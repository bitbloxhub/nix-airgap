# DO-NOT-EDIT. This file was auto-generated using github:vic/flake-file.
# Use `nix run .#write-flake` to regenerate it.
{
  inputs = {
    flake-file.url = "github:vic/flake-file";

    flake-parts = {
      inputs.nixpkgs-lib.follows = "nixpkgs";
      url = "github:hercules-ci/flake-parts";
    };

    flint = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:NotAShelf/flint";
    };

    import-tree.url = "github:vic/import-tree";

    make-shell = {
      inputs.flake-compat.follows = "";
      url = "github:nicknovitski/make-shell";
    };

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pedantix = {
      inputs = {
        flake-parts.follows = "flake-parts";
        nixpkgs.follows = "nixpkgs";
        treefmt-nix.follows = "treefmt-nix";
      };
      url = "github:Swarsel/pedantix";
    };

    treefmt-nix = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:numtide/treefmt-nix";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (
      (inputs.import-tree.filterNot (inputs.nixpkgs.lib.hasSuffix "npins/default.nix")) ./nix
    );
}
