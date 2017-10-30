{lib, k8s, ...}:

with lib;

{
  config = {
    kubernetes.moduleDefinitions.nginx.module = {name, config, ...}: {
      options = {
        port = mkOption {
          description = "Port for nginx to listen on";
          type = types.int;
          default = 80;
        };
      };

      config = {
        kubernetes.resources.deployments."${name}-nginx" = mkMerge [
          (k8s.loadJSON ./deployment.json)
          {
            metadata.name = mkForce "${name}-nginx";
            spec.template.spec.containers.nginx.ports = mkForce [{
              containerPort = config.port;
            }];
          }
        ];
      };
    };

    kubernetes.modules.app-v1.module = "nginx";
    kubernetes.modules.app-v2 = {
      module = "nginx";
      configuration.port = 8080;
    };

    kubernetes.resources.services.nginx = k8s.loadJSON ./service.json;
  };
}
