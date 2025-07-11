{
  kubenix,
  config,
  lib,
  ...
}:
{
  imports = [
    kubenix.modules.k8s
    ./namespace.nix
  ];
}