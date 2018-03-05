{ pkgs, ... }:
let
  inherit (pkgs) dockerTools elasticsearch;
in
{
  nixImages.elasticsearch = pkgs.dockerTools.buildImage {
    name = "my-elasticsearch";
    tag = elasticsearch.name;
    config = {
      Cmd = "${elasticsearch}/bin/elasticsearch";
    };
  };
}
