{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-compatish = {
      url = "github:lillecarl/flake-compatish";
      flake = false;
    };
    easykubenix = {
      url = "github:lillecarl/easykubenix";
      flake = false;
    };
    dinix = {
      url = "github:lillecarl/dinix";
      flake = false;
    };
  };
  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
      gen = func: lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] func;
    in
    {
      packages = gen (
        system:
        let
          pkgs = import inputs.nixpkgs { inherit system; };
        in
        {
          inherit (pkgs) hello;
        }
      );
    };
}
