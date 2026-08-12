{
  inputs,
  ...
}:
{
  flake.nixosConfigurations.airgap = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      (
        {
          lib,
          pkgs,
          ...
        }:
        {
          environment.systemPackages = with pkgs; [
            jq
            git
          ];
          nix.settings = {
            substituters = lib.mkForce [ ];
            trusted-public-keys = lib.mkForce [
              "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
            ];
            trusted-users = lib.mkForce [ "root" ];
          };
          services.openssh = {
            enable = true;
            settings = {
              PasswordAuthentication = false;
              PermitRootLogin = "no";
            };
          };
          system.stateVersion = "26.05";
          users.users.test = {
            isNormalUser = true;
            openssh.authorizedKeys.keyFiles = [
              ../vm-key.pub
            ];
            extraGroups = [ "wheel" ];
          };
          security.sudo.wheelNeedsPassword = false;
          virtualisation.vmVariant.virtualisation = {
            diskSize = 20 * 1024; # MiB, 20 GiB
            forwardPorts = [
              {
                from = "host";
                guest.port = 22;
                host = {
                  address = "127.0.0.1";
                  port = 13964;
                };
              }
            ];
            graphics = false;
            # Actually isolate the guest.
            restrictNetwork = true;
            # Live working tree; run the VM from the repo root.
            sharedDirectories.work = {
              securityModel = "none";
              source = "$PWD";
              target = "/work";
            };
            # IMPORTANT: don't expose the host's /nix/store to the guest.
            useBootLoader = true;
          };
        }
      )
    ];
    system = "x86_64-linux";
  };
}
