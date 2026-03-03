# maa-cli-docker

Docker images for [maa-cli](https://github.com/MaaAssistantArknights/maa-cli), the command-line interface for [MAA (MaaAssistantArknights)](https://github.com/MaaAssistantArknights/MaaAssistantArknights). Images are published to the [GitHub Container Registry (GHCR)](https://ghcr.io) and support both `amd64` and `arm64`.

## Available Images

### `ghcr.io/isning/maa-cli-debian` (recommended)

Built on top of a Debian slim base image. The upstream pre-compiled maa-cli binary is used, and MaaCore with its resources is baked in at image build time via `maa install`.

| Tag | Description |
|-----|-------------|
| `latest` | Latest MaaCore on Debian bookworm slim (multi-arch) |
| `bookworm` | Debian bookworm slim (multi-arch) |
| `bookworm-amd64` | Debian bookworm slim (amd64) |
| `bookworm-arm64` | Debian bookworm slim (arm64) |
| `trixie` | Debian trixie slim (multi-arch) |
| `trixie-amd64` | Debian trixie slim (amd64) |
| `trixie-arm64` | Debian trixie slim (arm64) |

### `ghcr.io/isning/maa-cli-nix`

Built with Nix using the official [maa-cli package from Nixpkgs](https://search.nixos.org/packages?query=maa-cli). MaaCore is bundled by the Nixpkgs package, but it may be **older** than the version in the Debian image because Nixpkgs follows its own release cadence.

| Tag | Description |
|-----|-------------|
| `latest` | Multi-arch manifest |
| `amd64` | amd64 only |
| `arm64` | arm64 only |

## Quick Start

```sh
# Pull and run a quick version check
docker run --rm ghcr.io/isning/maa-cli-debian maa --version

# Interactive shell inside the container
docker run -it --rm ghcr.io/isning/maa-cli-debian
```

Override the default timezone (`Asia/Shanghai`) at runtime:

```sh
docker run --rm -e TZ=America/New_York ghcr.io/isning/maa-cli-debian maa --version
```

Connect to a Redroid (Android-in-Docker) instance over ADB:

```sh
docker run --rm --network host ghcr.io/isning/maa-cli-debian \
  maa run <task> --addr 127.0.0.1:5555
```

## Image Contents

All images include:

- **maa-cli** — MAA command-line tool
- **adb** (android-tools) — required for connecting to Android/Redroid devices
- **bash**, **coreutils** — shell and basic utilities
- **CA certificates** — for HTTPS connections during resource updates
- **tzdata** — timezone data (default: `Asia/Shanghai`)

The `maa-cli-debian` images bake in MaaCore via `maa install` at image build time, so they always ship the **latest** MaaCore. The `maa-cli-nix` images bundle MaaCore as provided by Nixpkgs, which may be slightly older.

## Update Cadence

Images are rebuilt automatically every day:

1. **00:00 UTC** — `flake.lock` and `docker-images.lock.json` are updated to the latest maa-cli release and Debian base-image digests.
2. **01:00 UTC** — Docker images are rebuilt and pushed to GHCR. The `maa-cli-debian` images run `maa install` to bake in the latest MaaCore; the `maa-cli-nix` images receive whatever MaaCore version is bundled in the updated Nixpkgs package.

## Building Locally

[Nix](https://nixos.org/download/) with flakes enabled is required.

```sh
# Build the Debian bookworm image
nix build .#packages.x86_64-linux.debian-bookworm

# Load into Docker and run a smoke test
docker load < result
docker run --rm maa-cli-debian:latest maa --version

# Update Debian base-image digests and maa-cli hashes
nix run .#update-debian-hashes
```

Available Nix package attributes:

| Attribute | Description |
|-----------|-------------|
| `default` | Nix-built image using Nixpkgs maa-cli |
| `debian-bookworm` | Debian bookworm slim + upstream maa-cli binary |
| `debian-trixie` | Debian trixie slim + upstream maa-cli binary |
| `update-debian-hashes` | Script to refresh `docker-images.lock.json` |