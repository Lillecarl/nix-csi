{
  kubenix,
  config,
  lib,
  ...
}:
let
  namespace = "cknix";
in
{
  # Create cknix namespace
  kubernetes.api.resources.namespaces.${namespace} = {
    metadata = {
      name = namespace;
      labels = {
        "app.kubernetes.io/name" = "cknix";
        "app.kubernetes.io/component" = "namespace";
        "app.kubernetes.io/managed-by" = "kubenix";
      };
    };
  };
}