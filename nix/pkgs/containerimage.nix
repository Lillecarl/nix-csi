{
  bash,
  buildEnv,
  coreutils,
  dockerTools,
  fish,
  git,
  nix,
  writeTextFile,
  ...
}:
let
  nixConf = writeTextFile {  
    name = "nixConfig";
    text = builtins.readFile ./nix.conf;
    destination = "/etc/nix/nix.conf";
  };
  env = buildEnv {
    name = "containerEnv";
    paths = [
      bash
      coreutils
      dockerTools.binSh
      dockerTools.caCertificates
      dockerTools.fakeNss
      fish
      git
      nix
      nixConf
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
