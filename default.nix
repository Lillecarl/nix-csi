let
  npins = import ./npins;
  flake-compat = import npins.flake-compat;
  # flake-compat = import /home/lillecarl/Code/flake-compat;
  flake = flake-compat {
    src = (builtins.toString ./.);
    copySourceTreeToStore = false;
  };
in
flake.outputs
