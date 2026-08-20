# opencode-cli-nix

Always up-to-date Nix package for [opencode](https://opencode.ai) - the AI coding agent built for the terminal.

**🚀 Automatically updated every 6 hours** from the official npm releases - no source compilation, no waiting for nixpkgs.

**📦 Prebuilt official binaries** - the exact same binaries that `npm install -g opencode-ai` installs.

## Why this package?

### Primary Goal: Always Up-to-Date opencode for Nix Users

This flake provides immediate access to the latest opencode versions with:

1. **Prebuilt Binaries**: bun-compiled single-file executables straight from npm - installs in seconds, not minutes
2. **Automated Updates**: Checked every 6 hours; new opencode versions land within hours of release
3. **Zero-Build Updates**: Hashes come from the npm registry metadata itself - no tarball downloads needed to bump versions
4. **Flake-First Design**: Direct flake usage, overlay included
5. **Hash Pinned**: Every platform tarball is pinned by its registry-attested sha512 integrity hash

### Why Not the Official Flake or nixpkgs?

The official opencode flake builds from source with bun (slow on every update), and the nixpkgs package only moves when a maintainer commits. `npm install -g` is fast but lives outside your declarative Nix configuration.

### Comparison Table

| Feature | npm global | nixpkgs | Official flake | This Flake |
|---------|------------|---------|----------------|------------|
| **Latest Version** | ✅ Always | ❌ Manual bumps | ✅ At release | ✅ Daily checks |
| **Install Speed** | ✅ Seconds | ✅ Cache (when fresh) | ❌ Source build | ✅ Seconds |
| **Declarative Config** | ❌ No | ✅ Yes | ✅ Yes | ✅ Yes |
| **Version Pinning** | ⚠️ Manual | ✅ Yes | ✅ Flake lock | ✅ Flake lock |
| **Hash Verified** | ❌ No | ✅ Yes | ✅ Yes | ✅ Registry sha512 |
| **Reproducible** | ❌ No | ✅ Yes | ✅ Yes | ✅ Yes |

## Quick Start

### Fastest Installation (Try it now!)

```bash
nix run github:jerryfound/opencode-cli-nix
```

### Install to Your System

```bash
nix profile add github:jerryfound/opencode-cli-nix
```

On Nix versions before 2.30 that do not provide `nix profile add`, use
`nix profile install` instead.

## Using with Nix Flakes

### Using with NixOS / nix-darwin (overlay, recommended)

The overlay replaces the (often outdated) `pkgs.opencode` from nixpkgs
everywhere it is referenced - system configuration, Home Manager, dev shells:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    opencode-cli-nix.url = "github:jerryfound/opencode-cli-nix";
  };

  outputs = { nixpkgs, opencode-cli-nix, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [{
        nixpkgs.overlays = [ opencode-cli-nix.overlays.default ];
        environment.systemPackages = [ pkgs.opencode ];
      }];
    };
  };
}
```

### Using with NixOS / Home Manager (direct reference)

Fine when you only install it in one place and don't need to shadow the
nixpkgs package:

```nix
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.opencode-cli-nix.packages.${pkgs.system}.opencode
  ];
}
```

For Home Manager, use `home.packages` instead of `environment.systemPackages`.

### Reusing your own nixpkgs

This package only uses long-stable nixpkgs facilities (`fetchurl`, `stdenv`,
`autoPatchelfHook`, `makeBinaryWrapper`) and is verified to build on every
nixpkgs release from `nixos-24.05` up to the latest stable and
`nixpkgs-unstable`. To avoid a duplicate nixpkgs evaluation in your closure,
point the input at yours:

```nix
inputs.opencode-cli-nix = {
  url = "github:jerryfound/opencode-cli-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

The pinned `nixpkgs-unstable` is only the default for standalone use
(`nix run`, CI smoke builds); following your own nixpkgs is safe.

### In a dev shell

```nix
devShells.${system}.default = pkgs.mkShell {
  buildInputs = [
    opencode-cli-nix.packages.${system}.default
  ];
};
```

## Technical Details

### Package Architecture

opencode ships on npm as a meta package (`opencode-ai`) whose
`optionalDependencies` point at per-platform packages
(`opencode-linux-x64`, `opencode-darwin-arm64`, …). Each platform tarball
contains a single bun-compiled executable at `package/bin/opencode`.

This flake skips the meta package and fetches the platform tarball for the
current system directly:

- **Linux**: the binary only links glibc basics (`libc`/`libpthread`/`libdl`/`libm`),
  fixed up with `autoPatchelfHook`
- **macOS**: the binary links only system libraries and is installed as-is
  (it ships already adhoc-signed, no re-signing needed)
- `dontStrip` is set because bun single-file executables carry an appended
  payload that stripping would corrupt

On top of the bare binary, the package adds the polish that a Nix-installed
CLI needs:

- **Runtime tools pinned into PATH**: opencode shells out to `ripgrep` for
  code search (and to `sysctl` on macOS), so the wrapper prepends their
  store paths to `PATH` - they work even on a minimal NixOS install
- **Self-update disabled**: the wrapper sets `OPENCODE_DISABLE_AUTOUPDATE=true`,
  since opencode must never try to overwrite itself in the read-only store
- **Shell completions**: bash and zsh completions generated at build time
- **Install-time smoke test**: every build runs `opencode --version` and
  asserts it matches the pinned version

Supported systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
`aarch64-darwin`.

### How Updates Work

```
GitHub Actions (cron, every 6 hours)
        │
        ▼
scripts/update.py  ──► registry.npmjs.org  (pure JSON, no downloads)
        │                • opencode-ai dist-tags.latest → version
        │                • opencode-<platform>/<version> → tarball URL + sha512
        ▼
hashes.json  ◄── package.nix reads it and fetchurl's the platform tarball
        │
        ▼
nix build smoke test (x86_64-linux) ──► commit + push
```

The npm registry metadata carries a `dist.integrity` sha512 hash for every
tarball, computed at publish time - so refreshing the pins requires nothing
but a few HTTP requests. Nix is only installed in CI for the post-update
smoke build.

## Development

```bash
# Clone the repository
git clone https://github.com/jerryfound/opencode-cli-nix
cd opencode-cli-nix

# Build locally
nix build

# Test the build
./result/bin/opencode --version
```

Note: flakes only see files tracked by git, so remember to `git add` new
files (including `hashes.json`) before building.

## Updating opencode Version

### Automated Updates

A GitHub Action checks the npm registry every 6 hours. When a new stable
version is detected:

1. `scripts/update.py` rewrites `hashes.json` with the new version and hashes
2. A smoke build on `x86_64-linux` verifies the binary runs
3. The change is committed and pushed automatically

A check that finds no new version touches nothing and produces no commit.
The workflow also runs on manual trigger via the GitHub Actions UI.

### Manual Updates

```bash
python3 scripts/update.py   # rewrites hashes.json if a new release exists
nix build                   # verify
./result/bin/opencode --version
```

## Troubleshooting

### Command not found

Make sure the Nix profile bin directory is in your PATH:

```bash
export PATH="$HOME/.nix-profile/bin:$PATH"
```

### Old CPU without AVX2 (x86_64)

The x64 builds require AVX2. Upstream publishes `-baseline` packages for
older CPUs, but they are not wired up in this flake yet.

## License

This Nix packaging is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

opencode itself is licensed under the MIT License - see [opencode's repository](https://github.com/anomalyco/opencode) for details.

## Contributing

Contributions are welcome! Please submit pull requests or issues on GitHub.

## Related Projects

- [codex-cli-nix](https://github.com/sadjow/codex-cli-nix) - Similar packaging for OpenAI Codex
- [opencode-nix](https://github.com/dan-online/opencode-nix) - opencode flake fetching from GitHub releases, updated hourly, also packages the desktop app
- [llm-agents.nix](https://github.com/numtide/llm-agents.nix) - Nix packages for many AI coding agents, updated daily
- [nixpkgs](https://github.com/NixOS/nixpkgs) - The Nix Packages collection
