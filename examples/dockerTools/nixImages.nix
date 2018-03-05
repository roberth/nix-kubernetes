{ lib, pkgs, config, ... }:
let
  inherit (lib) mkOption types literalExample;
  inherit (pkgs.lib) mapAttrs;
in
{
  options.nixImages = mkOption {
    description = "A set of images to use in this configuration, as built by Nixpkgs' dockerTools, to be merged into the images option.";
    type = types.attrsOf types.attrs;
    default = {};
    example = literalExample ''
      { elasticsearch = pkgs.dockerTools.buildImage { ... }; }
    '';
  };
  config.images = mapAttrs (_: value: value.imageName + ":" + value.imageTag) config.nixImages;
}
