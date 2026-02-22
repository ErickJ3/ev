{
  description = "filesystem cleaner for Linux/FreeBSD";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, zig-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        zigpkg = zig-overlay.packages.${system}.master;
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            zigpkg
            pkgs.just
            pkgs.act
          ];
        };
      }
    );
}
