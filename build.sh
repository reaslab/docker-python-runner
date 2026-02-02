#!/bin/bash

# Python Docker image build script using Nix dockerTools
# Based on the original build.sh from reaslab-uni project

set -e

echo "=== Building Python Docker image with Nix dockerTools ==="
echo "🔨 Building secure Docker image with restricted Python environment..."

# Clean up old image tags and potentially conflicting images
echo "🧹 Cleaning up old image tags and conflicting images..."

# First stop and remove containers using docker-python-runner images
echo "🧹 Cleaning up containers using docker-python-runner images..."
CONTAINERS_TO_STOP=$(docker ps -a --format "{{.ID}} {{.Image}}" | grep "docker-python-runner" | awk '{print $1}' || echo "")
if [ -n "$CONTAINERS_TO_STOP" ]; then
    echo "   Found containers using docker-python-runner images, stopping and removing them..."
    echo "$CONTAINERS_TO_STOP" | while read container_id; do
        if [ -n "$container_id" ]; then
            echo "   Stopping container: $container_id"
            docker stop "$container_id" 2>/dev/null || echo "     Container $container_id already stopped"
            echo "   Removing container: $container_id"
            docker rm "$container_id" 2>/dev/null || echo "     Container $container_id already removed"
        fi
    done
else
    echo "   No containers using docker-python-runner images found"
fi

# Remove target tag
docker rmi ghcr.io/reaslab/docker-python-runner:latest 2>/dev/null || echo "   No existing tag to remove"

# Clean up all dangling images
echo "🧹 Cleaning up dangling images..."
docker image prune -f 2>/dev/null || echo "   No dangling images to remove"

# Clean up docker-python-runner related images
echo "🧹 Cleaning up docker-python-runner related images..."
docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep "docker-python-runner" | while read repo_tag id; do
    echo "   Removing docker-python-runner image: $repo_tag ($id)"
    docker rmi -f "$id" 2>/dev/null || echo "     Could not remove $repo_tag"
done

echo "Building with Nix dockerTools..."
# Configure Nix to support Flakes with optimizations
mkdir -p ~/.config/nix
cat > ~/.config/nix/nix.conf << EOF
experimental-features = nix-command flakes
allow-import-from-derivation = true
# Build optimizations
max-jobs = auto
cores = 0
keep-outputs = true
keep-derivations = true
# Binary cache (speeds up subsequent builds)
substituters = https://cache.nixos.org https://nix-community.cachix.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=
build-use-substitutes = true
auto-optimise-store = true
# Network optimization
stalled-download-timeout = 300
connect-timeout = 60
download-attempts = 5
EOF

# Set environment variable to allow unfree packages (Gurobi)
export NIXPKGS_ALLOW_UNFREE=1

# Generate current UTC timestamp
CURRENT_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Setting Docker image timestamp to: $CURRENT_TIMESTAMP"

# Use environment variable to pass timestamp to Nix
export DOCKER_IMAGE_TIMESTAMP="$CURRENT_TIMESTAMP"

# Use nix build command with optimizations
echo "⏱️  Building Docker image (this will be fast on subsequent builds)..."
nix build .#docker-image \
  --option sandbox false \
  --impure \
  --keep-going \
  --cores 0 \
  --max-jobs auto \
  --show-trace

echo "Loading Nix image into Docker..."
# Check if result exists and is valid
if [ ! -L result ] || [ ! -e result ]; then
    echo "❌ Error: Nix build result not found or invalid"
    exit 1
fi

