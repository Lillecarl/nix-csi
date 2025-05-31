{
  dockerTools,
  buildEnv,
  coreutils,
  fish,
  nix,
  ...
}:
let
  env = buildEnv {
    name = "containerEnv";
    paths = [
      nix
      coreutils
      fish
    ];
  };
in
dockerTools.streamLayeredImage {
  name = "barebones-fish";
  tag = "latest";
  contents = [
    env
  ];
  config = {
    Cmd = [
      "${coreutils}/bin/sleep"
      "infinity"
    ];
    Env = [
      "USER=nix"
      "HOME=/root"
      "SHELL=${env}/bin/fish"
      "PATH=${env}/bin"
    ];
    WorkingDir = "/root";
  };
}
