#!/bin/bash

# Python Docker image build script using Nix dockerTools
# Based on the original build.sh from reaslab-uni project

set -e

echo "=== Building Python Docker image with Nix dockerTools ==="
echo "🔨 Building secure Docker image with restricted Python environment..."

# 清理旧的镜像标签和可能冲突的镜像
echo "🧹 Cleaning up old image tags and conflicting images..."
# 删除目标标签
docker rmi ghcr.io/reaslab/docker-python-uv:secure-latest 2>/dev/null || echo "   No existing tag to remove"

# 清理所有悬空镜像
echo "🧹 Cleaning up dangling images..."
docker image prune -f 2>/dev/null || echo "   No dangling images to remove"

# 清理可能冲突的镜像（通过镜像名称识别）
echo "🧹 Cleaning up potentially conflicting images..."
# 首先检查是否有ID冲突的镜像
CONFLICTING_IMAGES=$(docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" | awk '{print $1}' | sort | uniq -d)
if [ -n "$CONFLICTING_IMAGES" ]; then
    echo "   Found conflicting image IDs: $CONFLICTING_IMAGES"
    for conflict_id in $CONFLICTING_IMAGES; do
        echo "   Removing all tags for conflicting ID: $conflict_id"
        docker rmi "$conflict_id" 2>/dev/null || echo "     Could not remove ID $conflict_id"
    done
fi

# 清理Python/UV相关的镜像
docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep -E "(python|uv)" | while read repo_tag id; do
    if [ "$repo_tag" != "ghcr.io/reaslab/docker-python-uv:secure-latest" ]; then
        echo "   Removing Python/UV related image: $repo_tag ($id)"
        docker rmi "$id" 2>/dev/null || echo "     Could not remove $repo_tag"
    fi
done

echo "Building with Nix dockerTools..."
nix-build docker.nix --option sandbox false

echo "Loading Nix image into Docker..."
# 记录加载前的镜像ID和标签
BEFORE_IMAGES=$(docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" | sort)

# 加载Nix构建的镜像
docker load < result

# 记录加载后的镜像ID和标签
AFTER_IMAGES=$(docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" | sort)

echo "Tagging image..."
# 找出新加载的镜像（通过比较ID和标签）
NEW_IMAGE_INFO=$(comm -13 <(echo "$BEFORE_IMAGES") <(echo "$AFTER_IMAGES") | head -1)

if [ -n "$NEW_IMAGE_INFO" ]; then
    NEW_IMAGE_ID=$(echo "$NEW_IMAGE_INFO" | awk '{print $1}')
    NEW_IMAGE_TAG=$(echo "$NEW_IMAGE_INFO" | awk '{print $2}')
    echo "   Found new image: $NEW_IMAGE_TAG ($NEW_IMAGE_ID)"
    
    # 检查是否是我们期望的镜像
    if [[ "$NEW_IMAGE_TAG" == *"python"* ]] || [[ "$NEW_IMAGE_TAG" == *"uv"* ]] || [[ "$NEW_IMAGE_TAG" == *"reaslab"* ]]; then
        echo "   Using new image ID: $NEW_IMAGE_ID"
        docker tag $NEW_IMAGE_ID ghcr.io/reaslab/docker-python-uv:secure-latest
    else
        echo "   New image doesn't match expected pattern, using it anyway"
        docker tag $NEW_IMAGE_ID ghcr.io/reaslab/docker-python-uv:secure-latest
    fi
else
    echo "   No new image detected, checking for existing suitable images"
    # 查找现有的Python相关镜像
    EXISTING_PYTHON=$(docker images --format "{{.ID}} {{.Repository}}:{{.Tag}}" | grep -E "(python|uv|reaslab)" | head -1)
    if [ -n "$EXISTING_PYTHON" ]; then
        EXISTING_ID=$(echo "$EXISTING_PYTHON" | awk '{print $1}')
        EXISTING_TAG=$(echo "$EXISTING_PYTHON" | awk '{print $2}')
        echo "   Using existing image: $EXISTING_TAG ($EXISTING_ID)"
        docker tag $EXISTING_ID ghcr.io/reaslab/docker-python-uv:secure-latest
    else
        echo "   Error: No suitable image found for tagging"
        exit 1
    fi
fi

# 验证最终镜像状态
echo "🔍 Verifying final image state..."
FINAL_IMAGE_ID=$(docker images --format "{{.ID}}" ghcr.io/reaslab/docker-python-uv:secure-latest 2>/dev/null || echo "")
if [ -n "$FINAL_IMAGE_ID" ]; then
    echo "   Final image ID: $FINAL_IMAGE_ID"
    
    # 检查是否有其他镜像使用相同的ID
    DUPLICATE_TAGS=$(docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | awk -v target_id="$FINAL_IMAGE_ID" '$2 == target_id && $1 != "ghcr.io/reaslab/docker-python-uv:secure-latest" {print $1}')
    
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
echo "   - Python version: 3.12 (restricted environment)"
echo "   - Security: Dangerous modules blocked (os, subprocess, sys, etc.)"
echo "   - Resource limits: 1GB memory, CPU shares limit"
echo "   - Safe packages: pip, setuptools, wheel, cython, numpy, scipy, pandas, matplotlib, scikit-learn"
echo "   - Gurobi: 12.0.3 (via nixpkgs)"
echo "   - Container: Read-only rootfs, non-root user (1000:1000)"
echo "   - Network: Restricted (disabled by default)"
echo "   - Tools: Minimal set (bash, coreutils, curl, tar, gzip)"
echo "   - Compilation tools: Removed for security"
echo "Image: ghcr.io/reaslab/docker-python-uv:secure-latest"
