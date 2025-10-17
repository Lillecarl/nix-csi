{ config, lib, ... }:
let
  cfg = config.nix-csi;
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.${cfg.namespace}.ConfigMap.nix-config.data."nix.conf" = ''
      # Use root as builder since that's the only user in the container.
      build-users-group = root
      # Auto allocare uids so we don't have to create lots of users in containers
      auto-allocate-uids = true
      # This supposedly helps with the sticky cache issue
      fallback = true
      # Enable common features
      experimental-features = nix-command flakes auto-allocate-uids fetch-closure pipe-operator
      # binary cache configuration
      ${lib.optionalString cfg.enableBinaryCache ''
        trusted-public-keys = ${builtins.readFile ../cache-public} cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
        substituters = http://nix-cache.${cfg.namespace}.svc https://cache.nixos.org
      ''}
      # Fuck purity
      warn-dirty = false
    '';
  };
}
