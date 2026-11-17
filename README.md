# ardia-flake

Nix packaging for [Ardia](https://ardia.dev) — Arc's sidebar and Dia's polish on real Chromium.

Upstream only publishes Linux builds (x86_64) from its nightly channel. This flake pins the
newest nightly that ships Linux tarballs, verifies them by SHA-256, and packages the browser,
its CLI, and NixOS/Home Manager modules.

## Requirements

- Nix with flakes enabled
- `x86_64-linux`
- Unprivileged user namespaces (see [Sandbox](#sandbox))

## Usage

### Run

```sh
nix run github:Atlas-BES/ardia-flake            # or: nix run .#ardia
nix run .#ardia -- --version                    # extra args go to Chromium
```

### Install

```sh
nix profile install .#ardia
```

### NixOS

```nix
{
  inputs.ardia.url = "github:Atlas-BES/ardia-flake";

  outputs = { self, nixpkgs, ardia, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        ardia.nixosModules.default
        { programs.ardia.enable = true; }
      ];
    };
  };
}
```

Installs `programs.ardia.package` (defaults to this flake's `ardia`) and the browser's polkit
action; set `programs.ardia.package` to use a different build.

### Home Manager

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ardia.url = "github:Atlas-BES/ardia-flake";
  };

  outputs = { self, nixpkgs, home-manager, ardia, ... }: {
    homeConfigurations.me = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        ardia.homeManagerModules.default # alias: ardia.homeModules.default
        { programs.ardia.enable = true; }
      ];
    };
  };
}
```

Adds the browser to `home.packages`. It is user-level, so it does not install the polkit
action — use the NixOS module for that.

### Overlay

```nix
{
  nixpkgs.overlays = [ ardia.overlays.default ];
  environment.systemPackages = [ pkgs.ardia pkgs.ardia-cli ];
}
```

### CLI

```sh
nix run .#ardia-cli -- --help     # or: nix shell .#ardia-cli -c ardia --help
```

Both packages install `bin/ardia`, so don't put `.#ardia` and `.#ardia-cli` in the same
profile; use `nix run`/`nix shell` for the CLI.

### Development shell

```sh
nix develop
pnpm install
pnpm --filter @ardia/linux build
```

Provides Node 24, pnpm 11, Python, uv and friends for the Linux UI and shared TypeScript
packages. The macOS app still needs Xcode.

## Sandbox

Nix cannot install Chromium's setuid `chrome-sandbox` into the store, so — like Brave and
Google Chrome in nixpkgs — Ardia uses the user-namespace sandbox:

```sh
sysctl kernel.unprivileged_userns_clone   # should be 1
```

That is the default on NixOS. If you set
`kernel.apparmor_restrict_unprivileged_userns = 1`, allow it for the Ardia binary or set the
sysctl back to `0`.

## Updating

Linux assets are not in every nightly. `update-flake.sh` finds the newest release that has
both Linux tarballs (drafts skipped, prereleases included) and rewrites the version and both
hashes in `flake.nix`:

```sh
./update-flake.sh --dry-run   # show what would change
./update-flake.sh             # update flake.nix, then run nix flake check
```

It reads the release's `.sha256` sidecars, so it downloads a few kilobytes. Set `GITHUB_TOKEN`
to avoid GitHub's anonymous API rate limit, or `ARDIA_REPO` to check a fork.

Manually: bump `version`, prefetch the two tarballs, drop the resulting hashes into
`browserSrc.hash` / `cliSrc.hash`, then `nix build .#ardia`. Update nixpkgs separately with
`nix flake update nixpkgs`.

## Outputs

| Output | What |
| --- | --- |
| `packages.<system>.ardia` | Wrapped browser (`passthru.unwrapped` for the raw tree) |
| `packages.<system>.ardia-cli` | Upstream CLI |
| `apps.<system>.default` | `nix run` entry point |
| `devShells.<system>.default` | Node 24, pnpm 11, Python, uv |
| `overlays.default` | Adds `ardia` / `ardia-cli` to nixpkgs |
| `nixosModules.default` | `programs.ardia.enable` |
| `homeManagerModules.default` | `programs.ardia.enable` (alias: `homeModules.default`) |
| `formatter.<system>` | `nixfmt` |

See [FLAKE.md](FLAKE.md) for longer packaging and maintenance notes (patchelf, rpath,
Vulkan, wrapper flags).

## License

This flake only repackages upstream binaries. Ardia is GPL-3.0-only, the CLI is Apache-2.0;
see `meta.license` in [flake.nix](flake.nix).
