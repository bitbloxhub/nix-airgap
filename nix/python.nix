{
  inputs,
  ...
}:
{
  flake-file.inputs = {
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  perSystem =
    {
      pkgs,
      ...
    }:
    let
      inherit (pkgs) lib;
      workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = ../.;
      };
      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };
      pythonSet =
        (pkgs.callPackage inputs.pyproject-nix.build.packages {
          python = pkgs.python3;
        }).overrideScope
          (lib.composeManyExtensions [
            inputs.pyproject-build-systems.overlays.wheel
            overlay
          ]);
      inherit (pkgs.callPackages inputs.pyproject-nix.build.util { }) mkApplication;
      airgap = mkApplication {
        venv = pythonSet.mkVirtualEnv "nix-airgap-env" workspace.deps.default;
        package = pythonSet.nix-airgap;
      };
    in
    {
      packages.airgap = airgap;
      packages.default = airgap;
      make-shells.default.packages = [
        pkgs.python3
        pkgs.uv
      ];
    };
}
