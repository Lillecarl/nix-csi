{
  kubenix,
  ...
}:
{
  imports = [
    kubenix.modules.k8s
    ./options.nix
    ./namespace.nix
    ./daemonset.nix
    ./csidriver.nix
    ./storageclass.nix
    ./config.nix
    ./cache.nix
    ./testDeploy.nix
  ];
}
