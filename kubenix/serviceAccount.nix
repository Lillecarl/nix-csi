{ config, ... }:
{
  config = {
    kubernetes.api.resources.serviceAccounts.nix-csi = {
      metadata.namespace = config.namespace;
    };
  };
}
