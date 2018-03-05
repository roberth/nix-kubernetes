{ lib, config, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.images = mkOption {
    description = "A set of images to use in this configuration";
    type = types.attrsOf types.str;
    default = {};
    example = { elasticsearch = "quay.io/pires/docker-elasticsearch-kubernetes:1.7.2"; };
  };
}
