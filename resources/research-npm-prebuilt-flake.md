# opencode-cli-nix 调研报告：基于 npm 预编译二进制的 Nix 每日更新方案

> 调研日期：2026-08-20
> 结论：**方案真实、可行，且已有社区先例。** 推荐直接基于 npm registry 的平台分包 + registry 自带的 sha512 integrity hash 实现，GitHub Actions 每日更新时**无需下载 tarball 也无需安装 Nix** 即可完成版本与 hash 更新。

---

## 1. 背景与动机

| 现状 | 问题 |
|---|---|
| `~/nixos-config` 使用 opencode 官方仓库的 `flake.nix` | 官方 flake 用 bun **从源码构建**（含单独的 `node_modules` fixed-output derivation），每次更新都要长时间编译 |
| nixpkgs 中的 `opencode` 包 | 依赖维护者手动 commit，更新滞后 |

目标：新建 flake，直接打包 `npm install -g opencode-ai` 所用的**官方预编译二进制**，固定 hash，GitHub Actions 每日检查更新。

## 2. opencode 的分发机制（已验证）

npm 上的 `opencode-ai` 是一个**元包**，本身不含二进制，通过 `optionalDependencies` 声明 12 个平台分包，由 `postinstall.mjs` 按平台/架构/AVX2/musl 选择并复制对应二进制：

```
opencode-ai (meta)
├── opencode-darwin-arm64          ← macOS Apple Silicon
├── opencode-darwin-x64 / -baseline
├── opencode-linux-x64 / -baseline / -musl / -baseline-musl
├── opencode-linux-arm64 / -musl
└── opencode-windows-x64 / -arm64 / ...（Nix 不需要）
```

每个平台分包 tarball 内只有一个文件：`package/bin/opencode`（bun 编译的单文件可执行体）。

**实测（v1.18.18，2026-08-13 发布）：**

| 平台包 | tarball 大小 | 解压后 | 形态 |
|---|---|---|---|
| `opencode-darwin-arm64` | 44 MB | 137 MB | Mach-O arm64，仅链接 `/usr/lib` 系统库（libicucore/libresolv/libc++/libSystem），adhoc 签名，**本机直接运行成功，输出 `1.18.18`** |
| `opencode-linux-x64` | — | — | ELF x86-64，动态链接，`DT_NEEDED` 仅 `libc/libpthread/libdl/libm/ld-linux`，interpreter `/lib64/ld-linux-x86-64.so.2` → NixOS 上只需 `autoPatchelfHook` + `stdenv.cc.cc.lib` 即可 |

发布节奏：稳定版约每 2–3 天一个（最近：1.18.17 → 08-12，1.18.18 → 08-13；npm 上另有高频 `0.0.0-dev-*` 预发布，应忽略）。**每日检查更新足够。**

## 3. 关键验证：hash 可以"免费"拿到

这是本方案相对同类项目的最大优势。npm registry 的每个平台包版本元数据自带 `dist.integrity`（SRI 格式 sha512），与 tarball 内容一一对应：

```
GET https://registry.npmjs.org/opencode-darwin-arm64/1.18.18
→ dist.tarball  = https://registry.npmjs.org/opencode-darwin-arm64/-/opencode-darwin-arm64-1.18.18.tgz
→ dist.integrity = sha512-VkG+bz8u8Xqg9NzPK+2/71nEd4DKKlo2NLZurQ1eLAzDnmb1CMYZif/o6Shl8YFuTuYU/30k6yufl4Zr0Ij64g==
```

**已实测验证**：本地 `shasum -a 512` 计算下载的 tarball，与 registry 的 integrity 完全一致。

推论：

1. Nix 的 `fetchurl { url = ...; hash = "sha512-..."; }` 直接接受 SRI 格式，无需转换。
2. GitHub Actions 更新时**只需几次 registry API 调用**（纯 JSON），不用下载 44MB×4 的 tarball、不用装 Nix、不用 `nix-prefetch-url`。更新脚本可以是一个几十行的 Python/Bash。

## 4. 社区先例（方案真实性佐证）

