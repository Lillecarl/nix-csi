{ ... }:
{
  imports = [
    ./options.nix
    ./namespace.nix
    ./daemonset.nix
    ./csidriver.nix
    ./storageclass.nix
    ./config.nix
    ./cache.nix
    ./rbac.nix
    ./ctest.nix
    ./undeploy.nix
  ];
}
