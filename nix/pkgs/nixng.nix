{
  nglib,
  nixpkgs,
  pkgs,
  ...
}:
let
  ourPkgs = pkgs;
in
nglib.makeSystem {
  inherit nixpkgs;
  inherit (pkgs) system;
  name = "nixng-nix";

  config = (
    { pkgs, ... }:
    {
      # Set nixpkgs to our preinitialized one
      nixpkgs.pkgs = ourPkgs;

      dinit.enable = true;

      nix = {
        enable = true;
        package = pkgs.lix;
        config = {
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          sandbox = false;
        };
      };

      services.attic = {
        enable = true;

        settings = {
          listen = "[::]:8080";
          database.url = "sqlite:///server.db?mode=rwc";
          token-hs256-secret-base64 = "kONlkVtBeH1PPoc7jLo0X3xKnNzuLhwYf030ghOTCH817P6jzqotxuhzRSrlOxS/VAmb5UEDobgw21EFGk8+XA==";

          storage = {
            type = "local";
            path = "/var/lib/atticd/storage";
          };

          chunking = {
            nar-size-threshold = 64 * 1024;
            min-size = 16 * 1024;
            avg-size = 64 * 1024;
            max-size = 256 * 1024;
          };
        };
      };
      environment.systemPackages = with pkgs; [
        coreutils
        fish
        bash
        git
        nix
      ];
    }
  );
}
