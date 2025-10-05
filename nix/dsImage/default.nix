{
  pkgs,
  dinix,
  buildImage,
  nix-csi,
}:
let
  dinixEval = import ./dinixEval.nix { inherit pkgs dinix nix-csi; };
in
import ./containerImage.nix { inherit pkgs dinixEval buildImage; }
