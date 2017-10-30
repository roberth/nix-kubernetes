{ config, ... }:

{
  kubernetes.version = "1.8";

  require = [./modules.nix ./deployment.nix];
}
