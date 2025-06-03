{
  pkgs,
}:
let
  initCopy =
    pkgs.writeScriptBin "initCopy" # fish
      ''
        #! ${pkgs.lib.getExe pkgs.fish}
        set initFile /nix2/var/initialized
        if ! test -f $initFile
          cp --verbose --archive --recursive --update=none /nix/. /nix2/
          mkdir -p $(dirname $initFile)
          touch $initFile
        else
          echo "Already copied store from image"
        end
        exit 0
      '';
  supervisord =
    pkgs.writeScriptBin "supervisord" # fish
      ''
        #! ${pkgs.lib.getExe pkgs.fish}
        set PKG $(nix build --no-link --print-out-paths --file /knix/default.nix spackages.supervisord.outPath)
        ln --symbolic --force $PKG/. /nix/var/nix/gcroots/supervisor/
        exec $PKG/bin/supervisord --nodaemon $argv
      '';
  supervisorctl =
    pkgs.writeScriptBin "supervisorctl" # fish
      ''
        #! ${pkgs.lib.getExe pkgs.fish}
        exec /nix/var/nix/gcroots/supervisor/bin/supervisorctl $argv
        exec /nix/var/nix/gcroots/supervisor/bin/supervisorctl
      '';
  svc =
    pkgs.writeScriptBin "svc" # fish
      ''
        #! ${pkgs.lib.getExe pkgs.fish}
        exec /nix/var/nix/gcroots/supervisor/bin/supervisorctl $argv
      '';
  nixConf = pkgs.writeTextFile {
    name = "nixConfig";
    text = builtins.readFile ./nix.conf;
    destination = "/etc/nix/nix.conf";
  };
  folders = pkgs.runCommand "folders" { } ''
    mkdir -p $out/tmp
    mkdir -p $out/var/log
    mkdir -p $out/var/lib/attic
    mkdir -p $out/etc
    mkdir -p $out/run
    mkdir -p $out/home/nix
  '';
  miniPaths =
    (with pkgs; [
      lix
      fish
      git
      coreutils
      bash
      dockerTools.caCertificates
    ])
    ++ [
      initCopy
      nixConf
      supervisord
      supervisorctl
      svc
      ((import ../dockerUtils.nix pkgs).nonRootShadowSetup {
        users = [
          {
            name = "root";
            id = 0;
          }
          {
            name = "nix";
            id = 1000;
          }
          {
            name = "nixbld";
            id = 1001;
          }
        ];
        shell = pkgs.lib.getExe pkgs.fish;
      })
    ];
  miniEnv = pkgs.buildEnv {
    name = "miniEnv";
    paths = miniPaths;
  };
in
pkgs.dockerTools.streamLayeredImage {
  name = "knix-csi";
  tag = "latest";
  contents = [
    folders
    miniPaths
  ];
  maxLayers = 125;
  config = {
    Env = [
      "USER=nix"
      "HOME=/home/nix"
      "PATH=${miniEnv}/bin:/bin:/run/current-system/bin"
      "EDITOR=hx"
    ];
    WorkingDir = "/home/nix";
    fakeRootCommands = ''
      ln --symbolic --force ${miniEnv}/bin /run/current-system
    '';
    enableFakechroot = true;
  };
}
