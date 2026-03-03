{
  description = "Docker image for MAA (MaaArknightsAssistant) built with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nur-packages = {
      url = "github:Cryolitia/nur-packages";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nur-packages }:
  let
    # Supported systems for multi-arch builds
    supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

    # Helper to generate attributes for each supported system
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
  in {
    packages = forAllSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nurPkgs = nur-packages.packages.${system};

        # Common image layers shared between stable and nightly images
        commonContents = with pkgs; [
          android-tools # Required: provides adb for connecting to Redroid
          coreutils     # Provides sleep, echo, etc. for K8s startup scripts
          bash          # Provides shell environment
          cacert        # Provides HTTPS certificates needed for maa resource updates
          tzdata        # Provides timezone support
        ];

        makeImage = { name, maa-cli-pkg }: pkgs.dockerTools.buildLayeredImage {
          inherit name;
          tag = "latest";

          # Specific components included in the image (strictly as needed)
          contents = [ maa-cli-pkg ] ++ commonContents;

          config = {
            Cmd = [ "${pkgs.bash}/bin/bash" ];
            Env = [
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              # Override at runtime with -e TZ=<your-timezone> if needed
              "TZ=Asia/Shanghai"
              # Ensure all binaries are in PATH
              "PATH=/bin:${maa-cli-pkg}/bin:${pkgs.android-tools}/bin:${pkgs.coreutils}/bin"
            ];
          };
        };
      in {
        default = makeImage {
          name = "maa-cli-nix";
          maa-cli-pkg = pkgs.maa-cli; # Official maa-cli maintained in Nixpkgs
        };

        nightly = makeImage {
          name = "maa-cli-nix-nightly";
          maa-cli-pkg = nurPkgs.maa-cli; # Nightly build from NUR (updates faster than nixpkgs)
        };
      }
    );
  };
}
