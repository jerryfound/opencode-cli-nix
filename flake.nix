{
  description = "opencode CLI packaged from official prebuilt npm binaries, updated daily";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      overlay = final: prev: {
        opencode = final.callPackage ./package.nix { };
      };
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ overlay ];
          };
        in
        {
          default = pkgs.opencode;
          opencode = pkgs.opencode;
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.opencode}/bin/opencode";
        };
      });
    };
}
