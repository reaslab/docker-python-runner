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
          buildInputs = with pkgs; [
            # Basic tools
            bash
            coreutils
            curl
            gnutar
            gzip
            
            # Nix tools
            alejandra
            
            # Python tools
            python312
            uv
          ];
          
          shellHook = ''
            echo "🐍 Python Docker Runner Development Environment"
            echo "Available commands:"
            echo "  nix build .#packages.x86_64-linux.docker-image  - Build Docker image"
            echo "  nix build .#docker-image                       - Build Docker image (short form)"
            echo "  nix fmt                                         - Format Nix files"
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
