{
  description = "blUI";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, flake-utils, nixpkgs, nixpkgs-unstable, zig }@inputs :
    flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      unstable = nixpkgs-unstable.legacyPackages.${system};
      zigpkgs = zig.packages.${system};
    in
    {
      devShells.default = pkgs.mkShell {
        packages = [
          zigpkgs."master-2026-01-28"
          unstable.zls
          pkgs.nodejs
          pkgs.pnpm
        ];

        shellHook = '''';
      };
    });
}
