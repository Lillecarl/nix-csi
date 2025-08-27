{
  kubenix,
  ...
}:
{
  imports = [
    kubenix.modules.k8s
    ./namespace.nix
    ./daemonset.nix
    ./crd.nix
    ./csidriver.nix
    ./storageclass.nix
  ];
}
