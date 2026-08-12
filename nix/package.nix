{
  perSystem =
    {
      pkgs,
      ...
    }:
    let
      demo =
        pkgs.runCommand "airgap-demo" {
          nativeBuildInputs = [ pkgs.hello ];
        } ''
          mkdir -p "$out"

          # Custom FOD dependencies.
          cp ${fod1} "$out/fod1"
          cp ${fod2} "$out/fod2"

          # Native build dependency. Airgap planner should use the cached
          # hello output without copying its source subtree.
          hello > "$out/hello"
          ${pkgs.ripgrep}/bin/rg --version > "$out/ripgrep-version"
          ln -s ${pkgs.ripgrep}/bin/rg $out/rg
          sleep 30
        '';
      fod1 =
        pkgs.runCommand "custom-fod-1"
          {
            outputHash = builtins.hashString "sha256" fod1Text;
            outputHashAlgo = "sha256";
            outputHashMode = "flat";
          }
          ''
            printf %s ${pkgs.lib.escapeShellArg fod1Text} > "$out"
          '';
      fod1Text = "hello from custom fod 1\n";
      fod2 =
        pkgs.runCommand "custom-fod-2"
          {
            outputHash = builtins.hashString "sha256" fod2Text;
            outputHashAlgo = "sha256";
            outputHashMode = "flat";
          }
          ''
            printf %s ${pkgs.lib.escapeShellArg fod2Text} > "$out"
          '';
      fod2Text = "hello from custom fod 2\n";
    in
    {
      # Package to copy over
      packages.demo = demo;
    };
}
