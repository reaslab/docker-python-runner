{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    rust-overlay,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [(import rust-overlay)];
          config.allowUnfree = true;
          config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [ "gurobi" "gurobipy" ];
        };
      in {
        formatter = pkgs.alejandra;
        devShells.default = import ./shell.nix {inherit pkgs;};

        packages = {
          reaslab-proto = import ./pkgs/reaslab-proto.nix {inherit pkgs;};

          reaslab-be = import ./pkgs/reaslab-be.nix {
            inherit pkgs;
            reaslab-proto = self.outputs.packages."${system}".reaslab-proto;
          };

          reaslab-be-image = import ./pkgs/reaslab-be-image.nix {
            inherit pkgs;
            reaslab-be = self.outputs.packages."${system}".reaslab-be;
          };

          # Docker image package for CI/CD
          docker-image = import ./docker.nix {inherit pkgs;};
        };
      }
    );
}
