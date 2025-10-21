{
  pkgs,
  dinix,
  nix2container,
}:
let
  dinixEval = import ./dinixEval.nix { inherit pkgs dinix; };
in
import ./containerImage.nix { inherit pkgs dinixEval nix2container; }
