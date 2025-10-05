{ config, lib, ... }:
{
  config = {
    kubernetes.resources.configMaps.nix-config = {
      metadata.namespace = config.namespace;
      data."nix.conf" = ''
        # build-users-group = root
        auto-allocate-uids = true
        experimental-features = nix-command flakes auto-allocate-uids fetch-closure
        trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= ${builtins.readFile ../cache-public}
        substituters = http://nix-cache.${config.namespace} https://cache.nixos.org
      '';
    };
  };
}
