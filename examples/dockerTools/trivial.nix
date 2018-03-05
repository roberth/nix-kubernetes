{
  default = {config, ...}: let inherit (config) images; in {

    imports = [
      ./images.nix
      ./nixImages.nix
      ./myImages.nix
    ];
    # Elasticserach replication controller
    kubernetes.controllers.elasticsearch = {
      dependencies = ["services/elasticsearch" "pvc/elasticsearch"];
      pod.containers.elasticsearch = {
        image = images.elasticsearch;
        env = {
          NAMESPACE = "default";
          CLUSTER_NAME = "my_cluster";
          NODE_MASTER = "true";
          NODE_DATA = "true";
          HTTP_ENABLE = "true";
        };
        ports = [{ port = 9200; } { port = 9300; }];
        mounts = [{
          name = "storage";
          mountPath = "/data";
        }];
        security.capabilities.add = ["IPC_LOCK"];
      };

      pod.volumes.storage = {
        type = "persistentVolumeClaim";
        options.claimName = "elasticsearch";
      };
    };

    # Elasticsearch load balancer
    kubernetes.services.elasticsearch.ports = [{ port = 9200; }];

    # Elasticsearch persistent volume claim
    kubernetes.pvc.elasticsearch.size = "1G";
  };
}
