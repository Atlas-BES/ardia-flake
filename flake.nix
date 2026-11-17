{
  description = "Ardia — Arc's sidebar and Dia's polish on real Chromium";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      # Upstream only publishes Linux builds for x86_64.
      systems = [ "x86_64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      version = "0.2.47-nightly.4";
      tag = "v${version}";
      release = "https://github.com/ardia-browser/ardia/releases/download/${tag}";

      # To update: bump `version`, then run
      #   nix build .#ardia --rebuild   (or nix-prefetch-url on the assets)
      # and copy the hashes it reports here.
      browserSrc = {
        url = "${release}/Ardia-${version}-linux-x64.tar.xz";
        hash = "sha256-V/OaA3zhbxUP0Gkqjq4DZJ9Ck7Z0jqgRlFAkfGxaThU=";
      };

      cliSrc = {
        url = "${release}/ardia-cli-${version}-linux-x64.tar.gz";
        hash = "sha256-Fp7y6Zot7y1kJM99+xARBx2RVVLel1Lv82lKiL3ZFRk=";
      };

      # Runtime dependencies of Chromium's own Linux build. Keep this list in
      # sync with nixpkgs' browsers (e.g. brave) when Chromium grows a dep.
      runtimeDeps =
        pkgs: with pkgs; [
          alsa-lib
          at-spi2-atk
          at-spi2-core
          atk
          cairo
          cups
          dbus
          expat
          fontconfig
          freetype
          gdk-pixbuf
          glib
          gtk3
          gtk4
          libdrm
          libGL
          libgbm
          libkrb5
          libnotify
          libpulseaudio
          libsecret
          libuuid
          libva
          libx11
          libxcb
          libxcomposite
          libxcursor
          libxdamage
          libxext
          libxfixes
          libxi
          libxkbcommon
          libxrandr
          libxrender
          libxscrnsaver
          libxshmfence
          libxtst
          nspr
          nss
          pango
          pciutils
          pipewire
          snappy
          speechd-minimal
          stdenv.cc.cc
          udev
          vulkan-loader
          wayland
          zlib
        ];

      # System library search path for the bundled `chrome` binary.
      rpath = pkgs: lib.makeLibraryPath (runtimeDeps pkgs);

      # Extra executables the upstream `ardia-launch` script calls out to.
      scriptPath =
        pkgs:
        lib.makeBinPath (
          with pkgs;
          [
            coreutils
            gnugrep
            util-linux
          ]
        );

      mkArdia =
        pkgs:
        pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "ardia";
          inherit version;

          src = pkgs.fetchurl browserSrc;

          nativeBuildInputs = with pkgs; [
            patchelf
            xz
          ];

          buildInputs = runtimeDeps pkgs;

          sourceRoot = "ardia";

          dontConfigure = true;
          dontBuild = true;
          dontPatchELF = true;
          dontStrip = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/opt $out/bin
            cp -a . $out/opt/ardia

            runtime=$out/opt/ardia/lib/ardia
            substituteInPlace $runtime/ardia-launch \
              --replace-fail '#!/usr/bin/env bash' '#!${pkgs.bash}/bin/bash'

            # Patchelf the executables Chromium launches, as nixpkgs does for
            # Google Chrome and Brave. The bundled .so files keep their own
            # $ORIGIN rpaths.
            for exe in \
              "$runtime/chrome" \
              "$runtime/chrome_crashpad_handler" \
              "$runtime/chrome-sandbox"
            do
              patchelf \
                --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
                --set-rpath "${rpath pkgs}" \
                "$exe"
            done

            # Use NixOS' patched Vulkan loader so /run/opengl-driver ICDs work.
            rm "$runtime/libvulkan.so.1"
            ln -s ${lib.getLib pkgs.vulkan-loader}/lib/libvulkan.so.1 "$runtime/libvulkan.so.1"

            runHook postInstall
          '';

          passthru = {
            inherit browserSrc;
          };

          meta = {
            description = "Arc's sidebar and Dia's polish on real Chromium";
            homepage = "https://ardia.dev";
            changelog = "https://github.com/ardia-browser/ardia/releases/tag/${tag}";
            license = lib.licenses.gpl3Only;
            sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
            platforms = systems;
            mainProgram = "ardia";
          };
        });

      # Nix cannot install a setuid `chrome-sandbox` into the store, so the
      # wrapper relies on Chromium's user-namespace sandbox (as Brave and
      # Google Chrome do in nixpkgs). Enable unprivileged user namespaces if
      # your kernel disables them.
      wrapArdia =
        pkgs: ardia:
        pkgs.runCommand "ardia-${version}"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
            meta = ardia.meta // {
              mainProgram = "ardia";
            };
            passthru = {
              unwrapped = ardia;
              inherit browserSrc;
            };
          }
          ''
            makeWrapper ${ardia}/opt/ardia/lib/ardia/ardia-launch $out/bin/ardia \
              --prefix LD_LIBRARY_PATH : ${rpath pkgs} \
              --prefix PATH : ${scriptPath pkgs} \
              --suffix PATH : ${lib.makeBinPath [ pkgs.xdg-utils ]} \
              --set CHROME_WRAPPER ardia \
              --add-flags "--disable-features=OutdatedBuildDetector" \
              --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"

            install -Dm644 ${ardia}/opt/ardia/share/applications/ardia.desktop \
              $out/share/applications/ardia.desktop
            substituteInPlace $out/share/applications/ardia.desktop \
              --replace-fail 'Exec=ardia ' "Exec=$out/bin/ardia "

            install -Dm644 ${ardia}/opt/ardia/share/icons/hicolor/256x256/apps/ardia.png \
              $out/share/icons/hicolor/256x256/apps/ardia.png

            install -Dm644 ${ardia}/opt/ardia/share/polkit-1/actions/dev.ardia.linux.policy \
              $out/share/polkit-1/actions/dev.ardia.linux.policy
          '';

      mkArdiaCli =
        pkgs:
        pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "ardia-cli";
          inherit version;

          src = pkgs.fetchurl cliSrc;

          nativeBuildInputs = with pkgs; [
            patchelf
          ];

          sourceRoot = "ardia-cli-${version}";

          dontConfigure = true;
          dontBuild = true;
          dontPatchELF = true;
          dontStrip = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out
            cp -a . $out/

            substituteInPlace $out/bin/ardia \
              --replace-fail '#!/bin/sh' '#!${pkgs.stdenv.shell}'

            patchelf \
              --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
              --set-rpath "${
                lib.makeLibraryPath [
                  pkgs.glibc
                  pkgs.zlib
                  pkgs.openssl
                ]
              }" \
              $out/python/bin/python3.13

            runHook postInstall
          '';

          meta = {
            description = "Command-line interface for the Ardia browser";
            homepage = "https://github.com/ardia-browser/ardia";
            license = lib.licenses.asl20;
            sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
            platforms = systems;
            mainProgram = "ardia";
          };

          passthru = {
            inherit cliSrc;
          };
        });
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          ardia = wrapArdia pkgs (mkArdia pkgs);
        in
        {
          ardia = ardia;
          ardia-cli = mkArdiaCli pkgs;
          default = ardia;
        }
      );

      apps = forAllSystems (pkgs: {
        ardia = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.ardia}/bin/ardia";
          meta.description = "Ardia web browser";
        };
        ardia-cli = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.ardia-cli}/bin/ardia";
          meta.description = "Ardia browser command-line interface";
        };
        default = self.apps.${pkgs.stdenv.hostPlatform.system}.ardia;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            nodejs_24
            pnpm_11
            python3
            git
            jq
            curl
            cacert
            pkg-config
            gnumake
            uv
          ];

          shellHook = ''
            echo "Ardia dev shell — Node $(node --version), pnpm $(pnpm --version)"
            echo "The macOS app needs Xcode; this shell covers the Linux UI and shared TS packages."
            export ARDIACORE_PREBUILT_REPO="''${ARDIACORE_PREBUILT_REPO:-ardia-browser/ardia}"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);

      overlays.default = final: prev: {
        ardia = self.packages.${final.stdenv.hostPlatform.system}.ardia;
        ardia-cli = self.packages.${final.stdenv.hostPlatform.system}.ardia-cli;
      };

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.ardia;
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          options.programs.ardia = {
            enable = lib.mkEnableOption "the Ardia web browser";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${system}.ardia;
              defaultText = lib.literalExpression "inputs.ardia.packages.${system}.ardia";
              description = "The Ardia package to install.";
            };
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];

            # Polkit action used by the browser's sandbox/credential helpers.
            environment.etc."polkit-1/actions/dev.ardia.linux.policy".source =
              "${cfg.package}/share/polkit-1/actions/dev.ardia.linux.policy";
          };
        };

      homeManagerModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.ardia;
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          options.programs.ardia = {
            enable = lib.mkEnableOption "the Ardia web browser";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${system}.ardia;
              defaultText = lib.literalExpression "inputs.ardia.packages.${system}.ardia";
              description = "The Ardia package to install.";
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];
          };
        };

      # Some configs import modules under this shorter name.
      homeModules.default = self.homeManagerModules.default;
    };
}
