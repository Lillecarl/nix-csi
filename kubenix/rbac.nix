{ config, lib, ... }:
let
  cfg = config.nix-csi;
in
{
  config = lib.mkIf cfg.enable {
    kubernetes.resources.${cfg.namespace} = {
      ServiceAccount.nix-csi = { };

      Role.nix-csi = {
        rules = [
          {
            # Full control over Jobs in the "batch" API group.
            apiGroups = [ "batch" ];
            resources = [ "jobs" ];
            verbs = [
              "create"
              "get"
              "list"
              "watch"
              "delete"
              "patch"
            ];
          }
          {
            # Read-only access to Pods and their logs in the core API group.
            apiGroups = [ "" ];
            resources = [
              "pods"
              "pods/log"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          {
            # Permissions for creating, managing, and owning ConfigMaps.
            apiGroups = [ "" ]; # ConfigMaps are in the core API group
            resources = [ "configmaps" ];
            verbs = [
              "create"
              "get"
              "list"
              "watch"
              "patch"
              "delete"
            ];
          }
        ];
      };

      # Binds the Role to the ServiceAccount.
      RoleBinding.nix-csi = {
        subjects = [
          {
            kind = "ServiceAccount";
            name = "nix-csi";
            namespace = cfg.namespace;
          }
        ];
        roleRef = {
          kind = "Role";
          name = "nix-csi";
          apiGroup = "rbac.authorization.k8s.io";
        };
      };
    };
  };
}
