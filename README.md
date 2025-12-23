# docker-python-runner

A secure, production-ready Docker environment for Python development with UV package manager, built with Nix for maximum security and reproducibility.

## Features

- **Nix-based Build**: Reproducible builds using Nix dockerTools
- **Secure Python Environment**: Restricted Python interpreter with disabled dangerous modules
- **UV Package Manager**: Fast Python package and dependency manager
- **Optimization Solvers Pre-installed**:
  - **Gurobi**: Commercial optimization solver (12.0.3) - requires license
  - **CPLEX**: IBM ILOG CPLEX Optimization Studio (22.1.2) - requires license
  - **OR-Tools**: Google's open-source suite (GLOP, CBC, SCIP, CP-SAT) - no license required
- **Non-root User**: Runs as non-privileged user for security
- **Resource Limits**: Built-in CPU and memory limits
- **Read-only Root**: Root filesystem is read-only
- **Network Isolation**: Restricted network access

## Quick Start

### Using Prebuilt Images

Prebuilt images are available on [GitHub Container Registry](https://github.com/reaslab/docker-python-runner/pkgs/container/docker-python-runner):

```bash
# Pull the latest secure image
docker pull ghcr.io/reaslab/docker-python-runner:secure-latest

# Run a Python container
docker run --rm -it ghcr.io/reaslab/docker-python-runner:secure-latest python --version
```

### Available Tags

| Image Tag | Description |
|-----------|-------------|
| `secure-latest` | Latest secure Python 3.12 with UV and Gurobi |
| `secure-{timestamp}` | Timestamped version (e.g., `secure-20250115-143022`) |
| `secure-{sha}` | Git commit SHA version (e.g., `secure-a1b2c3d`) |

## Usage

### Basic Usage

```bash
# Run Python code
docker run --rm ghcr.io/reaslab/docker-python-runner:secure-latest python -c "print('Hello, World!')"

# Interactive shell
docker run --rm -it ghcr.io/reaslab/docker-python-runner:secure-latest bash

# Run with volume mount
docker run --rm -v $(pwd):/app ghcr.io/reaslab/docker-python-runner:secure-latest python /app/script.py
```

### With UV Package Manager

```bash
# Create a new project
docker run --rm -v $(pwd):/app ghcr.io/reaslab/docker-python-runner:secure-latest uv init my-project

# Install packages
docker run --rm -v $(pwd):/app ghcr.io/reaslab/docker-python-runner:secure-latest uv add numpy pandas

# Run with dependencies
docker run --rm -v $(pwd):/app ghcr.io/reaslab/docker-python-runner:secure-latest uv run python script.py
```

### With Gurobi Optimization

```bash
# Set up Gurobi license
export GRB_LICENSE_FILE=/path/to/gurobi.lic

# Run optimization code
docker run --rm \
  -v $(pwd):/app \
  -v /path/to/gurobi.lic:/app/gurobi.lic:ro \
  -e GRB_LICENSE_FILE=/app/gurobi.lic \
  ghcr.io/reaslab/docker-python-runner:secure-latest python optimization.py
```

### With CPLEX Optimization

```bash
# Run CPLEX optimization code
# CPLEX is pre-installed at /opt/ibm/ILOG/CPLEX_Studio221
docker run --rm -v $(pwd):/app \
  ghcr.io/reaslab/docker-python-runner:secure-latest python -c "
import cplex
print(f'CPLEX Version: {cplex.__version__}')
# ... your optimization code ...
"

# Verify CPLEX installation
docker run --rm ghcr.io/reaslab/docker-python-runner:secure-latest /verify-cplex.sh
```

### With OR-Tools Optimization

```bash
# OR-Tools is pre-installed, no license required!
# Run optimization code directly
docker run --rm -v $(pwd):/app \
  ghcr.io/reaslab/docker-python-runner:secure-latest python -c "
from ortools.linear_solver import pywraplp

# Create a GLOP solver
solver = pywraplp.Solver.CreateSolver('GLOP')

# Define variables
x = solver.NumVar(0, 10, 'x')
y = solver.NumVar(0, 10, 'y')

# Define objective: maximize 3x + 4y
solver.Maximize(3 * x + 4 * y)

# Add constraint: x + 2y <= 14
solver.Add(x + 2 * y <= 14)

# Solve
status = solver.Solve()
if status == pywraplp.Solver.OPTIMAL:
    print(f'Optimal solution: x={x.solution_value()}, y={y.solution_value()}')
    print(f'Objective value: {solver.Objective().Value()}')
"

# Verify OR-Tools installation
docker run --rm ghcr.io/reaslab/docker-python-runner:secure-latest /verify-ortools.sh
```

## Security Features

- **Restricted Python**: Dangerous modules (os, subprocess, sys, etc.) are disabled
- **Non-root User**: Runs as user `python-user` (UID 1000)
- **Resource Limits**: 1GB memory limit, CPU shares limit
- **Read-only Root**: Root filesystem is read-only
- **Network Isolation**: Limited network access
- **No Privileges**: Runs without privileged capabilities
- **Capability Dropping**: All dangerous capabilities are dropped

## Pre-installed Packages

- **Core**: pip, setuptools, wheel
- **Scientific**: numpy, scipy, pandas, matplotlib, scikit-learn
- **Visualization**: seaborn
- **Optimization**: 
  - **gurobipy** (Gurobi 12.0.3) - Pre-installed, requires license
  - **cplex** (IBM CPLEX 22.1.2) - Pre-installed, requires license
  - **ortools** (Google OR-Tools) - Pre-installed, no license required ✨
- **Build Tools**: cython
- **Package Manager**: uv

### OR-Tools Solvers (Pre-installed)

OR-Tools is fully pre-installed with the following solvers:

- **GLOP**: Google's linear programming solver (for LP problems)
- **CBC**: COIN-OR Branch and Cut solver (for MILP problems)
- **SCIP**: Solving Constraint Integer Programs (for MILP/MINLP)
- **CP-SAT**: Constraint Programming SAT solver (for constraint programming)

**Protobuf Compatibility**:
- OR-Tools uses protobuf 5.x (managed by Nix)
- Separate environment prevents conflicts with other packages
- `ignoreCollisions` enabled in buildEnv for seamless integration

**Note**: `yfinance` is excluded from pre-installation due to protobuf 6.x requirement. Install it via `uv` if needed.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `USER` | `python-user` | Username inside container |
| `UID` | `1000` | User ID |
| `GID` | `1000` | Group ID |
| `GRB_LICENSE_FILE` | `/app/gurobi.lic` | Gurobi license file path |
| `UV_PYTHON_PREFERENCE` | `system` | UV Python preference |
| `UV_LINK_MODE` | `copy` | UV link mode |
| `PYTHONPATH` | `/app` | Python path |
| `PYTHONUNBUFFERED` | `1` | Python unbuffered output |

## Development

### Building Locally

```bash
# Clone the repository
git clone https://github.com/reaslab/docker-python-runner.git
cd docker-python-runner

# Build using Nix
nix-build docker.nix --option sandbox false

# Load into Docker
docker load < result

# Tag the image
docker tag <image-id> ghcr.io/reaslab/docker-python-runner:secure-latest
```

### Using Build Script

```bash
# Use the provided build script
./build.sh

# This will:
# 1. Clean up old images
# 2. Build with Nix dockerTools
# 3. Load into Docker
# 4. Tag as secure-latest
```

### CI/CD Workflow

The Docker image is automatically built and pushed using **Ubuntu** runners when:

- **Code Push**: Pushing to `main` branch
- **Pull Request**: Creating/updating PRs to `main` branch
- **Scheduled**: Every Monday at 2 AM UTC
- **Manual**: Triggered manually via GitHub Actions UI

**Build Environment**: Ubuntu Linux with Nix Flakes for reproducible builds.
**Image Tags**: 
- `secure-latest` - Latest stable version
- `secure-{timestamp}` - Timestamped version
- `secure-{sha}` - Git commit SHA version

### Testing

```bash
# Test Python version
docker run --rm ghcr.io/reaslab/docker-python-runner:secure-latest python --version

# Test UV installation
docker run --rm ghcr.io/reaslab/docker-python-runner:secure-latest uv --version

# Test Gurobi (requires license)
docker run --rm -v /path/to/gurobi.lic:/app/gurobi.lic:ro ghcr.io/reaslab/docker-python-runner:secure-latest python -c "import gurobipy; print('Gurobi available')"

# Test CPLEX (verify installation)
docker run --rm ghcr.io/reaslab/docker-python-runner:secure-latest /verify-cplex.sh

# Test OR-Tools (pre-installed, verify)
docker run --rm ghcr.io/reaslab/docker-python-runner:secure-latest /verify-ortools.sh

# Test security restrictions
docker run --rm ghcr.io/reaslab/docker-python-runner:secure-latest python -c "
try:
    import os
    print('ERROR: os module should be restricted')
except ImportError:
    print('OK: os module is properly restricted')
"
```

## Architecture

This Docker image is built using Nix dockerTools, which provides:

- **Reproducible builds**: Same input always produces same output
- **Security**: Minimal attack surface with only necessary packages
- **Efficiency**: Optimized layer caching and minimal image size
- **Reliability**: Declarative configuration reduces human error

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes to `docker.nix` or `build.sh`
4. Test your changes locally
5. Submit a pull request

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Support

- [Issues](https://github.com/reaslab/docker-python-runner/issues)
- [Discussions](https://github.com/reaslab/docker-python-runner/discussions)
- [Documentation](https://github.com/reaslab/docker-python-runner/wiki)
