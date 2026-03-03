{
  description = "Docker image for MAA (MaaArknightsAssistant) built with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    # Supported systems for multi-arch builds
    supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

    # Helper to generate attributes for each supported system
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
  in {
    packages = forAllSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        default = pkgs.dockerTools.buildLayeredImage {
          name = "maa-cli-nix";
          tag = "latest";

          # K8s args depend on /bin/sh, so we explicitly create a symlink
          extraCommands = ''
            mkdir -p bin
            ln -s ${pkgs.bash}/bin/bash bin/sh
          '';

          # Specific components included in the image (strictly as needed)
          contents = with pkgs; [
            maa-cli       # Official maa-cli maintained in Nixpkgs
            android-tools # Required: provides adb for connecting to Redroid
            coreutils     # Provides sleep, echo, etc. for K8s startup scripts
            bash          # Provides shell environment
            cacert        # Provides HTTPS certificates needed for maa resource updates
            tzdata        # Provides timezone support
          ];

          config = {
            Cmd = [ "/bin/sh" ];
            Env = [
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              # Override at runtime with -e TZ=<your-timezone> if needed
              "TZ=Asia/Shanghai"
              # Ensure all binaries are in PATH
              "PATH=/bin:${pkgs.maa-cli}/bin:${pkgs.android-tools}/bin:${pkgs.coreutils}/bin"
            ];
          };
        };
      }
    );
  };
}
