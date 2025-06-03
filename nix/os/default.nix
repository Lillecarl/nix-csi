
{ pkgs, lib, config, ... }:
{
  boot.isContainer = true;
  services.atticd = {
    enable = false;
  };
}
