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
        
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Nix development tools
            alejandra
            nixpkgs-fmt
            
            # Docker tools
            dockerTools
            
            # Python development tools
            python312
            uv
            
            # Build tools
            gnutar
            gzip
            curl
          ];
          
          shellHook = ''
            echo "🐍 Python Docker Runner Development Environment"
            echo "Available commands:"
            echo "  nix build .#docker-image  - Build Docker image"
            echo "  nix fmt                   - Format Nix files"
            echo ""
          '';
        };
        
        packages = {
          # Docker image package for CI/CD
          docker-image = import ./docker.nix {inherit pkgs;};
        };
      }
    );
}
