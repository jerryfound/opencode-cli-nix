# Runtime Dependencies and Packaging Details of opencode

> Date: 2026-08-20. Follow-up to `research-npm-prebuilt-flake.md`.
> Sources: nixpkgs `pkgs/by-name/op/opencode/package.nix` (source build),
> numtide/llm-agents.nix `packages/opencode/package.nix` (prebuilt, GitHub releases),
> plus `strings` inspection of the official prebuilt darwin-arm64 binary (v1.18.18).

## 1. External tools the binary shells out to

A prebuilt bun binary is self-contained *as a language runtime* (no Node.js
needed), but it still spawns external tools as child processes. Evidence from
the prebuilt binary itself:

| Tool | References in binary | Who wraps it | Verdict |
|---|---|---|---|
| `rg` (ripgrep) | 55 | nixpkgs ✅, numtide ✅ | **Required** — powers code search |
| `sysctl` (macOS) | 3 | nixpkgs ✅ (darwin only), numtide ❌ | **Recommended on darwin** — CPU feature probing |
| `fzf` | 1 | nixpkgs ❌, numtide ✅ | Marginal — optional fuzzy finder integration |

On NixOS the global environment is minimal by design, so a bare binary cannot
rely on the user having `rg` installed. Both serious packagers therefore wrap
the binary with a `PATH` prefix:

```nix
wrapProgram $out/bin/opencode \
  --prefix PATH : ${lib.makeBinPath ([ ripgrep ] ++ lib.optionals stdenv.hostPlatform.isDarwin [ sysctl ])}
```

## 2. Environment variables that matter at runtime

Verified present/absent in the prebuilt binary via `strings`:

| Variable | In binary? | Purpose | Used by |
|---|---|---|---|
| `OPENCODE_DISABLE_AUTOUPDATE` | ✅ yes (2 refs) | Prevents opencode from trying to overwrite itself — essential in the read-only `/nix/store` | nixpkgs sets it; **we should too** |
| `OPENCODE_DISABLE_MODELS_FETCH` | ✅ yes (2 refs) | Skips the runtime fetch of the models.dev catalog | nixpkgs sets it for build hermeticity; for a prebuilt package the online fetch is fine — leave unset |
| `OPENCODE_VERSION` | ❌ no | Build-time stamp only | irrelevant for us |
| `OPENCODE_CHANNEL` | ❌ no | Build-time stamp only | irrelevant for us |

## 3. macOS code signing

- The upstream prebuilt darwin binary is **already adhoc-signed**, and the
  signature survives copying/renaming (a wrapper script only renames the
  binary to `.opencode-wrapped`; contents — and thus the signature — are
  untouched). Verified working on aarch64-darwin.
- nixpkgs re-signs with `codesign --force --sign -` because *their* binary is
  compiled inside the Nix sandbox and arm64 macOS refuses to run unsigned
  code. **Not needed** for the prebuilt approach.

## 4. Shell completions

`opencode completion` prints bash/zsh completion scripts. nixpkgs installs
them with `installShellFiles`, guarded by
`stdenv.buildPlatform.canExecute stdenv.hostPlatform`. Cheap to add, nice UX.

## 5. Install-time smoke test

nixpkgs uses `versionCheckHook` with `versionCheckProgramArg = "--version"`
plus `writableTmpDirAsHomeHook` (opencode wants a writable `$HOME` even for
`--version`). Equivalent to our CI's `./result/bin/opencode --version`, but
runs on every local build too.

## 6. What is wrapBuddy?

numtide's opencode package pulls in `wrapBuddy` on Linux. It is
[Mic92/wrap-buddy](https://github.com/Mic92/wrap-buddy): a tool that patches
ELF binaries with a small **stub loader** so they find the Nix store's dynamic
linker — an alternative to patchelf/autoPatchelfHook. Linux-only.

Our simpler `autoPatchelfHook` + `stdenv.cc.cc.lib` is the standard nixpkgs
approach and sufficient for opencode (its `DT_NEEDED` is just glibc basics).
wrapBuddy's stub-loader trick matters more for binaries that are re-exec'd or
patched outside the store; not our case.

## 7. Consequences for our `package.nix`

> **Status: applied** (2026-08-20), with two deviations discovered during
> implementation:
>
> - The sandbox's `$HOME` (`/var/empty`) is read-only and `opencode --version`
>   does `mkdir ~/.local`, which made `versionCheckHook` fail with EPERM.
>   Instead of pulling in `writableTmpDirAsHomeHook` (too new for the
>   nixos-22.05 compatibility floor), the package sets `HOME=$(mktemp -d)`
>   itself and uses a hand-rolled `installCheckPhase`.
> - `stdenv.buildPlatform.canExecute` only exists on nixpkgs >= 23.05; the
>   cross-build guard uses `stdenv.buildPlatform == stdenv.hostPlatform`
>   instead.

Concrete, evidence-backed improvements over the current minimal version:

1. Add `makeBinaryWrapper` and wrap with:
   - `--prefix PATH :` ripgrep (+ `sysctl` on darwin)
   - `--set OPENCODE_DISABLE_AUTOUPDATE true`
2. Add `installShellFiles` + completion generation (guarded by `canExecute`).
3. Add `versionCheckHook` smoke test with `writableTmpDirAsHomeHook`.
4. Skip: fzf (1 reference), codesign (already signed), wrapBuddy (overkill),
   models.dev bundling (runtime fetch is fine for a prebuilt package).
