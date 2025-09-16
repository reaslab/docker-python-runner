{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [ "gurobi" "gurobipy" ];
        };
      in {
        formatter = pkgs.alejandra;
        
        packages = {
          # Docker image package for CI/CD
          docker-image = import ./docker.nix {inherit pkgs;};
        };
      }
    );
}
