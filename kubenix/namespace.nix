{
  config,
  lib,
  ...
}:
let
  namespace = config.namespace;
in
{
  config.kubernetes.resources.none = lib.mkIf (namespace != "default") {
    Namespace.${namespace} = { };
  };
}
