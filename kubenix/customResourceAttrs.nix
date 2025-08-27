{ config, lib, ... }:
{
  options = {
    kubernetes.customResourceAttrs = lib.mkOption {
      description = "Custom Resources with string key for merging";
      type = lib.types.attrsOf (
        lib.types.submodule {
          freeformType = lib.types.anything;
          options = {
            apiVersion = lib.mkOption {
              type = lib.types.str;
              description = "API version";
            };
            kind = lib.mkOption {
              type = lib.types.str;
              description = "Object kind";
            };
            metadata = lib.mkOption {
              type = lib.types.submodule {
                freeformType = lib.types.anything;
                options.name = lib.mkOption {
                  type = lib.types.str;
                  description = "Object name";
                };
              };
              description = "Resource metadata";
            };
          };
        }
      );
      default = { };
    };
  };
  config = {
    kubernetes.objects = lib.pipe config.kubernetes.customResourceAttrs [
      lib.attrsToList
      (lib.map (x: x.value))
    ];
  };
}
