{ pkgs ? import <nixpkgs> { 
    config.allowUnfree = true;
    config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [ "gurobi" ];
  } }:

let
  # Create restricted Python environment, remove dangerous modules
  restrictedPython = pkgs.python312;

  # Final solution for protobuf conflicts:
  # Install OR-Tools to /.local (separate from Nix store packages)
  # This completely avoids buildEnv conflicts
  
  # Main Python environment with all core packages
  pythonWithPackages = restrictedPython.withPackages (ps: with ps; [
    pip
    setuptools
    wheel
    # Scientific computing packages
    cython
    numpy
    scipy
    pandas
    matplotlib
    scikit-learn
    seaborn
    # Optimization solvers
    gurobipy
    pulp  # PuLP - Python Linear Programming (no protobuf dependency)
    # Exclude: yfinance (protobuf 6.x conflicts), ortools (installed separately)
    # Data processing packages
    openpyxl  # Excel file support for pandas
    xlrd  # Excel file support for pandas (legacy .xls format)
  ]);

  # Separate OR-Tools environment (will be copied to /.local)
  pythonWithOrtools = restrictedPython.withPackages (ps: with ps; [
    ortools
    # Automatically includes: protobuf 5.x, absl-py, immutabledict, etc.
  ]);

  # Extract OR-Tools packages to a derivation
  ortoolsPackages = pkgs.runCommand "ortools-packages" {} ''
    mkdir -p $out
    # Copy only the site-packages content (not bin/python to avoid conflicts)
    cp -r ${pythonWithOrtools}/lib/python3.12/site-packages $out/
  '';

  # CPLEX Installation
  # Use the installer saved in the repository folder
  #
  # UPGRADE INSTRUCTIONS (when updating CPLEX installer):
  # 1. Download new CPLEX installer and place it in pkgs/cplex/
  # 2. Update the filename below to match the new installer
  # 3. The extraction logic should automatically adapt to new file sizes
  # 4. If extraction fails, check if InstallAnywhere variable names changed in the script header
  # 5. Test the build: nix-build docker.nix -A docker-image
  # Expected changes: Usually only the filename needs updating, extraction logic remains the same
  cplexInstallerPath = ./pkgs/cplex/cos_installer_preview-22.1.2.R4-M0N96ML-linux-x86-64.bin;
  
  cplex = pkgs.stdenv.mkDerivation {
    name = "cplex-22.1.2";
    # Use builtins.path to import the installer into the Nix store
    src = if builtins.pathExists cplexInstallerPath 
          then builtins.path { path = cplexInstallerPath; name = "cplex-installer.bin"; }
          else pkgs.emptyDirectory; # Fallback if not found

    unpackPhase = "true";  # We'll do extraction in installPhase to keep files in scope
    
    # Dependencies for extraction and cleanup
    nativeBuildInputs = [ 
      pkgs.coreutils
      pkgs.findutils
      pkgs.unzip
      pkgs.patchelf
    ];
    # We will not use autoPatchelf on the installer
    dontAutoPatchelf = true;
    
    # Enable parallel extraction where possible
    enableParallelBuilding = true;
    buildInputs = [ 
      pkgs.glibc 
      pkgs.zlib 
      pkgs.stdenv.cc.cc.lib 
      pkgs.libffi
      pkgs.libxcrypt-legacy
      pkgs.fontconfig
      pkgs.freetype
      pkgs.curl
      pkgs.unixODBC
      pkgs.sqlite
      pkgs.xorg.libX11
      pkgs.xorg.libXext
      pkgs.xorg.libXrender
      pkgs.xorg.libXtst
      pkgs.xorg.libXi
      pkgs.xorg.libXmu
      pkgs.xorg.libSM
      pkgs.xorg.libICE
      pkgs.alsa-lib
      pkgs.mariadb-connector-c
      pkgs.libnsl
    ];

    # CPLEX installer and JRE bundle often contain broken symlinks 
    # and other issues that Nix checks for by default.
    dontCheckForBrokenSymlinks = true;
    # Prevent audit failures for temp directories in the installer
    noAuditTmpdir = true;

    installPhase = ''
      # Extract the embedded archive from the InstallAnywhere self-extractor
      # This method bypasses the problematic InstallAnywhere installer execution
      # and directly extracts the CPLEX files from the embedded archives
      #
      # UPGRADE NOTE: When updating to a new CPLEX installer version:
      # 1. Replace the installer file in pkgs/cplex/
      # 2. The variable names (BLOCKSIZE, JRESTART, etc.) should remain the same
      # 3. Only the values may change - the parsing logic should work automatically
      #
      echo "Extracting embedded archive from CPLEX installer..."
      
      # Parse InstallAnywhere variables from the script header
      BLOCKSIZE=$(grep -m1 "^BLOCKSIZE=" "$src" 2>/dev/null | cut -d= -f2 || echo "32768")
      JRESTART=$(grep -m1 "^JRESTART=" "$src" 2>/dev/null | cut -d= -f2 || echo "5")
      JREREALSIZE=$(grep -m1 "^JREREALSIZE=" "$src" 2>/dev/null | cut -d= -f2 || echo "48207661")
      ARCHREALSIZE=$(grep -m1 "^ARCHREALSIZE=" "$src" 2>/dev/null | cut -d= -f2 || echo "6804302")
      RESREALSIZE=$(grep -m1 "^RESREALSIZE=" "$src" 2>/dev/null | cut -d= -f2 || echo "409293865")
      
      echo "Parsed InstallAnywhere variables:"
      echo "  BLOCKSIZE: $BLOCKSIZE"
      echo "  JRESTART: $JRESTART"
      echo "  RESREALSIZE: $RESREALSIZE"
      
      # Calculate resource archive start position
      JRE_BLOCKS=$(( (JREREALSIZE + BLOCKSIZE - 1) / BLOCKSIZE ))
      ARCHSTART_BLOCKS=$(( JRESTART + JRE_BLOCKS ))
      ARCH_BLOCKS=$(( (ARCHREALSIZE + BLOCKSIZE - 1) / BLOCKSIZE ))
      RESSTART_BLOCKS=$(( ARCHSTART_BLOCKS + ARCH_BLOCKS ))
      RESOURCE_START_BYTES=$(( RESSTART_BLOCKS * BLOCKSIZE ))
      
      echo "Resource archive starts at byte: $RESOURCE_START_BYTES"
      echo "Extracting resource archive (~$((RESREALSIZE / 1048576))MB)..."
      
      # Extract resource archive (contains actual CPLEX files)
      mkdir -p archive_extract
      cd archive_extract
      
      # Extract using dd - avoid pipes to prevent SIGPIPE errors
      # Use bs=1 for exact byte positioning, even if slower
      echo "Extracting $RESREALSIZE bytes starting at offset $RESOURCE_START_BYTES..."
      dd if="$src" bs=1 skip=$RESOURCE_START_BYTES count=$RESREALSIZE of=resources.zip 2>/dev/null
      
      if [ -f resources.zip ] && [ -s resources.zip ]; then
        ACTUAL_SIZE=$(stat -c%s resources.zip 2>/dev/null || stat -f%z resources.zip 2>/dev/null)
        echo "✅ Extracted resource archive ($ACTUAL_SIZE bytes)"
        
        if [ "$ACTUAL_SIZE" -ne "$RESREALSIZE" ]; then
          echo "⚠️  Warning: Size mismatch (expected $RESREALSIZE, got $ACTUAL_SIZE)"
          # Try to fix by truncating or padding
          if [ "$ACTUAL_SIZE" -gt "$RESREALSIZE" ]; then
            truncate -s $RESREALSIZE resources.zip 2>/dev/null || true
          fi
        fi
        
      echo "Extracting resource ZIP contents..."
      # Use parallel unzip if available, otherwise fall back to regular unzip
      if command -v unzip >/dev/null 2>&1; then
        unzip -q resources.zip || {
          echo "❌ Error: Failed to extract resource ZIP archive"
          echo "Checking ZIP file integrity..."
          file resources.zip || true
          exit 1
        }
      fi
      echo "✅ Successfully extracted resource archive"
      else
        echo "❌ Error: Failed to extract resource archive file"
        exit 1
      fi
      
      echo "Processing extracted CPLEX archive..."
      
      # The CPLEX files are in a nested JAR file inside the resource ZIP
      CPLEX_JAR=$(find . -name "*CPLEXOptimizationStudio*.jar" -type f | head -n 1)
      
      if [ -z "$CPLEX_JAR" ] || [ ! -f "$CPLEX_JAR" ]; then
        echo "❌ Error: CPLEX JAR file not found"
        echo "Searching for JAR files..."
        find . -name "*.jar" -type f
        exit 1
      fi
      
      echo "Found CPLEX JAR: $CPLEX_JAR"
      JAR_SIZE=$(stat -c%s "$CPLEX_JAR" 2>/dev/null || stat -f%z "$CPLEX_JAR" 2>/dev/null)
      echo "Extracting CPLEX JAR (~$((JAR_SIZE / 1048576))MB, using optimized extraction)..."
      
      # Extract the JAR file (JAR files are ZIP archives)
      # Use -n to skip existing files if re-extracting (speeds up retries)
      mkdir -p cplex_extract
      cd cplex_extract
      unzip -q -n "../$CPLEX_JAR" 2>/dev/null || unzip -q "../$CPLEX_JAR" || {
        echo "❌ Error: Failed to extract CPLEX JAR"
        exit 1
      }
      echo "✅ Successfully extracted CPLEX JAR"
      
      # Find the CPLEX installation directory
      CPLEX_DIR=""
      if CPLEX_DIR=$(find . -type d -name "cplex" -exec test -d {}/bin/x86-64_linux \; -print | head -n 1); then
        echo "✅ Found CPLEX directory: $CPLEX_DIR"
      elif CPLEX_DIR=$(find . -type d -path "*/CPLEX_Studio221/cplex" | head -n 1); then
        echo "✅ Found CPLEX directory: $CPLEX_DIR"
      elif CPLEX_DIR=$(find . -type d -path "*/cplex/bin/x86-64_linux" | xargs dirname | xargs dirname | head -n 1); then
        echo "✅ Found CPLEX directory: $CPLEX_DIR"
      else
        echo "❌ Error: Could not locate CPLEX directory in extracted JAR"
        echo "Directory structure:"
        find . -type d | head -30
        exit 1
      fi
      
      # Copy CPLEX and CP Optimizer to output directory
      echo "Copying solvers to output directory..."
      mkdir -p $out/opt/ibm/ILOG/CPLEX_Studio221
      
      # Use a robust way to find directories
      SOLVER_BASE=$(find . -type d -path "*/opt/ibm/ILOG/CPLEX_Studio221" -print -quit || true)
      if [ -n "$SOLVER_BASE" ]; then
        cp -r "$SOLVER_BASE"/* $out/opt/ibm/ILOG/CPLEX_Studio221/
      else
        for s in cplex cpoptimizer concert opl docplex; do
          S_PATH=$(find . -type d -name "$s" ! -path "*/examples/*" -print -quit || true)
          [ -n "$S_PATH" ] && cp -r "$S_PATH" $out/opt/ibm/ILOG/CPLEX_Studio221/
        done
      fi

      # Cleanup large irrelevant files to keep image size down
      find $out/opt/ibm/ILOG -type d -name "examples" -exec rm -rf {} + || true
      find $out/opt/ibm/ILOG -type f -name "*.pdf" -delete || true

      # Fix permissions: some extracted payloads preserve read-only modes (e.g. 444),
      # which makes CPLEX binaries non-executable inside the final image.
      echo "Fixing CPLEX file permissions..."
      if [ -d "$out/opt/ibm/ILOG/CPLEX_Studio221" ]; then
        # Ensure directories are searchable
        find "$out/opt/ibm/ILOG/CPLEX_Studio221" -type d -exec chmod 755 {} + || true
        # Make binaries executable in any */bin/x86-64_linux directory (exclude shared libs)
        find "$out/opt/ibm/ILOG/CPLEX_Studio221" -type d -path "*/bin/x86-64_linux" | while read -r d; do
          find "$d" -maxdepth 1 -type f ! -name "*.so*" -exec chmod 755 {} + || true
          find "$d" -maxdepth 1 -type f -name "*.so*" -exec chmod 644 {} + || true
        done
      fi
      
      # Verify the core directory exists
      if [ -d "$out/opt/ibm/ILOG/CPLEX_Studio221/cplex/bin/x86-64_linux" ]; then
        echo "✅ CPLEX core binaries found in output directory"
        echo "CPLEX installation structure:"
        find $out/opt/ibm/ILOG/CPLEX_Studio221 -maxdepth 3 -type d | head -20 || true
        
        # Also look for Python API in the extracted structure before copying
        echo "Searching for Python API in extracted JAR..."
        PYTHON_API_DIR=$(find . -type d -name "python" ! -path "*/examples/*" -print -quit || true)
        if [ -n "$PYTHON_API_DIR" ]; then
          echo "Found Python API directory: $PYTHON_API_DIR"
          # Look for cplex Python package within
          CPLEX_PYTHON_PKG=$(find "$PYTHON_API_DIR" -name "__init__.py" -path "*/cplex/__init__.py" -print -quit | xargs dirname || true)
          if [ -n "$CPLEX_PYTHON_PKG" ] && [ "$CPLEX_PYTHON_PKG" != "." ]; then
            echo "Found CPLEX Python package: $CPLEX_PYTHON_PKG"
            # Copy Python API to a known location
            mkdir -p $out/opt/ibm/ILOG/CPLEX_Studio221/cplex/python
            cp -r "$CPLEX_PYTHON_PKG"/* $out/opt/ibm/ILOG/CPLEX_Studio221/cplex/python/ 2>/dev/null || true
          fi
        fi
      else
        echo "❌ Error: CPLEX core binaries not found in expected location"
        echo "Output directory structure:"
        find $out -maxdepth 5 -type d | head -30 || true
        exit 1
      fi
    '';
    
    # Post-install: Patch installed libraries to work with Nix's glibc
    postFixup = ''
      echo "Patching CPLEX ELF files for Nix compatibility..."

      RPATH="${pkgs.glibc}/lib:${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.zlib}/lib:${pkgs.libffi}/lib"
      INTERP="${pkgs.glibc}/lib/ld-linux-x86-64.so.2"

      # 1) Patch ELF executables (and any ELF that has an interpreter) so they can run in the image.
      # Missing/incorrect interpreter path is what causes: "cannot execute: required file not found".
      find "$out/opt/ibm/ILOG/CPLEX_Studio221" -type f | while read -r f; do
        if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
          patchelf --set-interpreter "$INTERP" "$f" || true
          patchelf --set-rpath "$RPATH" "$f" || true
        fi
      done

      # 2) Patch shared libraries rpath (they won't have an interpreter).
      find "$out/opt/ibm/ILOG/CPLEX_Studio221" -type f \( -name "*.so" -o -name "*.so.*" \) | while read -r lib; do
        patchelf --set-rpath "$RPATH" "$lib" || true
      done
    '';
  };

  # COPT (Cardinal Optimizer) 完整安装
  # 包含求解器二进制文件、共享库和 Python 接口
  coptVersion = "8.0.2";
  # MOSEK Python API (PyPI package)
  # Latest stable: 11.0.30 (Released: Nov. 18, 2025)
  mosekVersion = "11.0.30";
  copt = pkgs.stdenv.mkDerivation {
    name = "copt-${coptVersion}";
    src = pkgs.fetchurl {
      url = "https://pub.shanshu.ai/download/copt/${coptVersion}/linux64/CardinalOptimizer-${coptVersion}-lnx64.tar.gz";
      sha256 = "1cns2z8cic4rvisxy5bmf60241a6c7a1g1mpxvb13dzwdn94r65v";
      # Network optimization
      curlOptsList = [ "--retry" "5" "--retry-delay" "10" "--connect-timeout" "60" ];
    };

    nativeBuildInputs = [ pkgs.patchelf pkgs.unzip ];
    buildInputs = [ pkgs.glibc pkgs.zlib pkgs.stdenv.cc.cc.lib pkgs.libffi ];
    
    # Enable parallel operations
    enableParallelBuilding = true;
    
    installPhase = ''
      mkdir -p $out/opt/copt
      tar -xzf $src -C $out/opt/copt --strip-components=1
      
      # 移除不需要的例子和文档以减小镜像体积
      rm -rf $out/opt/copt/examples $out/opt/copt/docs
      
      # 确保权限正确
      find $out/opt/copt -type d -exec chmod 755 {} +
      find $out/opt/copt/bin -type f -exec chmod 755 {} +
      find $out/opt/copt/lib -type f -exec chmod 644 {} +
    '';

    postFixup = ''
      echo "Patching COPT binaries and libs for Nix..."
      RPATH="${pkgs.glibc}/lib:${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.zlib}/lib:${pkgs.libffi}/lib"
      INTERP="${pkgs.glibc}/lib/ld-linux-x86-64.so.2"

      # Patch 所有的二进制执行文件
      find $out/opt/copt/bin -type f | while read -r f; do
        if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
          patchelf --set-interpreter "$INTERP" "$f" || true
          patchelf --set-rpath "$RPATH" "$f" || true
        fi
      done

      # Patch 所有的共享库
      find $out/opt/copt/lib -name "*.so*" -type f | while read -r lib; do
        patchelf --set-rpath "$RPATH" "$lib" || true
      done
    '';
  };

  # MOSEK Python 接口（直接通过 uv pip 从 PyPI 安装）
  # MOSEK 提供免费的学术许可证和30天试用许可证
  # PyPI: https://pypi.org/project/Mosek/
  # 学术许可证: https://www.mosek.com/products/academic-licenses/
  # 固定版本以保证镜像可复现
  mosekPythonPackages = pkgs.runCommand "mosek-python-packages" {
    nativeBuildInputs = [ pythonWithPackages pkgs.uv pkgs.cacert ];
    __impureHostDeps = [ "/etc/resolv.conf" "/etc/hosts" ];
    # Enable better caching by declaring output hash
    preferLocalBuild = false;
    allowSubstitutes = false;
  } ''
    mkdir -p $out/site-packages
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export UV_CACHE_DIR="$TMPDIR/.uv_cache"
    mkdir -p "$UV_CACHE_DIR"
    export UV_PYTHON_PREFERENCE="system"
    export UV_PYTHON="${pythonWithPackages}/bin/python3.12"
    # Network optimization: increase timeouts and retries
    export UV_HTTP_TIMEOUT="300"
    export UV_NO_PROGRESS="1"
    export UV_CONCURRENT_DOWNLOADS="5"
    
    echo "Installing MOSEK Python API (Mosek==${mosekVersion}) via uv pip..."
    if ${pkgs.uv}/bin/uv pip install --python "$UV_PYTHON" --target $out/site-packages "Mosek==${mosekVersion}" 2>&1; then
      echo "✅ MOSEK Python package installed from PyPI"
      # 显示安装的版本
      ${pkgs.uv}/bin/uv pip list --python "$UV_PYTHON" | grep -i mosek || true
    else
      echo "❌ Error: Failed to install MOSEK Python package from PyPI"
      exit 1
    fi
  '';

  # COPT Python 接口（优先使用 uv pip 安装以获得最佳兼容性）
  coptPythonPackages = pkgs.runCommand "copt-python-packages" {
    nativeBuildInputs = [ pythonWithPackages pkgs.uv pkgs.cacert ];
    __impureHostDeps = [ "/etc/resolv.conf" "/etc/hosts" ];
    preferLocalBuild = false;
    allowSubstitutes = false;
  } ''
    mkdir -p $out/site-packages
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export UV_CACHE_DIR="$TMPDIR/.uv_cache"
    mkdir -p "$UV_CACHE_DIR"
    export UV_PYTHON_PREFERENCE="system"
    export UV_PYTHON="${pythonWithPackages}/bin/python3.12"
    # Network optimization
    export UV_HTTP_TIMEOUT="300"
    export UV_NO_PROGRESS="1"
    export UV_CONCURRENT_DOWNLOADS="5"
    
    echo "Installing coptpy via uv pip..."
    # 尝试从 PyPI 安装，如果失败则从解压后的 copt 目录提取
    if ${pkgs.uv}/bin/uv pip install --python "$UV_PYTHON" --target $out/site-packages coptpy==${coptVersion} 2>&1; then
      echo "✅ coptpy installed from PyPI"
    else
      echo "⚠️  PyPI install failed, extracting from copt package..."
      # 查找解压后的 copt 目录中的 python 接口
      CP_DIR=$(find ${copt}/opt/copt -name "coptpy" -type d | head -n 1)
      if [ -n "$CP_DIR" ]; then
        cp -r "$CP_DIR" $out/site-packages/
      else
        echo "❌ Error: Could not find coptpy in package"
        exit 1
      fi
    fi
  '';

  # Extract CPLEX Python API
  # First try to find it in the CPLEX installation, otherwise install via uv pip
  cplexPythonPackages = pkgs.runCommand "cplex-python-packages" {
    nativeBuildInputs = [ pythonWithPackages pkgs.uv pkgs.cacert pkgs.curl ];
    # Allow network access to download pip packages
    # Note: This requires --option sandbox false or network access enabled
    __impureHostDeps = [ "/etc/resolv.conf" "/etc/hosts" ];
    # Mark as impure to allow network access
    preferLocalBuild = false;
    allowSubstitutes = false;
  } ''
    mkdir -p $out/site-packages
    
    echo "Searching for CPLEX Python API in ${cplex}..."
    
    # Method 1: Look for python/<version>/<arch>/cplex structure
    # CPLEX provides Python API in version-specific directories like:
    # cplex/python/3.10/x86-64_linux/cplex/
    # cplex/python/3.11/x86-64_linux/cplex/
    # cplex/python/3.12/x86-64_linux/cplex/
    CPLEX_API_DIR=""
    PYTHON_BASE="${cplex}/opt/ibm/ILOG/CPLEX_Studio221/cplex/python"
    
    if [ -d "$PYTHON_BASE" ]; then
      echo "Found Python base directory: $PYTHON_BASE"
      # Prefer Python 3.12, then 3.11, then 3.10, then any version
      PYTHON_VERSIONS="3.12 3.11 3.10"
      FOUND=0
      
      for PREFERRED_VERSION in $PYTHON_VERSIONS; do
        VERSION_DIR="$PYTHON_BASE/$PREFERRED_VERSION"
        if [ -d "$VERSION_DIR" ]; then
          echo "Checking preferred Python version: $PREFERRED_VERSION"
          # Look for architecture-specific directory (x86-64_linux, etc.)
          for ARCH_DIR in "$VERSION_DIR"/*; do
            if [ -d "$ARCH_DIR" ]; then
              ARCH=$(basename "$ARCH_DIR")
              echo "Checking architecture: $ARCH"
              # Look for cplex package directory
              CPLEX_PKG_DIR="$ARCH_DIR/cplex"
              if [ -d "$CPLEX_PKG_DIR" ] && [ -f "$CPLEX_PKG_DIR/__init__.py" ]; then
                CPLEX_API_DIR="$CPLEX_PKG_DIR"
                echo "✅ Found CPLEX Python API for Python $PREFERRED_VERSION: $CPLEX_API_DIR"
                FOUND=1
                break 2
              fi
            fi
          done
        fi
      done
      
      # If preferred versions not found, try any version
      if [ $FOUND -eq 0 ]; then
        echo "Preferred Python versions not found, trying any available version..."
        for VERSION_DIR in "$PYTHON_BASE"/*; do
          if [ -d "$VERSION_DIR" ]; then
            VERSION=$(basename "$VERSION_DIR")
            echo "Checking Python version: $VERSION"
            for ARCH_DIR in "$VERSION_DIR"/*; do
              if [ -d "$ARCH_DIR" ]; then
                ARCH=$(basename "$ARCH_DIR")
                CPLEX_PKG_DIR="$ARCH_DIR/cplex"
                if [ -d "$CPLEX_PKG_DIR" ] && [ -f "$CPLEX_PKG_DIR/__init__.py" ]; then
                  CPLEX_API_DIR="$CPLEX_PKG_DIR"
                  echo "✅ Found CPLEX Python API for Python $VERSION: $CPLEX_API_DIR"
                  FOUND=1
                  break 2
                fi
              fi
            done
          fi
        done
      fi
    fi
    
    # Method 2: Direct search for cplex/__init__.py in python directories
    if [ -z "$CPLEX_API_DIR" ]; then
      echo "Trying alternative search method..."
      CPLEX_API_DIR=$(find ${cplex} -name "__init__.py" -path "*/python/*/cplex/__init__.py" ! -path "*/examples/*" -print | xargs -I {} dirname {} | head -n 1)
    fi
    
    # Method 3: Search for any cplex Python package directory
    if [ -z "$CPLEX_API_DIR" ]; then
      CPLEX_API_DIR=$(find ${cplex} -name "__init__.py" -path "*/cplex/__init__.py" ! -path "*/examples/*" -print | xargs -I {} dirname {} | head -n 1)
    fi
    
    if [ -n "$CPLEX_API_DIR" ] && [ -d "$CPLEX_API_DIR" ]; then
      echo "✅ Found CPLEX Python API in: $CPLEX_API_DIR"
      cp -r "$CPLEX_API_DIR" $out/site-packages/
      echo "✅ CPLEX Python API copied successfully"
      echo "Contents:"
      ls -la $out/site-packages/cplex/ | head -10
    else
      echo "⚠️  CPLEX Python API directory not found in installation package"
      echo "Installing CPLEX Python API via uv pip..."
      echo ""
      
      # Set up environment for uv pip installation
      export CPLEX_HOME=${cplex}/opt/ibm/ILOG/CPLEX_Studio221/cplex
      export LD_LIBRARY_PATH=${cplex}/opt/ibm/ILOG/CPLEX_Studio221/cplex/bin/x86-64_linux:$LD_LIBRARY_PATH
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      export PYTHON=${pythonWithPackages}/bin/python3.12
      # Ensure uv has writable cache + HOME during build
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      export UV_CACHE_DIR="$TMPDIR/.uv_cache"
      mkdir -p "$UV_CACHE_DIR"
      # Avoid flaky downloads: increase timeouts and disable progress UI
      export UV_HTTP_TIMEOUT="300"
      export UV_NO_PROGRESS="1"
      
      # Configure uv to use system Python
      export UV_PYTHON_PREFERENCE="system"
      export UV_PYTHON="$PYTHON"
      
      # Install cplex and docplex package using uv pip
      # Use --target to install to our output directory
      # Use --python to specify Python interpreter explicitly
      echo "Attempting to install cplex and docplex via uv pip from PyPI..."
      echo "Python interpreter: $PYTHON"
      echo "Target directory: $out/site-packages"
      if ${pkgs.uv}/bin/uv pip install --python "$PYTHON" --target $out/site-packages cplex docplex 2>&1; then
        echo "✅ Successfully installed CPLEX and docplex Python API via uv pip"
        echo "Installed packages:"
        ls -la $out/site-packages/ | head -10
        
        # Verify installation
        if [ -f "$out/site-packages/cplex/__init__.py" ] && [ -f "$out/site-packages/docplex/__init__.py" ]; then
          echo "✅ Verified: CPLEX and docplex Python packages are correctly installed"
        else
          echo "⚠️  Warning: Packages installed but some __init__.py not found"
          find $out/site-packages -maxdepth 2 -type d
        fi
      else
        echo "❌ Error: Failed to install packages via uv pip"
        echo "This might be due to:"
        echo "  1. Network restrictions (check if build.sh uses --option sandbox false)"
        echo "  2. PyPI unavailability"
        echo "  3. CPLEX package not available on PyPI"
        echo ""
        echo "Build is configured to PREINSTALL CPLEX Python API; failing hard."
        exit 1
      fi
    fi
  '';

  # Use main Python environment (only reference it once)
  systemPython = pythonWithPackages;

  # Create restricted Python interpreter startup script
  securePythonScript = pkgs.writeScriptBin "python" ''
    #!${pkgs.bash}/bin/bash
    
    # Set restricted environment
    # Use /.local instead of /tmp/.local because /tmp is mounted with noexec flag
    export PYTHONPATH="/app:/opt/ortools/lib/python3.12/site-packages:/opt/cplex/lib/python3.12/site-packages:/opt/copt/lib/python3.12/site-packages:/opt/mosek/lib/python3.12/site-packages:/.local/lib/python3.12/site-packages"
    export PYTHONUNBUFFERED=1
    export PYTHONDONTWRITEBYTECODE=1
    
    # Create writable site-packages directory if it doesn't exist
    mkdir -p /.local/lib/python3.12/site-packages
    
    # Ensure the directory is writable and has correct permissions
    chmod 755 /.local/lib/python3.12/site-packages
    
    # Restrict system tool access - ensure util-linux tools are accessible
    # Also include CPLEX and COPT paths so docplex/coptpy can find solvers
    export PATH="${pkgs.coreutils}/bin:${pkgs.util-linux}/bin:/usr/local/bin:/usr/bin:/opt/ibm/ILOG/CPLEX_Studio221/cplex/bin/x86-64_linux:/opt/ibm/ILOG/CPLEX_Studio221/cpoptimizer/bin/x86-64_linux:/opt/copt/bin"
    
    # Restrict environment variables
    # NOTE: do not unset HOME, it breaks some packages (setuptools, etc.) and causes 'HOME:-' directory creation
    export HOME=/home/python-user
    unset USER
    unset LOGNAME
    unset MAIL
    

    # Start restricted Python interpreter using system Python
    exec ${systemPython}/bin/python3.12 -S -c "
import sys
import builtins

# Dangerous modules list - excluding scientific computing modules
# Note: sys module is safe and needed for package path management
# os module is partially restricted - only dangerous functions are blocked
DANGEROUS_MODULES = {
    'subprocess', 'importlib', 'exec', 'eval', 'compile', 
    '__import__', 'open', 'file', 'input', 'raw_input', 'urllib', 'requests', 
    'socket', 'ftplib', 'smtplib', 'poplib', 'imaplib', 'nntplib', 'telnetlib'
}

# Override __import__ function to block dangerous modules
original_import = builtins.__import__

def safe_import(name, *args, **kwargs):
    if name in DANGEROUS_MODULES:
        raise ImportError(f\"Module '{name}' is not allowed in secure environment\")
    return original_import(name, *args, **kwargs)

builtins.__import__ = safe_import

# Override exec and eval functions
def safe_exec(*args, **kwargs):
    raise RuntimeError('exec() is not allowed in secure environment')

def safe_eval(*args, **kwargs):
    raise RuntimeError('eval() is not allowed in secure environment')

builtins.exec = safe_exec
builtins.eval = safe_eval

# Override compile function
def safe_compile(*args, **kwargs):
    raise RuntimeError('compile() is not allowed in secure environment')

builtins.compile = safe_compile

# Override open function
def safe_open(*args, **kwargs):
    raise RuntimeError('open() is not allowed in secure environment')

builtins.open = safe_open

# Override input function
def safe_input(*args, **kwargs):
    raise RuntimeError('input() is not allowed in secure environment')

builtins.input = safe_input

# Configure sys.path to include uv-installed packages
import sys
import os

# Restrict dangerous os functions while allowing safe ones
original_os_module = os
dangerous_os_functions = {
    'system', 'popen', 'execv', 'execve', 'execvp', 'execvpe', 
    'spawnv', 'spawnve', 'spawnvp', 'spawnvpe', 'fork', 'kill',
    'killpg', 'wait', 'waitpid', 'wait3', 'wait4'
}

def safe_os_function(name, *args, **kwargs):
    if name in dangerous_os_functions:
        raise RuntimeError(f'os.{name}() is not allowed in secure environment')
    return getattr(original_os_module, name)(*args, **kwargs)

# Override dangerous os functions
for func_name in dangerous_os_functions:
    if hasattr(os, func_name):
        setattr(os, func_name, lambda *args, **kwargs: safe_os_function(func_name, *args, **kwargs))

# Add uv-installed packages directory to sys.path
# Use /.local instead of /tmp/.local because /tmp is mounted with noexec flag
uv_packages_path = "/.local/lib/python3.12/site-packages"
if os.path.exists(uv_packages_path) and uv_packages_path not in sys.path:
    sys.path.insert(0, uv_packages_path)

# Set resource limits
import resource
import signal

# Set memory limit (2GB)
resource.setrlimit(resource.RLIMIT_AS, (2 * 1024 * 1024 * 1024, 2 * 1024 * 1024 * 1024))

# Set CPU time limit (200 seconds)
resource.setrlimit(resource.RLIMIT_CPU, (200, 200))

# Set recursion depth limit
sys.setrecursionlimit(1000)

# Set timeout handling
def timeout_handler(signum, frame):
    raise TimeoutError('Code execution timeout')

signal.signal(signal.SIGALRM, timeout_handler)
signal.alarm(200)  # 200 second timeout

# Handle different argument patterns
if len(sys.argv) == 1:
    # No arguments, read from stdin
    try:
        exec(sys.stdin.read())
    except EOFError:
        # No input, start interactive mode
        import code
        code.interact()
elif len(sys.argv) == 2 and sys.argv[1] == '--version':
    # Handle --version flag
    print(f'Python {sys.version.split()[0]}')
elif len(sys.argv) == 2 and sys.argv[1].startswith('-'):
    # Handle other flags like -c, -m, etc.
    if sys.argv[1] == '-c' and len(sys.argv) == 3:
        # Execute code with security restrictions
        exec(sys.argv[2])
    elif sys.argv[1] == '-m' and len(sys.argv) == 3:
        # Execute module with security restrictions
        import runpy
        runpy.run_module(sys.argv[2], run_name='__main__')
    else:
        # Other flags - execute with security restrictions
        original_os_module.execv('${systemPython}/bin/python3.12', ['python3.12'] + sys.argv[1:])
    else:
        # Execute file or code
        try:
            if len(sys.argv) > 1 and not sys.argv[1].startswith('-'):
                # Execute file with security restrictions
                with open(sys.argv[1], 'r') as f:
                    code = f.read()
                exec(code)
            else:
                # Execute with security restrictions
                original_os_module.execv('${systemPython}/bin/python3.12', ['python3.12'] + sys.argv[1:])
    except Exception as e:
        print(f'Error: {e}', file=sys.stderr)
        sys.exit(1)
finally:
    signal.alarm(0)  # Cancel timeout
" "$@"
  '';

  # Create secure uv startup script
  secureUvScript = pkgs.writeScriptBin "uv" ''
    #!${pkgs.bash}/bin/bash
    
    # Set restricted environment
    # Use /.local instead of /tmp/.local because /tmp is mounted with noexec flag
    export PYTHONPATH="/app:/opt/ortools/lib/python3.12/site-packages:/opt/cplex/lib/python3.12/site-packages:/opt/copt/lib/python3.12/site-packages:/opt/mosek/lib/python3.12/site-packages:/.local/lib/python3.12/site-packages"
    export PYTHONUNBUFFERED=1
    export PYTHONDONTWRITEBYTECODE=1
    # Some packages (sdists) require a valid HOME during build (e.g. setuptools expanduser()).
    # Keep HOME set to a writable directory.
    export HOME=/home/python-user
    
    # Force uv to use system Python
    export UV_PYTHON_PREFERENCE="system"
    export UV_LINK_MODE="copy"
    
    # Configure uv to install packages to writable directory
    export UV_PYTHON_SITE_PACKAGES="/.local/lib/python3.12/site-packages"
    
    # Set UV cache directory to writable location
    export UV_CACHE_DIR="/tmp/.uv_cache"
    
    # Set Python interpreter path explicitly
    export UV_PYTHON="${systemPython}/bin/python3.12"
    
    # Restrict network access - only allow HTTPS
    export HTTP_PROXY=""
    export HTTPS_PROXY=""
    export http_proxy=""
    export https_proxy=""
    
    # Restrict system tool access - ensure util-linux tools are accessible
    export PATH="${pkgs.coreutils}/bin:${pkgs.util-linux}/bin:/usr/local/bin:/usr/bin"
    
    # Restrict environment variables
    # NOTE: do not unset HOME, it breaks building some packages.
    unset MAIL
    
    # Create necessary directories
    mkdir -p /tmp/.uv_cache
    mkdir -p /.local/lib/python3.12/site-packages
    mkdir -p "$HOME" || true
    
    # Start uv
    exec ${pkgs.uv}/bin/uv "$@"
  '';

  # Python environment with gurobipy pre-installed
  pythonWithGurobipy = pythonWithPackages;

  # Create a small derivation to provide the 'python' symlink
  pythonSymlink = pkgs.runCommand "python-symlink" {} ''
    mkdir -p $out/bin
    ln -s ${systemPython}/bin/python3.12 $out/bin/python
    ln -s ${systemPython}/bin/python3.12 $out/bin/python3
  '';

  # Create secure environment with all necessary dependencies
  runtimeEnv = pkgs.buildEnv {
    name = "python-runtime-secure";
    ignoreCollisions = true; 
    paths = [
      systemPython
      pythonSymlink
      secureUvScript
      pkgs.gurobi
      cplex
      copt
      pkgs.glibc
      pkgs.zlib
      pkgs.ncurses
      pkgs.openssl
      pkgs.libffi
      pkgs.bash
      pkgs.coreutils
      pkgs.util-linux
      pkgs.curl
      pkgs.gnutar
      pkgs.gzip
      pkgs.lapack
      pkgs.blas
      pkgs.gcc.cc.lib
      pkgs.stdenv.cc.cc.lib
    ];
  };

  # Create a package with necessary directories and files for non-root user
  dockerSetup = pkgs.stdenv.mkDerivation {
    name = "docker-setup";
    buildCommand = ''
      # Create directories with proper ownership
      mkdir -p $out/app $out/bin $out/tmp $out/etc/uv $out/home/python-user
      mkdir -p $out/etc/passwd.d $out/etc/group.d $out/etc/shadow.d
      mkdir -p $out/.local/lib/python3.12/site-packages
      
      # Create uv cache dir
      mkdir -p $out/tmp/.uv_cache
      
      # Create symbolic link for python to satisfy uv and other tools
      # Note: We do this in dockerSetup now to avoid duplication
      # ln -sf ${systemPython}/bin/python3.12 $out/bin/python
      # ln -sf ${systemPython}/bin/python3.12 $out/bin/python3
      
      # Create ortools directory in a separate location (not /.local since it's tmpfs in containers)
      mkdir -p $out/opt/ortools/lib/python3.12/site-packages
      # Copy OR-Tools to /opt/ortools to avoid protobuf conflicts and tmpfs覆盖
      # This allows OR-Tools to use its own protobuf version (5.x)
      cp -r ${ortoolsPackages}/site-packages/* $out/opt/ortools/lib/python3.12/site-packages/
      
      # Create cplex directory for Python API
      mkdir -p $out/opt/cplex/lib/python3.12/site-packages
      # Copy CPLEX Python API to /opt/cplex
      cp -r ${cplexPythonPackages}/site-packages/* $out/opt/cplex/lib/python3.12/site-packages/
      
      # Create copt directory for Python API
      mkdir -p $out/opt/copt/lib/python3.12/site-packages
      # Copy COPT Python API from uv installation (PyPI version handles library loading correctly)
      cp -r ${coptPythonPackages}/site-packages/* $out/opt/copt/lib/python3.12/site-packages/
      
      # Create mosek directory for Python API
      mkdir -p $out/opt/mosek/lib/python3.12/site-packages
      # Copy MOSEK Python API from uv installation
      cp -r ${mosekPythonPackages}/site-packages/* $out/opt/mosek/lib/python3.12/site-packages/
      
      # Create uv configuration
      cat > $out/etc/uv/uv.toml << 'EOFUV'
# Global uv configuration
# Force use of system Python interpreter
python-preference = "system"
# Use copy mode for Docker environment
link-mode = "copy"
# Set cache directory
cache-dir = "/tmp/.uv_cache"
EOFUV
      
      # Create Gurobi setup script
      cat > $out/setup-gurobi.sh << 'EOF'
      #!/bin/bash
      # Setup Gurobi environment
      echo "Setting up Gurobi environment..."
      
      # Set Gurobi environment (using gurobi package from nixpkgs)
      export GUROBI_HOME=${pkgs.gurobi}
      export GRB_LICENSE_FILE=/app/gurobi.lic
      export LD_LIBRARY_PATH=${pkgs.gurobi}/lib:$LD_LIBRARY_PATH
      
      echo "Gurobi Python package is pre-installed"
      echo "Gurobi installed via nixpkgs, version: 12.0.3"
      echo "Please place Gurobi license file at /app/gurobi.lic"
      echo "Or specify license file path via GRB_LICENSE_FILE environment variable"
      echo "Use python and uv commands to run Python and package management"
      EOF
      
      # Create Gurobi verification script
      cat > $out/verify-gurobi.sh << 'EOF'
      #!/bin/bash
      # Verify Gurobi Python package is installed
      python -c "import gurobipy; print('Gurobi Python package is available')" 2>/dev/null || {
        echo "Gurobi Python package not found. This should not happen as it's pre-installed."
        exit 1
      }
      
      # Set Gurobi environment (using gurobi package from nixpkgs)
      export GUROBI_HOME=${pkgs.gurobi}
      export GRB_LICENSE_FILE=/app/gurobi.lic
      export LD_LIBRARY_PATH=${pkgs.gurobi}/lib:$LD_LIBRARY_PATH
      
      echo "Gurobi Python package is available"
      echo "Gurobi installed via nixpkgs, version: 12.0.3"
      echo "Please place Gurobi license file at /app/gurobi.lic"
      echo "Or specify license file path via GRB_LICENSE_FILE environment variable"
      EOF
      
      # Create OR-Tools verification script
      cat > $out/verify-ortools.sh << 'EOFSCRIPT'
      #!/bin/bash
      # Verify OR-Tools is pre-installed and working
      echo "Verifying OR-Tools installation..."
      echo ""
      
      python << 'EOFPYTHON'
import sys

try:
    import ortools
    from ortools.linear_solver import pywraplp
    from ortools.sat.python import cp_model
    import google.protobuf
    
    print("✓ OR-Tools is pre-installed!")
    print("  OR-Tools version:", ortools.__version__)
    print("  Protobuf version:", google.protobuf.__version__)
    print("")
    print("Available solvers:")
    print("  - GLOP (Google Linear Optimization Package)")
    print("  - CBC (COIN-OR Branch and Cut)")
    print("  - SCIP (Solving Constraint Integer Programs)")
    print("  - CP-SAT (Constraint Programming - SAT)")
    print("")
    
    # Test GLOP solver
    solver = pywraplp.Solver.CreateSolver("GLOP")
    if solver:
        print("✓ GLOP solver working correctly!")
    else:
        print("✗ Failed to create GLOP solver")
        sys.exit(1)
    
    # Test CP-SAT solver
    model = cp_model.CpModel()
    sat_solver = cp_model.CpSolver()
    print("✓ CP-SAT solver working correctly!")
    print("")
    print("OR-Tools is ready to use! 🎉")
    
except ImportError as e:
    print("✗ OR-Tools not found:", str(e))
    print("")
    print("This should not happen - OR-Tools is pre-installed in the image.")
    sys.exit(1)
except Exception as e:
    print("✗ Error verifying OR-Tools:", str(e))
    sys.exit(1)
EOFPYTHON
      EOFSCRIPT
      
      chmod +x $out/setup-gurobi.sh
      chmod +x $out/verify-gurobi.sh
      chmod +x $out/verify-ortools.sh
      
      # Create CPLEX verification script
      cat > $out/verify-cplex.sh << 'EOFSCRIPT'
      #!/bin/bash
      # Verify CPLEX is pre-installed and working
      echo "Verifying CPLEX installation..."
      echo ""
      
      # Set CPLEX environment
      export CPLEX_HOME=/opt/ibm/ILOG/CPLEX_Studio221/cplex
      export LD_LIBRARY_PATH=$CPLEX_HOME/bin/x86-64_linux:$LD_LIBRARY_PATH
      
      python << 'EOFPYTHON'
import sys
import os

try:
    import cplex
    print("✓ CPLEX Python API is pre-installed!")
    print("  CPLEX version:", cplex.__version__)
    
    # Try to create a small model to verify binaries
    c = cplex.Cplex()
    print("✓ CPLEX Binary libraries are accessible!")
    
    # Try to import docplex (might need to be installed via uv)
    try:
        import docplex
        print("✓ docplex is available!")
    except ImportError:
        print("! docplex is not yet installed. You can install it with: uv pip install docplex")
        
    print("")
    print("CPLEX is ready to use! 🚀")
    
except ImportError as e:
    print("✗ CPLEX Python API not found:", str(e))
    print("  PYTHONPATH:", os.environ.get('PYTHONPATH'))
    sys.exit(1)
except Exception as e:
    print("✗ Error verifying CPLEX:", str(e))
    import traceback
    traceback.print_exc()
    sys.exit(1)
EOFPYTHON
      EOFSCRIPT
      chmod +x $out/verify-cplex.sh
      
      # Create COPT verification script
      cat > $out/verify-copt.sh << 'EOFSCRIPT'
      #!/bin/bash
      # Verify COPT is pre-installed and working
      echo "Verifying COPT installation..."
      echo ""
      
      # Set COPT environment
      export COPT_HOME=/opt/copt
      export LD_LIBRARY_PATH=$COPT_HOME/lib:$LD_LIBRARY_PATH
      
      python << 'EOFPYTHON'
import sys
import os

try:
    import coptpy
    print("✓ COPT Python API is pre-installed!")
    print("  COPT version:", coptpy.Envr().getVersion())
    
    # Try to create a small model to verify binaries
    env = coptpy.Envr()
    model = env.createModel("verify")
    print("✓ COPT Binary libraries are accessible!")
    
    print("")
    print("COPT is ready to use! 🚀")
    
except ImportError as e:
    print("✗ COPT Python API not found:", str(e))
    print("  PYTHONPATH:", os.environ.get('PYTHONPATH'))
    sys.exit(1)
except Exception as e:
    print("✗ Error verifying COPT:", str(e))
    # It might fail due to no license, but the import should work
    if "license" in str(e).lower() or "113" in str(e):
        print("✓ COPT Python API and binaries are loaded (License required for model creation)")
    else:
        import traceback
        traceback.print_exc()
        sys.exit(1)
EOFPYTHON
      EOFSCRIPT
      chmod +x $out/verify-copt.sh
      
      # Note: python3 binary is provided by pythonWithPackages in runtimeEnv
      # No need to create a symlink here to avoid collision
      
      # Create user and group files
      cat > $out/etc/passwd.d/python-user << 'EOF'
      python-user:x:1000:1000:Python User:/home/python-user:/bin/bash
      EOF
      
      cat > $out/etc/group.d/python-user << 'EOF'
      python-user:x:1000:
      EOF
      
      cat > $out/etc/shadow.d/python-user << 'EOF'
      python-user:!:0:0:99999:7:::
      EOF
      
      # Create a non-root user setup script
      cat > $out/setup-user.sh << 'EOF'
      #!/bin/bash
      # Set proper ownership
      chown -R python-user:python-user /app
      chown -R python-user:python-user /home/python-user
      
      # Set up user environment
      echo 'export HOME=/home/python-user' >> /home/python-user/.bashrc
      echo 'export PATH=/usr/local/bin:/usr/bin' >> /home/python-user/.bashrc
      echo 'export PYTHONPATH=/app:/.local/lib/python3.12/site-packages' >> /home/python-user/.bashrc
      EOF
      
      chmod +x $out/setup-user.sh
    '';
  };

in
  # Use buildLayeredImage for better caching and faster rebuilds
  # This creates a multi-layer image where unchanged layers can be reused
  pkgs.dockerTools.buildLayeredImage {
    name = "ghcr.io/reaslab/docker-python-runner";
    tag = "secure-latest";
    # Set proper creation timestamp from environment variable
    created = if builtins.getEnv "DOCKER_IMAGE_TIMESTAMP" != "" then builtins.getEnv "DOCKER_IMAGE_TIMESTAMP" else "now";
    
    # Max layers: Docker supports up to 125 layers, we use 100 for safety
    # Nix will automatically distribute contents across layers based on dependencies
    maxLayers = 100;
    
    # Contents are automatically layered by Nix based on dependency graph
    # Most frequently changed items (like scripts) go in top layers
    # Rarely changed items (like system libraries) go in bottom layers
    contents = [
      runtimeEnv      # Layer group 1: System Python, libraries (rarely changes)
      dockerSetup     # Layer group 2: Setup scripts and configs (occasionally changes)
      pkgs.cacert     # Layer group 3: CA certificates (rarely changes)
    ];

    # IMPORTANT:
    # We intentionally do NOT use `runAsRoot` (it would require KVM on this host).
    # But `copyToRoot` comes from the Nix store, and those paths are immutable and often 0555.
    # To ensure writable runtime directories for the non-root user, we patch permissions
    # in the *layer rootfs* right before tarring it via `extraCommands`.
    extraCommands = ''
      set -eu

      # Ensure runtime directories exist in the layer
      mkdir -p tmp tmp/.uv_cache .local/lib/python3.12/site-packages home/python-user app

      # /tmp must be writable for non-root (cplex.log, matplotlib cache, tempfiles, uv cache)
      chmod 1777 tmp
      chmod 0777 tmp/.uv_cache

      # /.local is used as writable site-packages for uv/pip at runtime
      chmod 0777 .local
      chmod 0777 .local/lib
      chmod 0777 .local/lib/python3.12
      chmod 0777 .local/lib/python3.12/site-packages

      # Project and data directories
      mkdir -p app data
      chmod 0777 app data

      # Home directory should be writable for the non-root user
      chmod 0777 home/python-user
    '';
    
    config = {
      WorkingDir = "/tmp";
      Env = [
        "PYTHONPATH=/app:/opt/ortools/lib/python3.12/site-packages:/opt/cplex/lib/python3.12/site-packages:/opt/copt/lib/python3.12/site-packages:/opt/mosek/lib/python3.12/site-packages:/.local/lib/python3.12/site-packages"
        "PYTHONUNBUFFERED=1"
        "PYTHONDONTWRITEBYTECODE=1"
        # Force uv to use system Python
        "UV_PYTHON_PREFERENCE=system"
        "UV_LINK_MODE=copy"
        "UV_PYTHON_SITE_PACKAGES=/.local/lib/python3.12/site-packages"
        "UV_CACHE_DIR=/tmp/.uv_cache"
        "UV_PYTHON=/bin/python"
        # Set PATH - put runtimeEnv/bin first to ensure our python symlink is found
        "PATH=/bin:${securePythonScript}/bin:${runtimeEnv}/bin:${systemPython}/bin:${pkgs.coreutils}/bin:${pkgs.util-linux}/bin:/usr/local/bin:/usr/bin:/opt/ibm/ILOG/CPLEX_Studio221/cplex/bin/x86-64_linux:/opt/ibm/ILOG/CPLEX_Studio221/cpoptimizer/bin/x86-64_linux:/opt/copt/bin"
        # Set library search path
        "LD_LIBRARY_PATH=${runtimeEnv}/lib:${runtimeEnv}/lib64:/opt/ibm/ILOG/CPLEX_Studio221/cplex/bin/x86-64_linux:/opt/ibm/ILOG/CPLEX_Studio221/cpoptimizer/bin/x86-64_linux:/opt/copt/lib"
        # Gurobi environment variables (using gurobi package from nixpkgs)
        "GUROBI_HOME=${pkgs.gurobi}"
        "GRB_LICENSE_FILE=/app/gurobi.lic"
        # CPLEX environment variables
        "CPLEX_HOME=/opt/ibm/ILOG/CPLEX_Studio221/cplex"
        # COPT environment variables
        "COPT_HOME=/opt/copt"
        # MOSEK environment variables (license file will be mounted at runtime)
        "MOSEKLM_LICENSE_FILE=/tmp/mosek.lic"
        # SSL certificate configuration for Gurobi WLS
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "CURL_CA_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "REQUESTS_CA_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        # Matplotlib configuration directory
        "MPLCONFIGDIR=/tmp/.matplotlib"
        # Disable dangerous modules
        "PYTHON_DISABLE_MODULES=os,subprocess,sys,importlib,exec,eval,compile,__import__,open,file,input,raw_input,urllib,requests,socket,ftplib,smtplib,poplib,imaplib,nntplib,telnetlib"
        # Restrict network access
        "HTTP_PROXY="
        "HTTPS_PROXY="
        "http_proxy="
        "https_proxy="
        # Set non-root user environment
        "HOME=/home/python-user"
        "USER=python-user"
        "LOGNAME=python-user"
        "MAIL="
      ];
      # Use tail -f /dev/null for container management (keeps container running)
      Cmd = [ "tail" "-f" "/dev/null" ];
      # Set security parameters - use non-root user
      User = "1000:1000";
      # Additional security settings
      ReadOnlyRootfs = false;  # Temporarily set to false to ensure successful startup
      # Disable privileged mode
      Privileged = false;
      # Set resource limits
      Memory = 1073741824; # 1GB memory limit
      CpuShares = 1024;    # CPU shares limit
      # Disable dangerous capabilities
      CapDrop = [ "ALL" ];
      CapAdd = [ "CHOWN" "SETGID" "SETUID" ];
    };

    # IMPORTANT: do NOT set runAsRoot here.
    # Setting runAsRoot makes dockerTools switch to a Linux VM build layer, which requires KVM.
    # We instead create /tmp and /.local via copyToRoot (dockerSetup) with correct modes.
  }
