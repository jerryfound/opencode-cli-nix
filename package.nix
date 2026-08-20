# Packages the opencode CLI from the official prebuilt binaries published
# on npm (opencode-<platform> packages), instead of compiling from source.
#
# Version and hashes live in hashes.json, which is regenerated daily by
# scripts/update.py from npm registry metadata. Do not edit by hand.

{ lib
, stdenv
, fetchurl
, autoPatchelfHook
, makeBinaryWrapper
, installShellFiles
, ripgrep
, # Optional facilities that may not exist on every nixpkgs; the package
  # degrades gracefully when they are missing.
  sysctl ? null # darwin CPU probing tool
}:

let
  release = builtins.fromJSON (builtins.readFile ./hashes.json);

  # Nix system -> npm platform package suffix.
  platformMap = {
    "x86_64-linux"   = "linux-x64";
    "aarch64-linux"  = "linux-arm64";
    "x86_64-darwin"  = "darwin-x64";
    "aarch64-darwin" = "darwin-arm64";
  };

  target = platformMap.${stdenv.hostPlatform.system}
    or (throw "opencode: unsupported system ${stdenv.hostPlatform.system}");

  pkg = release.platforms.${target};

  # True when the build machine can run the produced binary (i.e. not a
  # cross build). platform.canExecute would be nicer but only exists on
  # nixpkgs >= 23.05; attrset equality works on every nixpkgs.
  canRunHere = stdenv.buildPlatform == stdenv.hostPlatform;
in
stdenv.mkDerivation {
  pname = "opencode";
  version = release.version;

  src = fetchurl {
    url = pkg.url;
    # SRI sha512 taken verbatim from the registry's dist.integrity field.
    hash = pkg.hash;
  };

  # Every platform tarball unpacks to a single "package/" directory.
  sourceRoot = "package";

  nativeBuildInputs = [ makeBinaryWrapper installShellFiles ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  # The Linux binaries are dynamically linked against glibc basics only
  # (libc/libpthread/libdl/libm + ld-linux); stdenv.cc.cc.lib covers them.
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  # bun-compiled single-file executables carry an appended payload;
  # stripping would corrupt them.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/opencode $out/bin/opencode
    runHook postInstall
  '';

  postInstall = ''
    # opencode wants a writable $HOME even for read-only invocations such as
    # `--version` and `completion`; the sandbox's $HOME (/var/empty) is not.
    export HOME=$(mktemp -d)

    # opencode shells out to ripgrep for code search, and on darwin probes
    # CPU features via sysctl. Pin both into the wrapper's PATH so they are
    # present even on a minimal NixOS install.
    wrapProgram $out/bin/opencode \
      --prefix PATH : ${lib.makeBinPath (
        [ ripgrep ]
        ++ lib.optional (stdenv.hostPlatform.isDarwin && sysctl != null) sysctl
      )} \
      --set OPENCODE_DISABLE_AUTOUPDATE true
  ''
  # Generate shell completions when the build machine can run the binary.
  + lib.optionalString canRunHere ''
    installShellCompletion --cmd opencode \
      --bash <($out/bin/opencode completion) \
      --zsh <(SHELL=/bin/zsh $out/bin/opencode completion)
  '';

  # Install-time smoke test: the built binary must run and report our exact
  # version. Hand-rolled instead of versionCheckHook so that old nixpkgs
  # (verified back to nixos-22.05) keeps working.
  doInstallCheck = canRunHere;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME=$(mktemp -d)
    output="$($out/bin/opencode --version)"
    echo "opencode --version: $output"
    [ "$output" = "$version" ] || {
      echo "version check failed: expected $version" >&2
      exit 1
    }
    runHook postInstallCheck
  '';

  meta = {
    description = "AI coding agent, built for the terminal (prebuilt binary from npm)";
    homepage = "https://opencode.ai";
    license = lib.licenses.mit;
    mainProgram = "opencode";
    platforms = builtins.attrNames platformMap;
  };
}
