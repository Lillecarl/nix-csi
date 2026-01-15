let
  default = import ./. {};
  inherit (default) pkgs;
in
pkgs.mkShell {
  packages = [
    default.python
    default.xonsh
    pkgs.cachix
    pkgs.ruff
    pkgs.kluctl
    pkgs.stern
    pkgs.kubectx
    pkgs.skopeo
    pkgs.regctl
  ];
  shellHook = # bash
  ''
    export PYTHONPATH="${default.python}/${default.python.sitePackages}:$PYTHONPATH"
  '';
}
