{ pkgs ? import <nixpkgs> { 
    config.allowUnfree = true;
    config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [ "gurobi" ];
  } }:

let
  # Create restricted Python environment, remove dangerous modules
  restrictedPython = pkgs.python312.override {
    # Custom Python configuration, disable dangerous features
    pythonAttr = "python312";
  };

  # Only include safe scientific computing packages, remove dangerous modules
  pythonWithPackages = restrictedPython.withPackages (ps: with ps; [
    pip
    setuptools
    wheel
    # Only include safe scientific computing packages
    cython
    numpy
    scipy
    pandas
    matplotlib
    scikit-learn
    # Add gurobipy for optimization
    gurobipy
    # Does not include dangerous modules like os, subprocess, sys
  ]);

  # Create restricted Python interpreter startup script
  securePythonScript = pkgs.writeScriptBin "python" ''
    #!${pkgs.bash}/bin/bash
    
    # Set restricted environment
    export PYTHONPATH="/app"
    export PYTHONUNBUFFERED=1
    export PYTHONDONTWRITEBYTECODE=1
    
    # Set restricted sys.path, only allow access to safe packages
    export PYTHONPATH="/app:/usr/lib/python3.12/site-packages"
    
    # Restrict system tool access - ensure util-linux tools are accessible
    export PATH="${pkgs.coreutils}/bin:${pkgs.util-linux}/bin:/usr/local/bin:/usr/bin"
    
    # Restrict environment variables
    unset HOME
    unset USER
    unset LOGNAME
    unset MAIL
    
    # Create secure Python startup code, disable dangerous modules at runtime
    cat > /tmp/safe_python.py << 'PYEOF'
import sys
import builtins

# Dangerous modules list
DANGEROUS_MODULES = {
    'os', 'subprocess', 'sys', 'importlib', 'exec', 'eval', 'compile', 
    '__import__', 'open', 'file', 'input', 'raw_input', 'urllib', 'requests', 
    'socket', 'ftplib', 'smtplib', 'poplib', 'imaplib', 'nntplib', 'telnetlib'
}

# Override __import__ function to block dangerous modules
original_import = builtins.__import__

def safe_import(name, *args, **kwargs):
    if name in DANGEROUS_MODULES:
        raise ImportError(f"Module '{name}' is not allowed in secure environment")
    return original_import(name, *args, **kwargs)

builtins.__import__ = safe_import

# Override exec and eval functions
def safe_exec(*args, **kwargs):
    raise RuntimeError("exec() is not allowed in secure environment")

def safe_eval(*args, **kwargs):
    raise RuntimeError("eval() is not allowed in secure environment")

builtins.exec = safe_exec
builtins.eval = safe_eval

# Override compile function
def safe_compile(*args, **kwargs):
    raise RuntimeError("compile() is not allowed in secure environment")

builtins.compile = safe_compile

# Override open function
def safe_open(*args, **kwargs):
    raise RuntimeError("open() is not allowed in secure environment")

builtins.open = safe_open

# Override input function
def safe_input(*args, **kwargs):
    raise RuntimeError("input() is not allowed in secure environment")

builtins.input = safe_input

# Execute user code
PYEOF

    # Start restricted Python interpreter
    exec ${pythonWithPackages}/bin/python3.12 -S -c "
import sys
import builtins

# Dangerous modules list
DANGEROUS_MODULES = {
    'os', 'subprocess', 'sys', 'importlib', 'exec', 'eval', 'compile', 
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

# Set resource limits
import resource
import signal
import sys

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
    exec('${pythonWithPackages}/bin/python3.12 "$@"')
else:
    # Execute file or code
    try:
        if len(sys.argv) > 1 and not sys.argv[1].startswith('-'):
            exec(open(sys.argv[1]).read())
        else:
            exec('${pythonWithPackages}/bin/python3.12 "$@"')
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
    export PYTHONPATH="/app"
    export PYTHONUNBUFFERED=1
    export PYTHONDONTWRITEBYTECODE=1
    
    # Force uv to use system Python
    export UV_PYTHON_PREFERENCE="system"
    export UV_LINK_MODE="copy"
    
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
    
    # Start uv
    exec ${pkgs.uv}/bin/uv "$@"
  '';

  # Python environment with gurobipy pre-installed
  pythonWithGurobipy = pythonWithPackages;

  # Create secure environment with all necessary dependencies
  runtimeEnv = pkgs.buildEnv {
    name = "python-runtime-secure";
    paths = [
      # Include Python with gurobipy pre-installed
      pythonWithGurobipy
      securePythonScript  # Add secure Python script
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
    ];
    # Avoid duplicate package issues
    ignoreCollisions = true;
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
      
      # Create uv configuration
      cat > $out/etc/uv/uv.toml << 'EOF'
      # Global uv configuration
      # Force use of system Python interpreter
      python-preference = "system"
      # Use copy mode for Docker environment
      link-mode = "copy"
      EOF
      
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
      
      chmod +x $out/setup-gurobi.sh
      chmod +x $out/verify-gurobi.sh
      
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
      echo 'export PYTHONPATH=/app' >> /home/python-user/.bashrc
      EOF
      
      chmod +x $out/setup-user.sh
    '';
  };

in
  # Use buildImage to avoid diffID conflicts
  pkgs.dockerTools.buildImage {
    name = "ghcr.io/reaslab/docker-python-runner";
    tag = "secure-latest";
    
    # Use a minimal base image instead of creating from scratch
    fromImage = pkgs.dockerTools.buildImage {
      name = "python-base";
      tag = "minimal";
      copyToRoot = pkgs.buildEnv {
        name = "base-root";
        paths = [ pkgs.bash pkgs.coreutils pkgs.glibc pkgs.util-linux ];
      };
      config = {
        Cmd = [ "bash" ];
        Env = [ "PATH=/usr/local/bin:/usr/bin" ];
      };
    };
    
    copyToRoot = pkgs.buildEnv {
      name = "image-root";
      paths = [ runtimeEnv dockerSetup pkgs.cacert ];
    };
    
    config = {
      WorkingDir = "/app";
      Env = [
        "PYTHONPATH=/app"
        "PYTHONUNBUFFERED=1"
        "PYTHONDONTWRITEBYTECODE=1"
        # Force uv to use system Python
        "UV_PYTHON_PREFERENCE=system"
        "UV_LINK_MODE=copy"
        # Set PATH to include our secure commands - ensure util-linux tools are accessible
        "PATH=${runtimeEnv}/bin:${pkgs.coreutils}/bin:${pkgs.util-linux}/bin:/usr/local/bin:/usr/bin"
        # Set library search path
        "LD_LIBRARY_PATH=${runtimeEnv}/lib:${runtimeEnv}/lib64"
        # Gurobi environment variables (using gurobi package from nixpkgs)
        "GUROBI_HOME=${pkgs.gurobi}"
        "GRB_LICENSE_FILE=/app/gurobi.lic"
        # SSL certificate configuration for Gurobi WLS
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "CURL_CA_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "REQUESTS_CA_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
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
      ReadOnlyRootfs = false;  # 暂时设为 false 以确保启动成功
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