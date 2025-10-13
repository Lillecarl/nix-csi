{ config, lib, ... }:
{
  config.kubernetes.resources.${config.namespace}.ConfigMap.nix-config.data."nix.conf" = ''
    # Use root as builder since that's the only user in the container.
    build-users-group = root
    # Auto allocare uids so we don't have to create lots of users in containers
    auto-allocate-uids = true
    # Enable common features
    experimental-features = nix-command flakes auto-allocate-uids fetch-closure pipe-operator
    # Don't cache anything that can cause Nix to not try other caches on failure.
    narinfo-cache-negative-ttl = 0
    narinfo-cache-positive-ttl = 0
    # binary cache configuration
    ${lib.optionalString config.enableBinaryCache ''
      trusted-public-keys = ${builtins.readFile ../cache-public} cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      substituters = http://nix-cache.${config.namespace}.svc https://cache.nixos.org
    ''}
    # Fuck purity
    warn-dirty = false
  '';
}
