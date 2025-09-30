{
  lib,
  writeScriptBin,
  runCommand,
  dockerTools,
  buildEnv,
  buildImage,
  rsync,
  dinixEval,
  lix,
  git,
  uutils-coreutils-noprefix,
  util-linux,

  nixUserGroupShadow,
  fish,
}:
let
  mkdir = lib.getExe' uutils-coreutils-noprefix "mkdir";
  dirname = lib.getExe' uutils-coreutils-noprefix "dirname";
  touch = lib.getExe' uutils-coreutils-noprefix "touch";
  initCopy =
    writeScriptBin "initCopy" # fish
      ''
        #! ${lib.getExe fish}
        set initFile /nix2/var/initialized
        if ! test -f $initFile
          ${rsync} --verbose --archive --ignore-existing /nix/. /nix2/
          ${mkdir} -p $(${dirname} $initFile)
          ${touch} $initFile
        else
          echo "Already copied store from image"
        end
        exit 0
      '';
  folders = runCommand "folders" { } ''
    ${mkdir} -p $out/tmp
    ${mkdir} -p $out/var/log
    ${mkdir} -p $out/home/nix
    ${mkdir} -p $out/home/root
  '';
  rootEnv = buildEnv {
    name = "rootEnv";
    paths = rootPaths;
  };
  rootPaths = [
    initCopy
    dinixEval.config.dinitLauncher
    dinixEval.config.package
    rsync
    util-linux
    lix
    git
    folders
    fish
    uutils-coreutils-noprefix
    dockerTools.caCertificates
    nixUserGroupShadow
  ];
in
buildImage {
  name = "nix-csi";
  copyToRoot = rootEnv;
  config = {
    Env = [
      "USER=nix"
      "HOME=/home/nix"
      "PATH=/bin"
    ];
    Entrypoint = [ (lib.getExe dinixEval.config.dinitLauncher) ];
    WorkingDir = "/home/nix-csi";
  };
}
