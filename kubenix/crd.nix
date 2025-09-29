{ ... }:
{
  config = {
    kubernetes.api.resources.customResourceDefinitions."expressions.nix.csi" = {
      spec = {
        conversion.strategy = "None";
        group = "nix.csi";
        names = {
          kind = "Expression";
          listKind = "ExpressionList";
          plural = "expressions";
          shortNames = [
            "expr"
            "kx"
          ];
          singular = "expression";
        };
        scope = "Namespaced";
        versions = [
          {
            additionalPrinterColumns = [
              {
                jsonPath = ".data.expr";
                name = "Expression";
                type = "string";
              }
              {
                jsonPath = ".status.phase";
                name = "Status";
                type = "string";
              }
            ];
            name = "v1";
            schema.openAPIV3Schema = {
              properties = {
                data = {
                  properties.expr = {
                    description = "Expression to be evaluated";
                    type = "string";
                  };
                  required = [ "expr" ];
                  type = "object";
                };
                status = {
                  properties = {
                    message = {
                      description = "Human-readable message indicating details about the current status";
                      type = "string";
                    };
                    phase = {
                      description = "Current phase of the resource (Pending, Running, Succeeded, Failed)";
                      type = "string";
                    };
                    result = {
                      description = "Result (storePath) of the expression evaluation";
                      type = "string";
                    };
                    gcRoots = {
                      description = "List of GC root objects produced by the expression evaluation";
                      type = "array";
                      items = {
                        type = "object";
                        properties = {
                          packageName = {
                            description = "Name (with hash) of package";
                            type = "string";
                          };
                          pathHash = {
                            description = "Hash of the mount location on the node";
                            type = "string";
                          };
                        };
                      };
                    };
                  };
                  type = "object";
                };
              };
              type = "object";
            };
            served = true;
            storage = true;
            subresources.status = { };
          }
        ];
      };
    };
  };
}
