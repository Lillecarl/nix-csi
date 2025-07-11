pkgs: {
  # users:  [ { name = "alice"; id = 1000; shell = "/bin/sh"; }, ... ]
  # shell:  Optional global shell for users that don't specify their own
  # This creates passwd, shadow, group, gshadow, and nsswitch.conf for all users (each user gets a group with the same name/id).
  nonRootShadowSetup =
    {
      users,
      shell ? "${pkgs.runtimeShell}",
    }:
    let
      passwdEntries = map (
        user:
        "${user.name}:x:${toString user.id}:${toString user.id}::/home/${user.name}:${
          if user ? shell then user.shell else shell
        }"
      ) users;

      shadowEntries = map (user: "${user.name}:!:::::::") users;

      groupEntries = map (user: "${user.name}:x:${toString user.id}:${toString user.name}") users;

      gshadowEntries = map (user: "${user.name}:x::") users;

    in
    pkgs.buildEnv {
      name = "usersgroups";
      paths = [
        (pkgs.writeTextDir "etc/passwd" (builtins.concatStringsSep "\n" passwdEntries + "\n"))
        (pkgs.writeTextDir "etc/shadow" (builtins.concatStringsSep "\n" shadowEntries + "\n"))
        (pkgs.writeTextDir "etc/group" (builtins.concatStringsSep "\n" groupEntries + "\n"))
        (pkgs.writeTextDir "etc/gshadow" (builtins.concatStringsSep "\n" gshadowEntries + "\n"))
        (pkgs.writeTextDir "etc/nsswitch.conf" ''
          hosts: files dns
        '')
      ];
    };
}
