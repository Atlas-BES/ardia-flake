# Ardia on Nix

A flake for [ardia-browser/ardia](https://github.com/ardia-browser/ardia) — the Chromium-based
browser with Arc's sidebar and Dia's polish.

Upstream currently ships Linux builds from its nightly channel only (x86-64, Wayland or X11).
This flake packages the newest nightly that has a Linux tarball and pins every download by
SHA-256.

## Run it

```sh
nix run .#ardia          # or: nix run .
```

Arguments are forwarded to Chromium, e.g. `nix run .#ardia -- --version`.

## Install it

```sh
nix profile install .#ardia
```

On NixOS, add the module instead:

```nix
# flake.nix
{
  inputs.ardia.url = "github:ardia-browser/ardia"; # or a path:/git URL to this flake

  outputs = { self, nixpkgs, ardia, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        ardia.nixosModules.default
        {
          programs.ardia.enable = true;
        }
      ];
    };
  };
}
```

The module installs `programs.ardia.package` (defaults to this flake's `ardia`) and the
browser's polkit action.

### Home Manager

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ardia.url = "github:ardia-browser/ardia"; # or a path:/git URL to this flake
  };

  outputs = { self, nixpkgs, home-manager, ardia, ... }: {
    homeConfigurations.me = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        ardia.homeManagerModules.default # also available as ardia.homeModules.default
        { programs.ardia.enable = true; }
      ];
    };
  };
}
```

The Home Manager module adds `programs.ardia.package` to `home.packages`. It is user-level,
so it does not install the polkit action; use the NixOS module for that.

## Dev shell

The repo's Linux UI and shared TypeScript packages build with Node 24 and pnpm 11:

```sh
nix develop
pnpm install
pnpm --filter @ardia/linux build
```

The macOS app itself still needs Xcode; this shell covers the Linux/TS side.

## CLI

The upstream `ardia` command (which controls a running browser) is also packaged:

```sh
nix run .#ardia-cli -- --help
```

Both packages install a `bin/ardia`, so don't install `.#ardia` and `.#ardia-cli` into the
same Nix profile; use `nix shell`/`nix run` for the CLI, or a separate profile.

## Sandbox

Nix cannot install Chromium's setuid `chrome-sandbox` helper into the store. Like Brave and
Google Chrome in nixpkgs, Ardia therefore uses Chromium's user-namespace sandbox. Make sure
unprivileged user namespaces are enabled:

```sh
sysctl kernel.unprivileged_userns_clone   # should be 1
```

On NixOS this is the default. If you run with AppArmor's
`kernel.apparmor_restrict_unprivileged_userns = 1`, either allow them for the Ardia binary or
set the sysctl to `0`.

## Updating

Linux assets are published per nightly and not every nightly includes them. `update-flake.sh`
finds the newest release that has both Linux tarballs — drafts are skipped, prereleases are
included — and rewrites the version and both hashes in `flake.nix`:

```sh
./update-flake.sh --dry-run   # show what would change
./update-flake.sh             # update flake.nix and run nix flake check
```

It reads the release's `.sha256` sidecars, so it only downloads a few kilobytes. Set
`GITHUB_TOKEN` to avoid GitHub's unauthenticated API rate limit, or `ARDIA_REPO` to check a
fork. To do it by hand, bump `version` and run `nix build .#ardia --rebuild` to get the
hash it expects.

`flake.lock` is generated and pins nixpkgs; update it separately with
`nix flake update nixpkgs`.

## Layout

| Output | What |
| --- | --- |
| `packages.<system>.ardia` | Wrapped browser (unwrapped tree in `passthru.unwrapped`) |
| `packages.<system>.ardia-cli` | Upstream CLI |
| `apps.<system>.default` | `nix run` entry point |
| `devShells.<system>.default` | Node 24, pnpm 11, Python, uv |
| `overlays.default` | Adds `ardia` / `ardia-cli` to nixpkgs |
| `nixosModules.default` | `programs.ardia.enable` |
| `homeManagerModules.default` | `programs.ardia.enable` for Home Manager (alias: `homeModules.default`) |
