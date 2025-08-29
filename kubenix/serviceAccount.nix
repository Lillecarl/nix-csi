{ config, ... }:
{
  config = {
    kubernetes.api.resources.serviceAccounts.cknix = {
      metadata.namespace = config.cknixNamespace;
    };
  };
}
