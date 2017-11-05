{lib, pkgs}:

with lib;

rec {
  mkAllDefault = value:
    if isAttrs value
    then mapAttrs (n: v: mkAllDefault v) value

    else if isList value
    then map (v: mkAllDefault v) value

    else mkDefault value;

  moduleToAttrs = value:
    if isAttrs value
    then mapAttrs (n: v: moduleToAttrs v) (filterAttrs (n: v: !(hasPrefix "_" n) && v != null) value)

    else if isList value
    then map (v: moduleToAttrs v) value

    else value;

  loadJSON = path: mkAllDefault (builtins.fromJSON (builtins.readFile path));

  loadYAML = path: loadJSON (pkgs.runCommand "yaml-to-json" {
    path = [pkgs.remarshal];
  } "remarshal -i ${path} -if yaml -of json > $out");
}
