{
  pkgs ? import <nixpkgs> {},
  configuration ? ./test,
  extraModules ? [./modules.nix]
}:

with pkgs.lib;
with import ./lib.nix { inherit pkgs; inherit (pkgs) lib; };

let
  evalKubernetesModules = configuration: evalModules {
    modules = [./kubernetes.nix configuration] ++ extraModules;
    args = {
      inherit pkgs;
      k8s = { inherit loadJSON loadYAML; };
    };
  };

  flattenResources = resources: flatten (
    mapAttrsToList (name: resourceGroup:
      mapAttrsToList (name: resource: resource) resourceGroup
    ) resources
  );

  toKubernetesList = resources: {
    kind = "List";
    apiVersion = "v1";
    items = resources;
  };

  evaldConfiguration = evalKubernetesModules configuration;
in {
  config = pkgs.writeText "config" (builtins.toJSON (
    toKubernetesList (
      (flattenResources (
        moduleToAttrs evaldConfiguration.config.kubernetes.resources)) ++
      (flattenResources (
        moduleToAttrs evaldConfiguration.config.kubernetes.customResources))
    )
  ));
}
