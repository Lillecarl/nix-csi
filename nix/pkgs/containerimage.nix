# You could easily get tempted to create folders that go into container root
# using copyToRoot but it's easy to shoot yourself in the foot with Kubernetes
# mounting it's own shit over those paths making a mess out of your life.
{
  lib,
  writeScriptBin,
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
  fishDinitLauncher =
    writeScriptBin "fishDinitLauncher" # fish
      ''
        #! ${lib.getExe fish}
        mkdir -p /run
        exec ${lib.getExe dinixEval.config.dinitLauncher} --container
      '';
  initCopy =
    writeScriptBin "initCopy" # fish
      ''
        #! ${lib.getExe fish}
        exec ${lib.getExe rsync} --verbose --archive --ignore-existing /nix/ /nix2/
      '';
  rootEnv = buildEnv {
    name = "rootEnv";
    paths = rootPaths;
  };
  rootPaths = [
    initCopy
    fishDinitLauncher
    dinixEval.config.package
    rsync
    util-linux
    lix
    git
    fish
    uutils-coreutils-noprefix
    dockerTools.caCertificates
    nixUserGroupShadow
  ];
in
buildImage {
  name = "nix-csi";
  # Links derivation into containers root
  copyToRoot = rootEnv;
  # Storepaths to bring into container
  # layers = rootPaths ++ [ fishDinitLauncher ];
  # Image configuration
  config = {
    Env = [
      "USER=nix"
      "HOME=/home/nix"
      "PATH=/bin"
    ];
    Entrypoint = [ (lib.getExe fishDinitLauncher) ];
    WorkingDir = "/home/nix-csi";
  };
}
