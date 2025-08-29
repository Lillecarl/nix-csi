{
  config,
  lib,
  ...
}:
let
  namespace = config.cknixNamespace;
in
{
  config = lib.mkIf (namespace != "default") {
    # Create cknix namespace
    kubernetes.api.resources.namespaces.${namespace} = {
      metadata = {
        name = namespace;
      };
    };
  };
}
