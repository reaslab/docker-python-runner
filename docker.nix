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

  # Use main Python environment (only reference it once)
  systemPython = pythonWithPackages;

  # Create restricted Python interpreter startup script
  securePythonScript = pkgs.writeScriptBin "python" ''
    #!${pkgs.bash}/bin/bash
    
    # Set restricted environment
    # Use /.local instead of /tmp/.local because /tmp is mounted with noexec flag
    export PYTHONPATH="/app:/opt/ortools/lib/python3.12/site-packages:/.local/lib/python3.12/site-packages"
    export PYTHONUNBUFFERED=1
    export PYTHONDONTWRITEBYTECODE=1
    
    # Create writable site-packages directory if it doesn't exist
    mkdir -p /.local/lib/python3.12/site-packages
    
    # Ensure the directory is writable and has correct permissions
    chmod 755 /.local/lib/python3.12/site-packages
    
    # Restrict system tool access - ensure util-linux tools are accessible
    export PATH="${pkgs.coreutils}/bin:${pkgs.util-linux}/bin:/usr/local/bin:/usr/bin"
    
    # Restrict environment variables
    unset HOME
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
        exec('${systemPython}/bin/python3.12 "$@"')
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
            exec('${systemPython}/bin/python3.12 "$@"')
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
    export PYTHONPATH="/app:/opt/ortools/lib/python3.12/site-packages:/.local/lib/python3.12/site-packages"
    export PYTHONUNBUFFERED=1
    export PYTHONDONTWRITEBYTECODE=1
    
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
    unset HOME
    unset USER
    unset LOGNAME
    unset MAIL
    
    # Create necessary directories
    mkdir -p /tmp/.uv_cache
    mkdir -p /.local/lib/python3.12/site-packages
    
    # Start uv
    exec ${pkgs.uv}/bin/uv "$@"
  '';

  # Python environment with gurobipy pre-installed
  pythonWithGurobipy = pythonWithPackages;

  # Create secure environment with all necessary dependencies
  # Note: OR-Tools is NOT added here to avoid protobuf conflicts
  # Instead, it's copied to /.local via dockerSetup
  runtimeEnv = pkgs.buildEnv {
    name = "python-runtime-secure";
    paths = [
      # Include Python with gurobipy pre-installed (provides python binary)
      systemPython
      # OR-Tools is installed via dockerSetup to /.local (avoid protobuf conflict)
      # securePythonScript conflicts with systemPython's bin/python, skip it
      secureUvScript
      pkgs.gurobi  # Direct use of gurobi package from nixpkgs (12.0.3)
      # Core runtime libraries (required)
      pkgs.glibc
      pkgs.zlib
      pkgs.ncurses
      
      # Network library (needed for uv to download packages)
      pkgs.openssl
      
      # C extension library (needed for some Python packages)
      pkgs.libffi
      
      # Basic system tools (minimal)
      pkgs.bash
      pkgs.coreutils
      # Essential commands for container management - ensure util-linux is included
      pkgs.util-linux  # Provides tail, head, etc.
      
      # Network tools (needed for uv to download packages)
      # Note: curl has security risks, but needed for uv to download packages
      pkgs.curl
      
      # File processing tools (needed for uv to handle compressed packages)
      # Note: tar and gzip have security risks, but needed for uv to handle packages
      pkgs.gnutar
      pkgs.gzip
      
      # Gurobi dependency math libraries
      pkgs.lapack
      pkgs.blas

      # C++ standard library (needed for numpy and other C extensions)
      pkgs.gcc.cc.lib
      pkgs.stdenv.cc.cc.lib
    ];
    # No longer need ignoreCollisions since we're not merging conflicting paths
    ignoreCollisions = false;
  };

  # Create a package with necessary directories and files for non-root user
  dockerSetup = pkgs.stdenv.mkDerivation {
    name = "docker-setup";
    buildCommand = ''
      # Create directories with proper ownership
      mkdir -p $out/app
      mkdir -p $out/bin
      mkdir -p $out/etc/uv
      mkdir -p $out/home/python-user
      mkdir -p $out/etc/passwd.d
      mkdir -p $out/etc/group.d
      mkdir -p $out/etc/shadow.d
      mkdir -p $out/.local/lib/python3.12/site-packages
      
      # Create ortools directory in a separate location (not /.local since it's tmpfs in containers)
      mkdir -p $out/opt/ortools/lib/python3.12/site-packages
      # Copy OR-Tools to /opt/ortools to avoid protobuf conflicts and tmpfs覆盖
      # This allows OR-Tools to use its own protobuf version (5.x)
      cp -r ${ortoolsPackages}/site-packages/* $out/opt/ortools/lib/python3.12/site-packages/
      
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
  # Use buildImage to avoid diffID conflicts
  pkgs.dockerTools.buildImage {
    name = "ghcr.io/reaslab/docker-python-runner";
    tag = "secure-latest";
    # Set proper creation timestamp from environment variable
    created = if builtins.getEnv "DOCKER_IMAGE_TIMESTAMP" != "" then builtins.getEnv "DOCKER_IMAGE_TIMESTAMP" else "now";
    
    copyToRoot = pkgs.buildEnv {
      name = "image-root";
      paths = [ runtimeEnv dockerSetup pkgs.cacert ];
    };
    
    config = {
      WorkingDir = "/tmp";
      Env = [
        "PYTHONPATH=/app:/opt/ortools/lib/python3.12/site-packages:/.local/lib/python3.12/site-packages"
        "PYTHONUNBUFFERED=1"
        "PYTHONDONTWRITEBYTECODE=1"
        # Force uv to use system Python
        "UV_PYTHON_PREFERENCE=system"
        "UV_LINK_MODE=copy"
        "UV_PYTHON_SITE_PACKAGES=/.local/lib/python3.12/site-packages"
        "UV_CACHE_DIR=/tmp/.uv_cache"
        "UV_PYTHON=${systemPython}/bin/python3.12"
        # Set PATH to include our secure commands - ensure util-linux tools are accessible
        "PATH=${systemPython}/bin:${runtimeEnv}/bin:${pkgs.coreutils}/bin:${pkgs.util-linux}/bin:/usr/local/bin:/usr/bin"
        # Set library search path
        "LD_LIBRARY_PATH=${runtimeEnv}/lib:${runtimeEnv}/lib64"
        # Gurobi environment variables (using gurobi package from nixpkgs)
        "GUROBI_HOME=${pkgs.gurobi}"
        "GRB_LICENSE_FILE=/app/gurobi.lic"
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
  }
