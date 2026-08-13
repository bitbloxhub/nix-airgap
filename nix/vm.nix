{
  inputs,
  ...
}:
{
  flake.nixosConfigurations = {
    airgap = inputs.nixpkgs.lib.nixosSystem {
      modules = [
        (
          {
            lib,
            pkgs,
            ...
          }:
          {
            environment.systemPackages = with pkgs; [
              bindfs
              git
              jq
            ];
            networking.hostName = "airgap";
            nix.settings = {
              substituters = lib.mkForce [ ];
              trusted-public-keys = lib.mkForce [
                "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
              ];
              trusted-users = lib.mkForce [ "root" ];
            };
            security.sudo.wheelNeedsPassword = false;
            services.openssh = {
              enable = true;
              settings = {
                PasswordAuthentication = false;
                PermitRootLogin = "no";
              };
            };
            system.stateVersion = "26.05";
            users.users.test = {
              extraGroups = [ "wheel" ];
              isNormalUser = true;
              openssh.authorizedKeys.keyFiles = [
                ../vm/vm-key.pub
              ];
            };
            virtualisation.vmVariant = {
              boot.growPartition = true;
              fileSystems."/".autoResize = true;
              systemd.services.shared-user = {
                after = [ "run-shared\\x2draw.mount" ];
                requires = [ "run-shared\\x2draw.mount" ];
                serviceConfig = {
                  ExecStart = [
                    "${pkgs.coreutils}/bin/mkdir -p /work"
                    "${pkgs.bindfs}/bin/bindfs --force-user=test --force-group=users /run/shared-raw /work"
                  ];
                  ExecStop = "${pkgs.fuse3}/bin/fusermount3 -u /work";
                  RemainAfterExit = true;
                  Type = "oneshot";
                };
                wantedBy = [ "multi-user.target" ];
              };
              virtualisation = {
                diskSize = 20 * 1024; # MiB, 20 GiB
                forwardPorts = [
                  {
                    from = "host";
                    guest.port = 22;
                    host = {
                      address = "0.0.0.0";
                      port = 13964;
                    };
                  }
                ];
                graphics = false;
                # Actually isolate the guest.
                restrictNetwork = true;
                # Live working tree; run the VM from the vm/ directory.
                sharedDirectories."shared-raw" = {
                  securityModel = "none";
                  source = "$OLDPWD/..";
                  target = "/run/shared-raw";
                };
                # IMPORTANT: don't expose the host's /nix/store to the guest.
                useBootLoader = true;
              };
            };
          }
        )
      ];
      system = "x86_64-linux";
    };
    client = inputs.nixpkgs.lib.nixosSystem {
      modules = [
        (
          {
            lib,
            pkgs,
            ...
          }:
          {
            boot.growPartition = true;
            environment.systemPackages = with pkgs; [
              bindfs
              git
              jq
            ];
            fileSystems."/".autoResize = true;
            networking.hostName = "client";
            nix.settings = {
              experimental-features = [
                "nix-command"
                "flakes"
              ];
              substituters = lib.mkForce [
                "https://cache.nixos.org"
              ];
              trusted-public-keys = lib.mkForce [
                "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
              ];
              trusted-users = lib.mkForce [ "root" ];
            };
            security.sudo.wheelNeedsPassword = false;
            services.openssh = {
              enable = true;
              settings = {
                PasswordAuthentication = false;
                PermitRootLogin = "no";
              };
            };
            system.stateVersion = "26.05";
            users.users.test = {
              extraGroups = [ "wheel" ];
              isNormalUser = true;
              openssh.authorizedKeys.keyFiles = [
                ../vm/vm-key.pub
              ];
            };
            virtualisation.vmVariant = {
              boot.growPartition = true;
              fileSystems."/".autoResize = true;
              systemd.services.shared-user = {
                after = [ "run-shared\\x2draw.mount" ];
                requires = [ "run-shared\\x2draw.mount" ];
                serviceConfig = {
                  ExecStart = [
                    "${pkgs.coreutils}/bin/mkdir -p /work"
                    "${pkgs.bindfs}/bin/bindfs --force-user=test --force-group=users /run/shared-raw /work"
                  ];
                  ExecStop = "${pkgs.fuse3}/bin/fusermount3 -u /work";
                  RemainAfterExit = true;
                  Type = "oneshot";
                };
                wantedBy = [ "multi-user.target" ];
              };
              virtualisation = {
                diskSize = 20 * 1024; # MiB, 20 GiB
                forwardPorts = [
                  {
                    from = "host";
                    guest.port = 22;
                    host = {
                      address = "127.0.0.1";
                      port = 13965;
                    };
                  }
                ];
                graphics = false;
                # Client needs unrestricted network access.
                restrictNetwork = false;
                # Live working tree; run the VM from the vm/ directory.
                sharedDirectories."shared-raw" = {
                  securityModel = "none";
                  source = "$OLDPWD/..";
                  target = "/run/shared-raw";
                };
                # IMPORTANT: don't expose the host's /nix/store to the guest.
                useBootLoader = true;
              };
            };
          }
        )
      ];
      system = "x86_64-linux";
    };
  };
}
