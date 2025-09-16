#!/bin/bash

# Test script to verify GitHub Actions workflow configuration
# This script simulates the key steps from the workflow

set -e

echo "=== Testing GitHub Actions Workflow Configuration ==="

# Check if we're in the right directory
if [ ! -f "flake.nix" ]; then
    echo "❌ Error: flake.nix not found. Please run this script from the docker-python-runner directory."
    exit 1
fi

echo "✅ Found flake.nix"

# Check if Nix is available
if ! command -v nix &> /dev/null; then
    echo "❌ Error: Nix is not installed or not in PATH"
    exit 1
fi

echo "✅ Nix is available: $(nix --version)"

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "❌ Error: Docker is not installed or not in PATH"
    exit 1
fi

echo "✅ Docker is available: $(docker --version)"

# Test Nix flake evaluation
echo "🔍 Testing Nix flake evaluation..."
if nix flake show . > /dev/null 2>&1; then
    echo "✅ Flake evaluation successful"
    echo "Available outputs:"
    nix flake show . | grep -A 10 "packages"
else
    echo "❌ Flake evaluation failed"
    exit 1
fi

# Test if the docker-image package exists
echo "🔍 Testing docker-image package availability..."
if nix flake show . | grep -q "docker-image"; then
    echo "✅ docker-image package found in flake outputs"
else
    echo "❌ docker-image package not found in flake outputs"
    exit 1
fi

# Test Nix build (dry run)
echo "🔍 Testing Nix build (dry run)..."
if nix build .#docker-image --dry-run 2>/dev/null; then
    echo "✅ Nix build dry run successful"
else
    echo "❌ Nix build dry run failed"
    exit 1
fi

# Test Docker environment
echo "🔍 Testing Docker environment..."
if docker info > /dev/null 2>&1; then
    echo "✅ Docker daemon is running"
else
    echo "❌ Docker daemon is not running"
    exit 1
fi

# Test Nix develop environment
echo "🔍 Testing Nix develop environment..."
if nix develop --command bash -c "echo 'Nix develop environment test successful'"; then
    echo "✅ Nix develop environment works"
else
    echo "❌ Nix develop environment failed"
    exit 1
fi

echo ""
echo "🎉 All tests passed! The workflow configuration should work correctly."
echo ""
echo "Next steps:"
echo "1. Commit and push your changes to trigger the GitHub Actions workflow"
echo "2. Check the Actions tab in your GitHub repository to monitor the build"
echo "3. The built image will be available at: ghcr.io/reaslab/docker-python-runner:secure-latest"
