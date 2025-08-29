{ lib, ... }:
{
  options = {
    cknixNamespace = lib.mkOption {
      description = "Which namespace to deploy cknix resources too";
      type = lib.types.str;
      default = "default";
    };
  };
}
