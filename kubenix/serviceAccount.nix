{ ... }:
{
  config = {
    kubernetes.api.resources.serviceAccounts.cknix = {
      metadata.namespace = "default";
    };
  };
}
