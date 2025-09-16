# Makefile for docker-python-uv (Nix-based, Fedora runners)

.PHONY: help build test clean push pull run run-secure dev

# Default values
REGISTRY ?= ghcr.io
IMAGE_NAME ?= reaslab/docker-python-runner
TAG ?= secure-latest

help: ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build Docker image using Nix
	@echo "Building Docker image using Nix..."
	@echo "This will build a secure Python environment with UV and Gurobi"
	./build.sh

test: ## Test the built Docker image
	@echo "Testing Docker image..."
	@echo "Testing Python version..."
	docker run --rm $(IMAGE_NAME):$(TAG) python --version
	@echo "Testing UV installation..."
	docker run --rm $(IMAGE_NAME):$(TAG) uv --version
	@echo "Testing security restrictions..."
	docker run --rm $(IMAGE_NAME):$(TAG) python -c "try: import os; print('ERROR: os should be restricted'); exit(1); except ImportError: print('OK: os is restricted')"
	@echo "Testing Gurobi availability..."
	docker run --rm $(IMAGE_NAME):$(TAG) python -c "import gurobipy; print('OK: Gurobi available')"
	@echo "Testing scientific packages..."
	docker run --rm $(IMAGE_NAME):$(TAG) python -c "import numpy, scipy, pandas; print('OK: Scientific packages available')"

clean: ## Clean up Docker images and Nix build artifacts
	@echo "Cleaning up..."
	docker rmi $(IMAGE_NAME):$(TAG) 2>/dev/null || true
	docker image prune -f 2>/dev/null || true
	rm -f result 2>/dev/null || true
	@echo "Cleanup completed"

push: ## Push Docker images to registry
	@echo "Pushing Docker images to registry..."
	docker push $(IMAGE_NAME):$(TAG)

pull: ## Pull Docker images from registry
	@echo "Pulling Docker images from registry..."
	docker pull $(IMAGE_NAME):$(TAG)

run: ## Run interactive container
	@echo "Running interactive container..."
	docker run --rm -it $(IMAGE_NAME):$(TAG) bash

run-secure: ## Run secure Python interpreter
	@echo "Running secure Python interpreter..."
	docker run --rm -it $(IMAGE_NAME):$(TAG) python

dev: ## Run development container with volume mount
	@echo "Running development container with volume mount..."
	docker run --rm -it -v $(PWD):/app $(IMAGE_NAME):$(TAG) bash

gurobi-test: ## Test Gurobi with license file
	@echo "Testing Gurobi with license file..."
	@if [ ! -f "gurobi.lic" ]; then \
		echo "Error: gurobi.lic file not found. Please place your Gurobi license file in the current directory."; \
		exit 1; \
	fi
	docker run --rm -v $(PWD)/gurobi.lic:/app/gurobi.lic:ro $(IMAGE_NAME):$(TAG) python -c "import gurobipy; print('Gurobi version:', gurobipy.gurobi.version())"

nix-shell: ## Enter Nix shell for development
	@echo "Entering Nix shell..."
	nix-shell -p nixpkgs.dockerTools nixpkgs.gnutar nixpkgs.gzip

info: ## Show image information
	@echo "Image Information:"
	@echo "  Registry: $(REGISTRY)"
	@echo "  Image: $(IMAGE_NAME)"
	@echo "  Tag: $(TAG)"
	@echo "  Full name: $(REGISTRY)/$(IMAGE_NAME):$(TAG)"
	@echo ""
	@echo "Available commands:"
	@echo "  make build    - Build the image"
	@echo "  make test     - Test the image"
	@echo "  make run      - Run interactive container"
	@echo "  make dev      - Run with volume mount"
	@echo "  make clean    - Clean up images"
