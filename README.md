# SeisSol Spack Installer

This project provides a portable installer for [SeisSol](https://seissol.org), a
high-performance earthquake simulation code, using the [Spack](https://spack.io)
package manager on Linux OS. The goal is to try to reduce the barrier to entry
for new users by automating the installation process through a configuration
file that mirrors SeisSol's own build parameters.

**Tested Linux distros:**

| Name | Version | 
|---|---|
| Alma | 9,10 |
| Arch | rolling |
| Debian | 13 |
| Fedora | 43, 44 |
| Ubuntu | 22.04, 24.04, 26.04 |

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation Options](#installation-options)
- [Build Parameter File](#build-parameter-file)
- [Quick Start](#quick-start)
- [License](#license)

---

## Overview

The installer aims to automate SeisSol installation via Spack:

1. Detects the host OS and installs the required system packages for Spack.
2. Clones (or updates) Spack and activates it in the current shell.
3. Creates an isolated Spack environment (`seissol-env`). 
4. Reads build-parameter file and assembles the Spack spec string for a specific SeisSol build.
5. Builds and installs SeisSol.

All output is logged to a timestamped file in `$HOME` for later inspection.

---

## Prerequisites

| Requirement | Minimum version | 
|---|---|
| Linux (x86-64 or ARM) | - |
| Bash | 4.0 |
| Git | 2.12 | 
| awk | - | 
| Free disk space | ~20 GB | 
| RAM | ~8 GB | 

> **WSL 2 note:** if your system has less than 8 GB of RAM visible to WSL,
> add a `.wslconfig` file in your Windows home directory:
> ```ini
> [wsl2]
> memory=12GB <- your maximum RAM here
> ```
> Then restart WSL (`wsl --shutdown` in PowerShell).

---

## Installation Options

```
Usage: ./install_seissol.sh [OPTIONS]

Options:
 --params-file FILE   SeisSol build-parameter file
                      (default: seissol_params.conf in the script directory)
 -j, --jobs N         Parallel build jobs (default: nproc − 1)
 --spack-dir DIR      Where to clone or find Spack (default: ~/spack)
 --spack-env STR      Spack environment name (default: seissol-env)
 --log FILE           Custom log file path
                      (default: ~/seissol_install_YYYYMMDD_HHMMSS.log)
 --gcc-14             Build gcc-14 from source / export it to PATH
 -y, --yes            Skip the confirmation prompt
 -h, --help           Show usage and exit
```

### Examples

```bash
# Minimal - use a params file (parallelism: all cores - 1)
./install_seissol.sh --params-file path/to/seissol_params.conf

# Limit parallelism on a memory-constrained machine
./install_seissol.sh --params-file path/to/seissol_params.conf -j 4

# Custom Spack location
./install_seissol.sh --spack-dir /opt/spack

# Save log to a custom path
./install_seissol.sh --log /tmp/seissol_build.log

# Build and use GCC-14 from source (compatibility option)
./install_seissol.sh --gcc-14
```

> **.conf file note:** --params-file is optional, the program defaults to
> looking for 'seissol_params.conf' in the main directory.

---

## Build Parameter File

The parameter file controls SeisSol Spack variants. The format is:

```
# comment
param_name = value
```

Blank lines and lines starting with `#` are ignored. Inline comments
(everything after the first `#`) are also stripped.

### Value mapping to Spack tokens

| Value in file | Spack token produced |
|---|---|
| `version = master` | `seissol@master` |
| `with_mpi = true` | `+with_mpi` |
| `with_asagi = false` | `~with_asagi` |
| `equations = elastic` | `equations=elastic` |
| `gemm_tools_list = LIBXSMM,PSpaMM` | `gemm_tools_list=LIBXSMM,PSpaMM` |

Full parameter reference:
1. <https://seissol.readthedocs.io/en/latest/build-parameters.html>
2. <https://packages.spack.io/package.html?name=seissol>

### Implicit dependency pins

In addition to the variants you set in the parameter file, the installer
appends two constraints to the assembled Spack spec to work around known
incompatibilities in SeisSol's dependency tree:

| Constraint | Reason | When applied |
|---|---|---|
| `^netcdf-c@4.9:` | `netcdf-c` 4.8.x fails to build with C23 (default in GCC 15+) | Only when the `netcdf` variant is **not** disabled in the params file. Setting `netcdf = false` skips this pin. |
| `^py-matplotlib@3.5:` | `py-matplotlib` 3.2.x is incompatible with FreeType ≥ 2.11 | Always added. Spack ignores `^`-constraints for dependencies that aren't actually in the resolved DAG, so this is a no-op when matplotlib isn't pulled in. |

If a future SeisSol or Spack release fixes these upstream, the pins can be
removed from `install_seissol.sh` (search for `netcdf-c` and `py-matplotlib`).

---

## Quick Start

### Installation

```bash
# 1. Clone this repository
git clone https://github.com/lucioquadros/seissol-spack-installer.git
cd seissol-spack-installer

# 2. Make the installer executable
chmod +x install_seissol.sh

# 3. Edit a parameter file
$EDITOR seissol_params.conf  # adjust convergence_order, equations, etc. 

# 4. Run the installer
./install_seissol.sh

# 5. After installation, activate the environment in any new shell
source ~/spack/share/spack/setup-env.sh
spack env activate seissol-env
```

The first run downloads and compiles all dependencies. It may take several minutes
depending on your hardware and internet connection. Even more if compiling GCC-14 from source ('--gcc-14' option).

See [Build Parameter File](#build-parameter-file) for parameter references.

### After installation

```bash
# Activate in a new shell
source ~/spack/share/spack/setup-env.sh
spack env activate seissol-env

# Verify SeisSol binaries
which SeisSol_Release_*
```

> **SeisSol variants note:** multiple installations with different SeisSol
> parameters is possible. Rerun the script with the new parameters. If you want
> to preserve both installations, pass a new environment name via
> --spack-env <new_name>.
> Spack will reuse the compatible dependencies, so a new run will be faster.

---

## License

This project is licensed under the MIT License - see [LICENSE](LICENSE) for
the full text.

SeisSol itself is licensed under the BSD 3-Clause License.
Spack is licensed under the MIT and Apache-2.0 licenses.
