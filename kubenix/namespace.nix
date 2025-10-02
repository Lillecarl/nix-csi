{
  config,
  lib,
  ...
}:
let
  namespace = config.namespace;
in
{
  config = lib.mkIf (namespace != "default") {
    kubernetes.api.resources.namespaces.${namespace} = {
      metadata.name = namespace;
    };
  };
}
