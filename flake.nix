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

          # Nix's bash package installs loadable built-ins under lib/bash/, which causes
          # buildLayeredImage to create /lib as a directory in the customisation layer.
          # This shadows Debian's /lib -> usr/lib symlink from the fromImage base, breaking
          # the ELF interpreter chain for unpatched binaries (dontPatchELF = true) like maa.
          # Restore the symlink so the standard dynamic linker path resolves correctly.
          extraCommands = pkgs.lib.optionalString (fromImage != null) ''
            rm -rf lib
            ln -s usr/lib lib
          '';

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
        # Pinned in docker-images.lock.json — update with: nix run .#update-images-lock
        lock = builtins.fromJSON (builtins.readFile ./docker-images.lock.json);
        debianBaseImages = builtins.removeAttrs lock [ "maa-cli" ];
        maaCliLock = lock.maa-cli;

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

        # Fetch the official pre-compiled maa-cli binary from upstream releases.
        # The gnu variant is used as Debian provides glibc in the base image.
        fetchedMaaCli =
          let
            goarch = { "x86_64-linux" = "amd64"; "aarch64-linux" = "arm64"; }.${system};
            info = maaCliLock.${goarch};
          in pkgs.stdenvNoCC.mkDerivation {
            pname = "maa-cli-upstream";
            version = maaCliLock.version;
            src = pkgs.fetchurl {
              url = info.url;
              hash = info.sha256;
            };
            # The maa-cli tarball extracts files directly (no top-level directory),
            # so we tell Nix to use the current directory as the source root.
            sourceRoot = ".";
            # This is a pre-compiled upstream binary targeting the standard GNU/Linux ABI
            # (interpreter /lib64/ld-linux-x86-64.so.2). Skipping ELF patching preserves
            # that interpreter so the Debian base image's glibc is used at runtime instead
            # of a Nix-store glibc that would not exist in the image.
            dontPatchELF = true;
            installPhase = ''
              mkdir -p $out/bin
              binary=$(find . -name maa -type f | head -n1)
              if [ -z "$binary" ]; then
                echo "Error: maa binary not found in tarball" >&2
                exit 1
              fi
              install -m755 "$binary" $out/bin/maa
            '';
          };

        # Script that refreshes docker-images.lock.json with current Debian image digests
        # and the latest maa-cli release info.
        # Run with: nix run .#update-images-lock [-- path/to/docker-images.lock.json]
        updateImagesLockPy = pkgs.writeText "update-images-lock.py" ''
          import base64
          import binascii
          import hashlib
          import json
          import os
          import subprocess
          import sys
          import tempfile
          import urllib.request

          lock_file = sys.argv[1] if len(sys.argv) > 1 else "docker-images.lock.json"
          archs = ["amd64", "arm64"]
          codenames = ["bookworm", "trixie"]
          debian_values = {}

          for arch in archs:
              debian_values[arch] = {}
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
                  debian_values[arch][codename] = {"imageDigest": image_digest, "sha256": sha256}

          print("Fetching maa-cli version info...", flush=True)
          version_url = "https://raw.githubusercontent.com/MaaAssistantArknights/maa-cli/version/stable.txt"
          with urllib.request.urlopen(version_url) as resp:
              version_data = {}
              for line in resp.read().decode().splitlines():
                  if "=" in line and not line.startswith("#"):
                      k, v = line.split("=", 1)
                      version_data[k] = v
          version = version_data["VERSION"]
          print(f"  version: {version}")
          maa_cli_info = {"version": version}
          for goarch, target in [("amd64", "X86_64_UNKNOWN_LINUX_GNU"), ("arm64", "AARCH64_UNKNOWN_LINUX_GNU")]:
              name = version_data[f"{target}_NAME"]
              sha256 = "sha256-" + base64.b64encode(binascii.unhexlify(version_data[f"{target}_SHA256"])).decode()
              url = f"https://github.com/MaaAssistantArknights/maa-cli/releases/download/v{version}/{name}"
              print(f"  {goarch}: {name}")
              maa_cli_info[goarch] = {"url": url, "sha256": sha256}

          lock_data = {"maa-cli": maa_cli_info}
          lock_data.update(debian_values)
          with open(lock_file, "w") as f:
              json.dump(lock_data, f, indent=2)
              f.write("\n")
          print(f"Updated {lock_file} successfully!")
        '';

        update-images-lock = pkgs.writeShellApplication {
          name = "update-images-lock";
          runtimeInputs = with pkgs; [ skopeo python3 ];
          text = ''
            python3 ${updateImagesLockPy} "''${1:-docker-images.lock.json}"
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
          maa-cli-pkg = fetchedMaaCli;
          fromImage = pullDebianBase "bookworm";
        };

        debian-trixie = makeImage {
          name = "maa-cli-debian";
          maa-cli-pkg = fetchedMaaCli;
          fromImage = pullDebianBase "trixie";
        };

        inherit update-images-lock;
      }
    );
  };
}
