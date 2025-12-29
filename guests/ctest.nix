{
  pkgs ? import <nixpkgs> { },
}:
let
  ctest = pkgs.stdenv.mkDerivation {
    pname = "big-binary";
    version = "0.1";

    src =
      pkgs.writeText "main.c" # c
        ''
          #include <stdio.h>
          #include <unistd.h>
          #include <signal.h> // Required for signal handling
          #include <stdbool.h> // Required for bool type

          // ${toString builtins.currentTime}

          #define ARRAY_SIZE 100 * 1024 * 1024

          static char big_array[ARRAY_SIZE] = {1};

          // Volatile flag to ensure visibility across threads/signal handlers
          volatile bool shutdown_requested = false;

          // Signal handler function
          void handle_shutdown_signal(int signum) {
              printf("\nReceived signal %d. Initiating graceful shutdown...\n", signum);
              shutdown_requested = true;
          }

          int main() {
              // Register signal handlers for SIGINT and SIGTERM
              signal(SIGINT, handle_shutdown_signal);
              signal(SIGTERM, handle_shutdown_signal);

              printf("Binary size is large due to a static array!\n");

              // Use a volatile accumulator to prevent the loop from being optimized away.
              // This forces a read of every element in the array.
              volatile long long sum = 0;
              for (size_t i = 0; i < ARRAY_SIZE; ++i) {
                  sum += big_array[i];
              }

              printf("Finished array sum. Sum: %lld\n", sum);

              // Loop to keep the process alive, checking for shutdown requests
              while (!shutdown_requested) {
                  printf("Application running...\n");
                  sleep(1);
              }

              printf("Graceful shutdown complete. Exiting.\n");
              return 0;
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
pkgs.buildEnv {
  name = "ctestenv";
  paths = [
    ctest
    pkgs.fishMinimal
    pkgs.lixPackageSets.lix_2_93.lix
  ];
  meta.mainProgram = ctest.meta.mainProgram;
}
