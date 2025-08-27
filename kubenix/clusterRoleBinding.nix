{ ... }:
{
  config = {
    kubernetes.api.resources.clusterRoleBindings."cknix-binding" = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "cknix";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "cknix";
          namespace = "default";
        }
      ];
    };
  };
}
