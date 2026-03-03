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
        # Pinned in docker-images.lock.json — update with: nix run .#update-debian-hashes
        debianBaseImages = builtins.fromJSON (builtins.readFile ./docker-images.lock.json);

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

        # Script that refreshes docker-images.lock.json with current Debian image digests.
        # Run with: nix run .#update-debian-hashes [-- path/to/docker-images.lock.json]
        updateDebianHashesPy = pkgs.writeText "update-debian-hashes.py" ''
          import base64, hashlib, json, os, subprocess, sys, tempfile

          lock_file = sys.argv[1] if len(sys.argv) > 1 else "docker-images.lock.json"
          archs = ["amd64", "arm64"]
          codenames = ["bookworm", "trixie"]
          new_values = {}

          for arch in archs:
              new_values[arch] = {}
              for codename in codenames:
                  print(f"Fetching debian:{codename}-slim for {arch}...", flush=True)
                  result = subprocess.run(
                      ["skopeo", "inspect", "--override-arch", arch,
                       f"docker://debian:{codename}-slim"],
                      capture_output=True, text=True, check=True,
                  )
                  image_digest = json.loads(result.stdout)["Digest"]
                  print(f"  imageDigest: {image_digest}")

                  with tempfile.NamedTemporaryFile(suffix=".tar", delete=False) as f:
                      tmpfile = f.name
                  try:
                      subprocess.run(
                          ["skopeo", "copy", "--override-arch", arch,
                           f"docker://debian:{codename}-slim",
                           f"docker-archive:{tmpfile}:debian:{codename}-slim"],
                          check=True,
                      )
                      with open(tmpfile, "rb") as f:
                          digest_bytes = hashlib.sha256(f.read()).digest()
                  finally:
                      os.unlink(tmpfile)
                  sha256 = "sha256-" + base64.b64encode(digest_bytes).decode()
                  print(f"  sha256: {sha256}")
                  new_values[arch][codename] = {"imageDigest": image_digest, "sha256": sha256}

          with open(lock_file, "w") as f:
              json.dump(new_values, f, indent=2)
              f.write("\n")
          print(f"Updated {lock_file} successfully!")
        '';

        update-debian-hashes = pkgs.writeShellApplication {
          name = "update-debian-hashes";
          runtimeInputs = with pkgs; [ skopeo python3 ];
          text = ''
            python3 ${updateDebianHashesPy} "''${1:-docker-images.lock.json}"
          '';
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

        inherit update-debian-hashes;
      }
    );
  };
}
