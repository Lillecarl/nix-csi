{ ... }:
{
  config = {
    kubernetes.api.resources.clusterRoleBindings."nix-csi-binding" = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "nix-csi";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "nix-csi";
          namespace = "default";
        }
      ];
    };
  };
}
