{
  inputs,
  ...
}:
{
  flake-file.inputs.pedantix = {
    url = "github:Swarsel/pedantix";
    inputs = {
      flake-parts.follows = "flake-parts";
      nixpkgs.follows = "nixpkgs";
      treefmt-nix.follows = "treefmt-nix";
    };
  };

  imports = [
    inputs.pedantix.flakeModules.default
  ];

  perSystem =
    {
      pkgs,
      inputs',
      ...
    }:
    {
      make-shells.default.packages = [
        pkgs.nixfmt
        pkgs.deadnix
        pkgs.statix
        inputs'.pedantix.packages.pedantix
        pkgs.nixVersions.nix_2_35
      ];

      treefmt.programs = {
        deadnix.enable = true;
        nixfmt.enable = true;
        pedantix = {
          enable = true;
          excludes = [ "flake.nix" ];
        };
        statix.enable = true;
      };
    };
}
