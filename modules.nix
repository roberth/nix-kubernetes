{ config, lib, pkgs, k8s, ... }:

with lib;
with import ./lib.nix { inherit pkgs lib; };

let
  evalK8SModule = {module, name, configuration}: evalModules {
    modules = [
      ./kubernetes.nix module configuration
    ] ++ config.kubernetes.defaultModuleConfiguration;
    args = {
      inherit pkgs k8s name;
    };
  };
in {
  options.kubernetes.defaultModuleConfiguration = mkOption {
    description = "Default configuration for kubernetes modules";
    type = types.listOf types.attrs;
    default = {};
  };

  options.kubernetes.moduleDefinitions = mkOption {
    description = "Attribute set of module definitions";
    default = {};
    type = types.attrsOf (types.submodule ({name, ...}: {
      options = {
        name = mkOption {
          description = "Module definition name";
          type = types.str;
          default = name;
        };

        module = mkOption {
          description = "Module definition";
        };
      };
    }));
  };

  options.kubernetes.modules = mkOption {
    description = "Attribute set of module definitions";
    default = {};
    type = types.attrsOf (types.submodule ({name, ...}: {
      options = {
        name = mkOption {
          description = "Module name";
          type = types.str;
          default = name;
        };

        configuration = mkOption {
          description = "Module configuration";
          type = types.attrs;
          default = {};
        };

        module = mkOption {
          description = "Name of the module to use";
          type = types.str;
        };
      };
    }));
  };

  config = {
    kubernetes.resources = mkMerge (
      mapAttrsToList (name: module:
        let
          evaledService = evalK8SModule {
            module = config.kubernetes.moduleDefinitions.${module.module}.module;
            inherit (module) name configuration;
          };
          resources = moduleToAttrs evaledService.config.kubernetes.resources;
        in resources
      ) config.kubernetes.modules
    );

    kubernetes.defaultModuleConfiguration = [{
      config.kubernetes.version = mkDefault config.kubernetes.version;
    }];
  };
}
