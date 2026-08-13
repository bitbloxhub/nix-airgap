{
  inputs,
  ...
}:
{
  flake-file.inputs = {
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
      };
    };
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        pyproject-nix.follows = "pyproject-nix";
      };
    };
  };

  perSystem =
    {
      pkgs,
      ...
    }:
    let
      inherit (pkgs) lib;
      inherit (pkgs.callPackages inputs.pyproject-nix.build.util { }) mkApplication;
      airgap = mkApplication {
        package = pythonSet.nix-airgap;
        venv = pythonSet.mkVirtualEnv "nix-airgap-env" workspace.deps.default;
      };
      devEnvironment = pythonSet.mkVirtualEnv "nix-airgap-dev-env" workspace.deps.all;
      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };
      pythonSet =
        (pkgs.callPackage inputs.pyproject-nix.build.packages {
          python = pkgs.python3;
        }).overrideScope
          (
            lib.composeManyExtensions [
              inputs.pyproject-build-systems.overlays.wheel
              overlay
            ]
          );
      workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = ../.;
      };
    in
    {
      make-shells.default.packages = [
        devEnvironment
        pkgs.python3
        pkgs.uv
      ];
      packages = {
        inherit airgap;
        default = airgap;
      };
    };
}
