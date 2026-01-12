{
  pkgs,
  lib,
  config,
  ...
}:
{
  options.gc = {
    retainSeconds = lib.mkOption {
      type = lib.types.ints.positive;
    };
    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
    };
  };
  config = {
    logger.files = [
      "gc.log"
    ];
    services.gc = {
      command = pkgs.writeShellApplication {
        name = "gc";
        runtimeInputs = [
          pkgs.lruLix
          pkgs.jq
        ];
        text =
          let
            rs = toString config.gc.retainSeconds;
            lis = toString (config.gc.intervalSeconds / 2);
            uis = toString config.gc.intervalSeconds;
          in
          # bash
          ''
            while :; do
              # Copy everything to cache
              CACHE_ENABLED="''${CACHE_ENABLED:-false}"
              if test "$CACHE_ENABLED" = "true"; then
                nix copy --all --store local --to ssh-ng://nix@nix-cache || true
              fi
              # Garbage collect anything older than an hour
              nix path-info --store local --all --json | \
                jq -r --argjson age ${rs} 'map(select(.registrationTime < (now - $age)) | .path) | .[]' | \
                nix store delete --store local --stdin --skip-live
              # chill
              SLEEP=$(shuf -i ${lis}-${uis} -n 1)
              echo Sleeping for "$SLEEP" seconds
              sleep "$SLEEP"
            done
          '';
      };
      log-type = "file";
      logfile = "/var/log/gc.log";
      depends-on = [
        "setup"
        "nix-daemon"
      ];
    };
  };
}
