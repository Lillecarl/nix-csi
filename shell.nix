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
    (default.inputs.treefmt-nix.lib.mkWrapper pkgs {
      projectRootFile = "flake.nix";
      programs.nixfmt.enable = true;
      programs.ruff-format.enable = true;
      programs.shellcheck.enable = true;
      programs.fish_indent.enable = true;
    })
  ];
  shellHook = # bash
  ''
    export PYTHONPATH="${default.python}/${default.python.sitePackages}:$PYTHONPATH"
  '';
}
