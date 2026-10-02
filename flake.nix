{
  description = "ROM-driven Spy Hunter sound-board player and music investigation";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/c0a89c379b4ac67c7b13b051ddbd4e0dbc9b0eaf";
  };
  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      each = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
      fs = nixpkgs.lib.fileset;
      version = "0.2.0";

      # Pinned Musashi and floooh/chips sources from build.zig.zon, fetched
      # once into a fixed-output derivation; update the hash when the zon changes.
      zigDepsHash = "sha256-ZeN2KuUNWuBjRNW0W4+nvbAR34rkarNPDhfALgSAU1g=";
      zigDeps = pkgs: pkgs.stdenv.mkDerivation {
        pname = "spy-hunter-music-zig-deps";
        inherit version;
        src = fs.toSource { root = ./.; fileset = fs.unions [ ./build.zig ./build.zig.zon ]; };
        nativeBuildInputs = [ pkgs.zig pkgs.git pkgs.cacert ];
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = zigDepsHash;
        dontConfigure = true;
        buildPhase = ''
          export HOME=$TMPDIR
          export ZIG_GLOBAL_CACHE_DIR=$out
          export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
          zig build --fetch=all
          rm -rf $out/tmp $out/z
        '';
        dontInstall = true;
        dontFixup = true;
      };

      # Native package inputs are source only. The sound-board image and every
      # compiled executable stay out of this derivation; the web build uses them.
      packageSource = fs.toSource {
        root = ./.;
        fileset = fs.difference
          (fs.unions [ ./build.zig ./build.zig.zon ./src ./include ./build ./bin/spy-hunter-music ])
          ./src/web/sound_image.bin;
      };
      testSource = fs.toSource {
        root = ./.;
        fileset = fs.unions [ ./build.zig ./build.zig.zon ./src ./include ./tests ./web ./assets ./build ./bin/spy-hunter-music ];
      };
      zigEnv = pkgs: ''
        export HOME=$TMPDIR
        export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
        mkdir -p $ZIG_GLOBAL_CACHE_DIR
        cp -r ${zigDeps pkgs}/. $ZIG_GLOBAL_CACHE_DIR/
        chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
      '';
      zigBuildInputs = pkgs: {
        nativeBuildInputs = [ pkgs.zig pkgs.pkg-config ];
        buildInputs = [ pkgs.SDL2 ];
      };

      package = pkgs: pkgs.stdenv.mkDerivation ((zigBuildInputs pkgs) // {
        pname = "spy-hunter-music";
        inherit version;
        src = packageSource;
        strictDeps = true;
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          ${zigEnv pkgs}
          zig build -Doptimize=ReleaseFast -Dcpu=baseline --prefix $out
          runHook postBuild
        '';
        dontInstall = true;
        meta.mainProgram = "spy-hunter-music";
      });

      test = pkgs: pkgs.stdenv.mkDerivation ((zigBuildInputs pkgs) // {
        pname = "spy-hunter-music-tests";
        inherit version;
        src = testSource;
        strictDeps = true;
        dontConfigure = true;
        nativeCheckInputs = [ pkgs.bash ];
        nativeBuildInputs = (zigBuildInputs pkgs).nativeBuildInputs ++ [ pkgs.nodejs ];
        buildPhase = ''
          ${zigEnv pkgs}
          patchShebangs tests build bin
          failures=0
          zig build test -Dcpu=baseline || failures=$((failures + 1))
          zig build -Dcpu=baseline || failures=$((failures + 1))
          export SPY_HUNTER_BIN=$PWD/zig-out/bin/spy-hunter-music
          for suite in tests/cli tests/terminal tests/build tests/web/run tests/rom/run; do
            bash "$suite" || failures=$((failures + 1))
          done
          [ "$failures" -eq 0 ]
        '';
        installPhase = "touch $out";
      });
    in {
      packages = each (pkgs: { default = package pkgs; zig-deps = zigDeps pkgs; });
      apps = each (pkgs: { default = {
        type = "app";
        program = "${package pkgs}/bin/spy-hunter-music";
        meta.description = "Play locally supplied Spy Hunter arcade sound ROMs";
      }; });
      devShells = each (pkgs: { default = pkgs.mkShell {
        packages = [ pkgs.zig pkgs.pkg-config pkgs.SDL2 pkgs.stdenv.cc pkgs.nodejs pkgs.darkhttpd pkgs.zip pkgs.unzip ];
      }; });
      checks = each (pkgs: { package = package pkgs; test = test pkgs; });
    };
}
