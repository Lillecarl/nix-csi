let
  flake-compat = import (builtins.fetchTree {
    type = "git";
    url = "https://git.lix.systems/lix-project/flake-compat.git";
  });
  flake = flake-compat {
    src = (builtins.toString ./.);
    copySourceTreeToStore = false;
  };
  system = builtins.currentSystem;
in
flake.outputs // {
  pkgs = flake.outputs.legacyPackages.${system};
  packages = flake.outputs.packages.${system};
}
