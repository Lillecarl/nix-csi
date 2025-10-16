{
  pkgs,
  ...
}:
{
  imports = [
    ./options.nix
    ./namespace.nix
    ./daemonset.nix
    ./csidriver.nix
    ./storageclass.nix
    ./config.nix
    ./cache.nix
  ];
  config = {
    kluctl.package = pkgs.kluctl.override { python310 = pkgs.python3; };
  };
}
