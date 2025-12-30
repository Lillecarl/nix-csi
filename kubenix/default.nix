{ ... }:
{
  imports = [
    ./options.nix
    ./namespace.nix
    ./daemonset.nix
    ./csidriver.nix
    ./config.nix
    ./cache.nix
    ./rbac.nix
    ./ctest.nix
    ./undeploy.nix
    ./secret.nix
  ];
}
