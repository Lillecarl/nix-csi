let
  pkgs = import <nixpkgs> { };
  inherit (pkgs) lib;
  dinixEval = (
    import <dinix> {
      inherit pkgs;
      modules = [
        {
          config = {
            services.boot = {
              depends-on = [
                "ctest"
              ];
            };
            services.ctest = {
              type = "process";
              command = "${lib.getExe ctest}";
              options = [ "shares-console" ];
            };
          };
        }
      ];
    }
  );

  ctest = pkgs.stdenv.mkDerivation {
    pname = "big-binary";
    version = "0.1";

    src =
      pkgs.writeText "main.c" # c
        ''
          #include <stdio.h>
          #include <unistd.h>

          #define ARRAY_SIZE 100 * 1024 * 1024

          static char big_array[ARRAY_SIZE] = {1};

          int main() {
              printf("Binary size is large due to a static array!\n");

              // Use a volatile accumulator to prevent the loop from being optimized away.
              // This forces a read of every element in the array.
              volatile long long sum = 0;
              for (size_t i = 0; i < ARRAY_SIZE; ++i) {
                  sum += big_array[i];
              }

              // Infinite loop to keep the process alive.
              while (1) {
                  printf("Finished. Sum: %lld\n", sum);
                  sleep(1);
              }

              return 0; // Unreachable
          }
        '';

    # Skip the unpack phase for a single source file.
    dontUnpack = true;

    dontStrip = true;
    NIX_CFLAGS_COMPILE = "-O0";

    buildPhase = ''
      runHook preBuild
      $CC $NIX_CFLAGS_COMPILE -o big-binary $src
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp big-binary $out/bin/
      runHook postInstall
    '';
    meta.mainProgram = "big-binary";
  };
in
dinixEval.config.containerWrapper
