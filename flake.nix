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

        # Common image layers shared between stable and cryolitia images
        commonContents = with pkgs; [
          android-tools # Required: provides adb for connecting to Redroid
          coreutils     # Provides sleep, echo, etc. for K8s startup scripts
          bash          # Provides shell environment
          cacert        # Provides HTTPS certificates needed for maa resource updates
          tzdata        # Provides timezone support
        ];

        makeImage = { name, maa-cli-pkg, fromImage ? null }: pkgs.dockerTools.buildLayeredImage {
          inherit name fromImage;
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

        # Per-arch, per-codename content-addressed digests for debian slim base images.
        # To update, run for each arch in {amd64,arm64} and codename in {bookworm,trixie}:
        #   skopeo copy --override-arch <arch> docker://debian:<codename>-slim \
        #     docker-archive:/tmp/img.tar:debian:<codename>-slim
        #   sha256sum /tmp/img.tar | awk '{print $1}' | xxd -r -p | base64 \
        #     | xargs -I{} echo 'sha256-{}'
        debianBaseImages = {
          amd64 = {
            bookworm = {
              imageDigest = "sha256:74a21da88cf4b2e8fde34558376153c5cd80b00ca81da2e659387e76524edc73";
              sha256 = "sha256-R5UjwjvqVQrL+lK0jzBjS2poo3auXyZxu0b0RcMTIpk=";
            };
            trixie = {
              imageDigest = "sha256:b29a157cc8540addda9836c23750e389693bf3b6d9a932a55504899e5601a66b";
              sha256 = "sha256-DyLaBbm9k4xsBM4KbqKNX/ncfTW1ZRtdxKzNh80qbe8=";
            };
          };
          arm64 = {
            bookworm = {
              imageDigest = "sha256:210137e2083cc9cd391a5117ff97e158fb8e69b984063e585732aac86216d60e";
              sha256 = "sha256-QmO1gAOse0JVAUZE22Za8/SNMMGZd6aZWXjFk7x+EUI=";
            };
            trixie = {
              imageDigest = "sha256:fe8092b22e202f36de71030f43b52f97ceb79f649d91ed9bdd9d8881a011c1e3";
              sha256 = "sha256-z3NzdxH2mtKUXc0eQqmUVCDqlk25uGquRoVuPinOU9M=";
            };
          };
        };

        pullDebianBase = codename:
          let
            # Map Nix system to Docker architecture name (same as go.GOARCH)
            goarch = { "x86_64-linux" = "amd64"; "aarch64-linux" = "arm64"; }.${system};
            info = debianBaseImages.${goarch}.${codename};
          in pkgs.dockerTools.pullImage {
            imageName = "debian";
            inherit (info) imageDigest sha256;
            finalImageName = "debian";
            finalImageTag = "${codename}-slim";
          };
      in {
        default = makeImage {
          name = "maa-cli-nix";
          maa-cli-pkg = pkgs.maa-cli; # Official maa-cli maintained in Nixpkgs
        };

        cryolitia = makeImage {
          name = "maa-cli-nix-cryolitia";
          maa-cli-pkg = nurPkgs.maa-cli; # Cryolitia build from NUR (updates faster than nixpkgs)
        };

        debian-bookworm = makeImage {
          name = "maa-cli-debian";
          maa-cli-pkg = pkgs.maa-cli;
          fromImage = pullDebianBase "bookworm";
        };

        debian-trixie = makeImage {
          name = "maa-cli-debian";
          maa-cli-pkg = pkgs.maa-cli;
          fromImage = pullDebianBase "trixie";
        };
      }
    );
  };
}
