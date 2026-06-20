{
  description = "Noumena Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          inherit (pkgs) stdenv;

          packageJson = builtins.fromJSON (builtins.readFile ./package.json);
          version = packageJson.version;

          sharedLibraryExt = stdenv.hostPlatform.extensions.sharedLibrary;
          supportedCompiledTargets = {
            x86_64-linux = "bun-linux-x64";
            aarch64-darwin = "bun-darwin-arm64";
          };
          compiledTarget = supportedCompiledTargets.${system} or null;
          targetSlug = target: lib.removePrefix "bun-" target;

          bunDepsHashBySystem = {
            x86_64-linux = "sha256-eA/mi+kblkx2tEp5yar039wQ8zvC2GJrM6cserkC2Aw=";
            aarch64-darwin = "sha256-4Jaw8P8/AXIqdkNGM4FyaeGS+eqYBLzrpux0arZtq6E=";
          };

          cargoVendorHashBySystem = {
            x86_64-linux = "sha256-tOjtzkTeS4fbMlj9C1cDsnzcEjQrP4Aee8zTBaq520s=";
            aarch64-darwin = "sha256-tOjtzkTeS4fbMlj9C1cDsnzcEjQrP4Aee8zTBaq520s=";
          };

          cleanSource = lib.cleanSourceWith {
            src = ./.;
            filter =
              path: type:
              let
                rel = lib.removePrefix "${toString ./.}/" (toString path);
                ignoredRoots = [
                  ".git"
                  ".jj"
                  ".tmp"
                  "dist"
                  "node_modules"
                  "flake.lock"
                  "flake.nix"
                  "result"
                ];
                ignored = root: rel == root || lib.hasPrefix "${root}/" rel;
              in
              !(lib.any ignored ignoredRoots);
          };

          depsSource = pkgs.runCommand "ncode-bun-deps-source" { } ''
            mkdir -p "$out"
            cp ${./package.json} "$out/package.json"
            cp ${./bun.lock} "$out/bun.lock"
          '';

          bunDeps = pkgs.stdenvNoCC.mkDerivation {
            pname = "ncode-bun-deps";
            inherit version;
            src = depsSource;
            nativeBuildInputs = [
              pkgs.bun
              pkgs.cacert
            ];
            outputHashAlgo = "sha256";
            outputHashMode = "recursive";
            outputHash = bunDepsHashBySystem.${system};

            dontConfigure = true;
            dontFixup = true;

            buildPhase = ''
              runHook preBuild

              export HOME="$TMPDIR/home"
              export BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
              mkdir -p "$HOME" "$BUN_INSTALL_CACHE_DIR"

              bun install --frozen-lockfile --ignore-scripts

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p "$out"
              cp -R node_modules "$out/node_modules"

              runHook postInstall
            '';
          };

          cargoVendor = pkgs.stdenvNoCC.mkDerivation {
            pname = "ncode-cargo-vendor";
            inherit version;
            src = cleanSource;
            nativeBuildInputs = [
              pkgs.cacert
              pkgs.cargo
            ];
            outputHashAlgo = "sha256";
            outputHashMode = "recursive";
            outputHash = cargoVendorHashBySystem.${system};

            dontConfigure = true;
            dontFixup = true;

            buildPhase = ''
              runHook preBuild

              export HOME="$TMPDIR/home"
              mkdir -p "$HOME" vendor

              cargo vendor --locked \
                --manifest-path native/markdown-renderer-napi/Cargo.toml \
                --sync native/openai-compat-ws-v2-napi/Cargo.toml \
                --sync rust/py_repl_host/Cargo.toml \
                vendor

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p "$out"
              cp -R vendor/. "$out/"

              runHook postInstall
            '';
          };

          commonNativeBuildInputs = [
            pkgs.bun
            pkgs.cargo
            pkgs.makeWrapper
            pkgs.pkg-config
            pkgs.rustc
          ]
          ++ lib.optionals stdenv.isLinux [
            pkgs.binutils
            pkgs.patchelf
          ];

          commonBuildInputs = [
            pkgs.openssl
          ];

          runtimeLibraryPath = lib.makeLibraryPath (
            [
              pkgs.openssl
              stdenv.cc.cc.lib
            ]
            ++ lib.optionals stdenv.isLinux [ pkgs.zlib ]
          );

          prepareBuildTree = ''
            export HOME="$TMPDIR/home"
            export BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
            export CARGO_HOME="$TMPDIR/cargo-home"
            export CARGO_NET_OFFLINE=true
            export CARGO_TARGET_DIR="$TMPDIR/cargo-target"
            mkdir -p "$HOME" "$BUN_INSTALL_CACHE_DIR" "$CARGO_HOME" .cargo

            cp -R ${bunDeps}/node_modules ./node_modules

            cat > .cargo/config.toml <<EOF
            [source.crates-io]
            replace-with = "vendored-sources"

            [source.vendored-sources]
            directory = "${cargoVendor}"
            EOF
          '';

          ncodeInstallCheck = ''
            runHook preInstallCheck

            version_output="$("$out/bin/ncode" --version)"
            if [ "$version_output" != "${version} (NCode)" ]; then
              echo "bad ncode --version output: $version_output" >&2
              exit 1
            fi

            help_output="$("$out/bin/ncode" --help)"
            printf '%s\n' "$help_output" | grep -F "Usage: ncode" >/dev/null
            printf '%s\n' "$help_output" | grep -F "Options:" >/dev/null

            runHook postInstallCheck
          '';

          buildCompiled =
            buildMode:
            let
              artifactName = "ncode-${version}-${targetSlug compiledTarget}";
            in
            stdenv.mkDerivation {
              pname = "ncode-${buildMode}";
              inherit version;
              src = cleanSource;
              nativeBuildInputs = commonNativeBuildInputs;
              buildInputs = commonBuildInputs;

              doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;

              configurePhase = ''
                runHook preConfigure
                ${prepareBuildTree}
                runHook postConfigure
              '';

              buildPhase = ''
                runHook preBuild

                bun build/package.mjs \
                  --build-mode ${lib.escapeShellArg buildMode} \
                  --target ${lib.escapeShellArg compiledTarget} \
                  --out-dir .tmp/packages \
                  --skip-archive

                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall

                install -Dm755 ".tmp/packages/${artifactName}/ncode" "$out/bin/ncode"
                install -Dm644 ".tmp/packages/${artifactName}/manifest.json" "$out/share/ncode/manifest.json"

                runHook postInstall
              '';

              postFixup = lib.optionalString stdenv.isLinux ''
                wrapProgram "$out/bin/ncode" \
                  --prefix LD_LIBRARY_PATH : ${lib.escapeShellArg runtimeLibraryPath}
              '';

              installCheckPhase = ncodeInstallCheck;
            };

          buildSourceBundle =
            buildMode:
            stdenv.mkDerivation {
              pname = "ncode-source-${buildMode}";
              inherit version;
              src = cleanSource;
              nativeBuildInputs = commonNativeBuildInputs;
              buildInputs = commonBuildInputs;

              doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;

              configurePhase = ''
                runHook preConfigure
                ${prepareBuildTree}
                runHook postConfigure
              '';

              buildPhase = ''
                runHook preBuild
                NCODE_USER_TYPE=${lib.escapeShellArg buildMode} bun build/build.mjs
                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall

                mkdir -p "$out/lib/ncode"
                cp -R dist "$out/lib/ncode/dist"
                install -Dm755 ncode "$out/lib/ncode/ncode"
                makeWrapper "$out/lib/ncode/ncode" "$out/bin/ncode" \
                  --set BUN_BIN ${lib.escapeShellArg "${pkgs.bun}/bin/bun"} \
                  --prefix LD_LIBRARY_PATH : ${lib.escapeShellArg runtimeLibraryPath}

                runHook postInstall
              '';

              installCheckPhase = ncodeInstallCheck;
            };

          buildNativeCdylib =
            {
              pname,
              crateDir,
              lockFile,
              rustStem,
              nodeName,
            }:
            pkgs.rustPlatform.buildRustPackage {
              inherit pname version;
              src = cleanSource;
              sourceRoot = "source/${crateDir}";
              cargoLock.lockFile = lockFile;
              nativeBuildInputs = [ pkgs.pkg-config ];
              buildInputs = commonBuildInputs;

              installPhase = ''
                runHook preInstall

                artifact="$(find target -type f -name 'lib${rustStem}${sharedLibraryExt}' -print -quit)"
                if [ -z "$artifact" ]; then
                  echo "Could not find built lib${rustStem}${sharedLibraryExt}" >&2
                  exit 1
                fi
                install -Dm755 "$artifact" "$out/lib/${nodeName}"

                runHook postInstall
              '';
            };

          pyReplHost = pkgs.rustPlatform.buildRustPackage {
            pname = "ncode-py-repl-host";
            inherit version;
            src = cleanSource;
            sourceRoot = "source/rust/py_repl_host";
            cargoLock.lockFile = ./rust/py_repl_host/Cargo.lock;

            installPhase = ''
              runHook preInstall

              artifact="$(find target -type f -name ncode_py_repl_host -print -quit)"
              if [ -z "$artifact" ]; then
                echo "Could not find built ncode_py_repl_host" >&2
                exit 1
              fi
              install -Dm755 "$artifact" "$out/bin/ncode_py_repl_host"

              runHook postInstall
            '';
          };

          # Single-executable Bun compilation currently produces a bare Bun binary
          # under nixpkgs Bun, so only source-level CLI builds are exposed.
          compiledPackages = { };

          sourcePackages = {
            ncode-source-external = buildSourceBundle "external";
            ncode-source-noumena = buildSourceBundle "noumena";
            ncode-source-dev = buildSourceBundle "dev";
            ncode-source-internal = buildSourceBundle "internal";
          };
        in
        {
          bun-deps = bunDeps;
          cargo-vendor = cargoVendor;
          markdown-renderer-napi = buildNativeCdylib {
            pname = "markdown-renderer-napi";
            crateDir = "native/markdown-renderer-napi";
            lockFile = ./native/markdown-renderer-napi/Cargo.lock;
            rustStem = "markdown_renderer_napi";
            nodeName = "markdown-renderer-napi.node";
          };
          openai-compat-ws-v2-napi = buildNativeCdylib {
            pname = "openai-compat-ws-v2-napi";
            crateDir = "native/openai-compat-ws-v2-napi";
            lockFile = ./native/openai-compat-ws-v2-napi/Cargo.lock;
            rustStem = "openai_compat_ws_v2_napi";
            nodeName = "openai-compat-ws-v2-napi.node";
          };
          py-repl-host = pyReplHost;
          default = sourcePackages.ncode-source-external;
        }
        // compiledPackages
        // sourcePackages
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.binutils
              pkgs.bun
              pkgs.cacert
              pkgs.cargo
              pkgs.cargo-nextest
              pkgs.clippy
              pkgs.curl
              pkgs.git
              pkgs.nodejs
              pkgs.openssl
              pkgs.pkg-config
              pkgs.python3
              pkgs.ripgrep
              pkgs.rustc
              pkgs.rustfmt
              pkgs.tmux
              pkgs.wget
              pkgs.zip
            ];

            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

            shellHook = ''
              export BUN_INSTALL_CACHE_DIR="''${BUN_INSTALL_CACHE_DIR:-$PWD/.bun-cache}"
              export NCODE_PY_REPL_PYTHON_PATH="''${NCODE_PY_REPL_PYTHON_PATH:-${pkgs.python3}/bin/python3}"

              echo "Noumena Code dev shell"
              echo "  bun install --frozen-lockfile"
              echo "  bun run build"
              echo "  bun run build:source"
              echo "  bun run test"
            '';
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          packages = self.packages.${system};
          compiledChecks = { };
        in
        {
          inherit (packages)
            markdown-renderer-napi
            ncode-source-external
            openai-compat-ws-v2-napi
            py-repl-host
            ;
        }
        // compiledChecks
      );

      apps = forAllSystems (
        system:
        let
          packages = self.packages.${system};
          appFor = name: package: {
            type = "app";
            program = "${package}/bin/ncode";
            meta.description = "Run Noumena Code (${name})";
          };
        in
        {
          default = appFor "external" packages.default;
          external = appFor "external" packages.ncode-source-external;
          noumena = appFor "noumena" packages.ncode-source-noumena;
          dev = appFor "dev" packages.ncode-source-dev;
          internal = appFor "internal" packages.ncode-source-internal;
        }
      );

      formatter = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.nixfmt
      );
    };
}
