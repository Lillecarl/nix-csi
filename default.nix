let
  npins = import ./npins;
  flake-compat = import npins.flake-compat;
  # flake-compat = import /home/lillecarl/Code/flake-compat;
  flake = flake-compat {
    src = (builtins.toString ./.);
    copySourceTreeToStore = false;
  };
  system = builtins.currentSystem;
in
flake.outputs // {
  spkgs = flake.outputs.legacyPackages.${system};
  spackages = flake.outputs.packages.${system};
}
