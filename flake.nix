{
  description = "blui";

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
          zigpkgs.master
          unstable.zls
        ];

        nativeBuildInputs = with pkgs; [
          pkg-config
        ];

        shellHook = ''
          #PATH="$PATH:/Users/tobias/src/github.com/ziglang/zig/build/stage3/bin"
          echo "zig" "$(zig version)"
          unset NIX_CFLAGS_COMPILE
          unset NIX_LDFLAGS
        '';
      };
    });
}