| 项目 | 模式 | 更新频率 |
|---|---|---|
| [dan-online/opencode-nix](https://github.com/dan-online/opencode-nix) | 从 **GitHub Releases** 取预编译 zip/tar.gz + `autoPatchelfHook`，Actions 更新版本/hash → 自动 PR → auto-merge | 每小时 |
| [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix) | 多个 AI CLI 的 Nix 包合集，含 opencode，附公共 binary cache | 每日 |
| [ryoppippi/nix-claude-code](https://github.com/ryoppippi/nix-claude-code) | 同模式（Claude Code 预编译二进制） | 每小时 |

本项目与 dan-online/opencode-nix 的差异点：

- **源不同**：用 npm registry 而非 GitHub Releases。registry 自带 integrity hash，更新 CI 更轻、更快、不依赖 `nix-prefetch-url`。
- GitHub Releases 的 zip（darwin）多一层解压；npm tarball 结构更统一（四个平台都是 `package/bin/opencode`）。

> 备选：如果只是自己用，直接引用 `github:dan-online/opencode-nix` 或 numtide 的 cache 即可零维护。自建的价值在于可控、轻量、学习，且 npm 源通常与 release 同步发布。

## 5. 推荐方案设计

### 5.1 仓库结构

```
opencode-cli-nix/
├── flake.nix                  # 输出 packages / overlays，四平台
├── package.nix                # 从 npm registry fetchurl 平台 tarball，固定版本+hash
├── hashes.json                # { version, platforms: { target: { url, hash } } }（自动生成）
├── scripts/
│   └── update.py              # 查 registry latest → 写 hashes.json + package.nix 版本
└── .github/workflows/
    └── update.yml             # 每日 cron：跑 update.py → 有变更则开 PR/commit
```

### 5.2 package.nix 核心逻辑（示意）

```nix
{ lib, stdenv, fetchurl, autoPatchelfHook }:
let
  meta = builtins.fromJSON (builtins.readFile ./hashes.json);
  platformMap = {
    "x86_64-linux"  = "linux-x64";
    "aarch64-linux" = "linux-arm64";
    "x86_64-darwin" = "darwin-x64";
    "aarch64-darwin" = "darwin-arm64";
  };
  target = platformMap.${stdenv.hostPlatform.system};
  p = meta.platforms.${target};
in
stdenv.mkDerivation {
  pname = "opencode";
  version = meta.version;
  src = fetchurl { url = p.url; hash = p.hash; };  # hash 为 npm SRI sha512
  sourceRoot = "package";
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];
  installPhase = ''
    install -Dm755 bin/opencode $out/bin/opencode
  '';
  # darwin 上二进制 adhoc 签名、只链接系统库，无需任何修补
}
```

要点：

- Linux 二进制只依赖 glibc 基础库（已解析 `DT_NEEDED` 确认），`autoPatchelfHook` + `stdenv.cc.cc.lib` 足够。
- darwin 二进制已实测可直接运行，无需 `fixup`。
- x64 变体注意：opencode 为无 AVX2 的老 CPU 提供 `-baseline` 包。第一版可默认非 baseline（现代 CPU 均支持 AVX2），后续如需兼容再加选项。
- musl 变体（NixOS 用不到，可忽略）。

### 5.3 update.py 核心逻辑（示意）

```python
# 伪代码，已在 _tmp/ 验证过等效流程
latest = GET registry.npmjs.org/opencode-ai → dist-tags.latest   # 过滤掉 0.0.0-dev-*
for target in ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"]:
    m = GET registry.npmjs.org/opencode-{target}/{latest}
    platforms[target] = { url: m.dist.tarball, hash: m.dist.integrity }
写回 hashes.json（版本无变化则退出 0 且无 diff）
```

### 5.4 GitHub Actions

- `schedule: cron` 每日一次（错开整点，如 `17 3 * * *`）+ `workflow_dispatch` 手动触发。
- 步骤：checkout → 跑 `scripts/update.py` → `git diff --quiet` 判断有无更新 → 有则直接 commit 到 main（自用仓库可不开 PR）或 `peter-evans/create-pull-request` 开 PR。
- 可选增强：在 CI 里加一步 `nix build`（装 `cachix/install-nix-action`）验证构建，`./result/bin/opencode --version` 冒烟测试——能提前拦下上游包结构变化。
- **无需 Nix 即可更新 hash** 是本方案相对 dan-online/opencode-nix 的简化点；加 Nix 构建验证只是可选的质量门。

## 6. 风险与注意点

| 风险 | 评估 | 缓解 |
|---|---|---|
| 上游改 tarball 内部结构 | 低（bun 单二进制模式稳定） | CI 里加 `nix build` + `--version` 冒烟 |
| npm 发布滞后于 GitHub Release | 低（实测同日发布） | 版本源以 npm `dist-tags.latest` 为准，避免追到没有 npm 包的 release |
| `0.0.0-dev-*` 预发布污染 latest | 实测 `dist-tags.latest` 指向稳定版，不受影响 | 仍建议脚本里过滤 `0.0.0-dev` 前缀 |
| 老 x64 CPU 无 AVX2 崩溃 | 仅影响旧硬件 | 后续可暴露 `baseline` 选项 |
| linux-arm64 未实测 patchelf | 结构与 x64 一致，风险低 | CI 矩阵构建四个平台 |

## 7. 结论

1. **真实**：opencode 官方通过 npm 平台分包分发预编译二进制，机制公开稳定；社区已有至少 3 个同模式项目长期自动运行。
2. **可行且更优**：npm registry 自带 sha512 integrity，使"固定 hash 的每日自动更新"可以在**不下载二进制、不装 Nix** 的 CI 里完成——比现有的 GitHub-Releases 方案更轻。
3. darwin 开箱即用；linux 只需处理 glibc 解释器，工作量极小。
4. 下一步：按 §5 结构实现，先手动跑一次 `update.py` + 本机 `nix build` 验证四平台（至少 aarch64-darwin / x86_64-linux），再开 Actions 定时任务。

## 附：调研中间产物

`_tmp/` 目录保留：平台 tarball、解压出的二进制、`hashes.json`（registry 原始数据样例）、hash 校验记录。