# Record image IDs and tags before loading
BEFORE_IMAGES=$(docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" | sort)

# Load Nix-built image (optimized: using pv for progress if available)
if command -v pv &> /dev/null; then
    echo "📦 Loading image with progress indicator..."
    pv result | docker load
else
    docker load < result
fi

# Record image IDs and tags after loading
AFTER_IMAGES=$(docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" | sort)

echo "Tagging image..."
# Find newly loaded image (by comparing IDs and tags)
NEW_IMAGE_INFO=$(comm -13 <(echo "$BEFORE_IMAGES") <(echo "$AFTER_IMAGES") | head -1)

if [ -n "$NEW_IMAGE_INFO" ]; then
    NEW_IMAGE_ID=$(echo "$NEW_IMAGE_INFO" | awk '{print $1}')
    NEW_IMAGE_TAG=$(echo "$NEW_IMAGE_INFO" | awk '{print $2}')
    echo "   Found new image: $NEW_IMAGE_TAG ($NEW_IMAGE_ID)"
    
    # Check if this is our expected image
    if [[ "$NEW_IMAGE_TAG" == *"python"* ]] || [[ "$NEW_IMAGE_TAG" == *"uv"* ]] || [[ "$NEW_IMAGE_TAG" == *"reaslab"* ]]; then
        echo "   Using new image ID: $NEW_IMAGE_ID"
    else
        echo "   New image doesn't match expected pattern, using it anyway"
    fi
else
    echo "   No new image detected, checking for existing suitable images"
    # Find existing Python-related images
    EXISTING_PYTHON=$(docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" | grep -E "(python|uv|reaslab)" | head -1)
    if [ -n "$EXISTING_PYTHON" ]; then
        EXISTING_ID=$(echo "$EXISTING_PYTHON" | awk '{print $1}')
        EXISTING_TAG=$(echo "$EXISTING_PYTHON" | awk '{print $2}')
        echo "   Using existing image: $EXISTING_TAG ($EXISTING_ID)"
        NEW_IMAGE_ID=$EXISTING_ID
    else
        echo "   Error: No suitable image found for tagging"
        exit 1
    fi
fi

# Generate tags, consistent with workflow
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "local")

echo "   Creating tags with image ID: $NEW_IMAGE_ID"
echo "   - ghcr.io/reaslab/docker-python-runner:latest"
echo "   - ghcr.io/reaslab/docker-python-runner:$TIMESTAMP"
echo "   - ghcr.io/reaslab/docker-python-runner:$SHORT_SHA"

# Create multiple tags, consistent with workflow
docker tag $NEW_IMAGE_ID ghcr.io/reaslab/docker-python-runner:latest
docker tag $NEW_IMAGE_ID ghcr.io/reaslab/docker-python-runner:$TIMESTAMP
docker tag $NEW_IMAGE_ID ghcr.io/reaslab/docker-python-runner:$SHORT_SHA

# Verify final image state
echo "🔍 Verifying final image state..."
FINAL_IMAGE_ID=$(docker images --format "{{.ID}}" ghcr.io/reaslab/docker-python-runner:latest 2>/dev/null || echo "")
if [ -n "$FINAL_IMAGE_ID" ]; then
    echo "   Final image ID: $FINAL_IMAGE_ID"
    echo "   Created: $(docker images --format "{{.CreatedAt}}" ghcr.io/reaslab/docker-python-runner:latest)"
    echo "   Size: $(docker images --format "{{.Size}}" ghcr.io/reaslab/docker-python-runner:latest)"
    
    # Check if other images use the same ID
    DUPLICATE_TAGS=$(docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | awk -v target_id="$FINAL_IMAGE_ID" '$2 == target_id && $1 != "ghcr.io/reaslab/docker-python-runner:latest" {print $1}')
    
    if [ -n "$DUPLICATE_TAGS" ]; then
        echo "   ⚠️  Warning: Found duplicate image IDs:"
        echo "$DUPLICATE_TAGS" | while read tag; do
            echo "     - $tag"
        done
        echo "   This may cause confusion. Consider cleaning up these tags."
    else
        echo "   ✅ No duplicate image IDs found"
    fi
else
    echo "   ❌ Error: Target image not found after build"
    exit 1
fi

echo "✅ Build completed successfully!"

echo "📋 Secure Image Configuration:"
echo "   - Python Version: 3.12 (restricted environment)"
echo "   - Security: Dangerous modules blocked (os, subprocess, sys, etc.)"
echo "   - Resource Limits: 1GB memory, CPU share limits"
echo "   - Safe Packages: pip, setuptools, wheel, cython, numpy, scipy, pandas, matplotlib, scikit-learn, seaborn, gurobipy, coptpy, cplex, ortools, mosek, pulp"
echo "   - Gurobi: 12.0.3 (via nixpkgs)"
echo "   - COPT: 8.0.2 (via uv pip)"
echo "   - CPLEX: 22.1.2 (from installer)"
echo "   - Container: Read-only root filesystem, non-root user (1000:1000)"
echo "   - Network: Restricted (disabled by default)"
echo "   - Tools: Minimal set (bash, coreutils, curl, tar, gzip)"
echo "   - Compilation Tools: Removed for security"
echo "   - Module Installation: Support via UV installation to /.local/lib/python3.12/site-packages"
echo "Image: ghcr.io/reaslab/docker-python-runner:latest"
