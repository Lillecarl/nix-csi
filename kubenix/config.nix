{ config, lib, ... }:
{
  config = {
    kubernetes.resources.configMaps.nix-config = {
      metadata.namespace = config.namespace;
      data."nix.conf" = ''
        # build-users-group = root
        auto-allocate-uids = true
        experimental-features = nix-command flakes auto-allocate-uids fetch-closure
        ${lib.optionalString config.enableBinaryCache ''
          trusted-public-keys = ${builtins.readFile ../cache-public} cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
          substituters = http://nix-cache.${config.namespace}.svc https://cache.nixos.org
        ''}
      '';
    };
  };
}
