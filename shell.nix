# SPDX-License-Identifier: MIT

let
  default = import ./. { };
  inherit (default) pkgs;

  pypkgs =
    pp:
    with pp;
    [
      pytest
      pytest-asyncio
      hypothesis
      sphinx
      myst-parser
      furo
    ]
    ++ pkgs.nixkube.dependencies
    ++ pkgs.pynixd-nixkube.dependencies;
  python = pkgs.python3.withPackages pypkgs;
  xonsh = pkgs.xonsh.override {
    extraPackages = pypkgs;
  };
in
pkgs.mkShell {
  packages = [
    python
    xonsh
    pkgs.cachix
    pkgs.cargo
    pkgs.go
    pkgs.just
    pkgs.kluctl
    pkgs.kubectx
    pkgs.pyright
    pkgs.python3Packages.pylsp-mypy
    pkgs.python3Packages.pylsp-rope
    pkgs.python3Packages.python-lsp-ruff
    pkgs.python3Packages.python-lsp-server
    pkgs.regctl
    pkgs.ruff
    pkgs.rustc
    pkgs.ty
    pkgs.skopeo
    pkgs.stern
    pkgs.dive
    default.treefmt
  ];
  shellHook = # bash
    ''
      # Make LSPs that are too stupid to run python to check environment happy
      export PYTHONPATH="${python}/${python.sitePackages}:$PYTHONPATH"
    '';
}
