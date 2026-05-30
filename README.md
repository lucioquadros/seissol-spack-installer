# SeisSol Spack Installer

This project provides a portable installer for [SeisSol](https://seissol.org), a
high-performance earthquake simulation code, using the [Spack](https://spack.io)
package manager on Linux OS. The goal is to try to reduce the barrier to entry
for new users by automating the installation process on local workstations
through a configuration file that mirrors SeisSol's own build parameters.

**Tested Linux distros:**

| Name | Version | 
|---|---|
| Alma | 9,10 |
| Arch | rolling |
| Debian | 13 |
| Fedora | 43, 44 |
| Suse Leap | 16 |
| Ubuntu | 22.04, 24.04, 26.04 |

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Installation Options](#installation-options)
- [Build Parameter File](#build-parameter-file)
- [Example Configurations](#example-configurations)
- [License](#license)

---

## Overview

The installer aims to automate SeisSol installation via Spack:

1. Detects the host OS and, when `--install-deps` is passed, installs the
   required system packages for Spack. Without that flag it assumes the
   dependencies are already present and proceeds straight to Spack.
2. Clones (or updates) Spack and activates it in the current shell.
3. Creates an isolated Spack environment (`seissol-env`). 
4. Reads build-parameter file and assembles the Spack spec string for a specific SeisSol build.
5. Builds and installs SeisSol.

All output is logged to a timestamped file in `$HOME` for later inspection.

---

## Prerequisites

| Requirement | Minimum | 
|---|---|
| Linux (x86-64 or ARM) | - |
| Bash | 4.0 |
| Git | 2.12 | 
| awk | - | 
| Free disk space | ~30 GB | 
| RAM | ~16 GB | 

> **Low-RAM / GPU builds note:** on machines with 16 GB of RAM or less, large
> builds can be a problem, e.g. a "cuda = true" build. If you have problems,
> stage builds on disk by re-running with "--build-dir ${HOME}/spack/tmp".

---

## Quick Start

### Installation

```bash
# 1. Clone this repository
git clone https://github.com/lucioquadros/seissol-spack-installer.git
cd seissol-spack-installer

# 2. Make the installer executable
chmod +x install_seissol.sh

# 3. [OPTIONAL] Edit a parameter file
$EDITOR seissol_params.conf  # adjust convergence_order, equations, etc. 

# 4. Run the installer
#    If this is your first run and you are unsure whether the system
#    dependencies that Spack needs are already installed, add --install-deps
./install_seissol.sh --install-deps
```

The first run downloads and compiles all dependencies. It may take several minutes
depending on your hardware and internet connection. Even more if compiling GCC-14 from source ('--gcc-14' option).

### After installation

```bash
# 5. Activate environment
source ~/spack/share/spack/setup-env.sh
spack env activate seissol-env

# 6. Verify SeisSol binaries (e.g.)
compgen -c | grep "SeisSol_*"
```

> **SeisSol variants note:** multiple installations with different SeisSol build
> parameters are possible. Rerun the script with the new parameters in your
> configuration file. If you want to preserve both installations, create a new
> environment via --spack-env <new_name>.  Spack will reuse the compatible
> dependencies, so a new run will be faster.

---

## Installation Options

```
Usage: ./install_seissol.sh [OPTIONS]

Options:
 --params-file FILE   SeisSol build-parameter file
                      (default: seissol_params.conf in the script directory)
 --install-deps       Install system dependencies for Spack via the OS package
                      manager (apt / dnf / zypper / pacman). If omitted, the
                      dependencies are assumed to be already met and the script
                      proceeds straight to the Spack install.
 -j, --jobs N         Parallel build jobs (default: nproc − 1)
 --spack-dir DIR      Where to clone or find Spack (default: ~/spack)
 --spack-env STR      Spack environment name (default: seissol-env)
 --build-dir DIR      Build staging directory; sets TMPDIR to DIR.
                      (default: system TMPDIR)
 --log FILE           Custom log file path
                      (default: ~/seissol_install_YYYYMMDD_HHMMSS.log)
 --gcc-14             Build gcc-14 from source / export it to PATH
 --spec-extra SPEC    Extra Spack spec constraints appended to the SeisSol spec.
                      Repeatable. E.g. --spec-extra "^cuda@12".
 -y, --yes            Skip the confirmation prompt
 -h, --help           Show usage and exit
```

### Examples

```bash
# Minimal - use a params file (parallelism: all cores - 1)
./install_seissol.sh --params-file path/to/seissol_params.conf

# First run / unsure if Spack's system dependencies are present:
# let the script install them via your OS package manager
./install_seissol.sh --install-deps

# Choose number of parallel jobs
./install_seissol.sh --params-file path/to/seissol_params.conf -j 4

# Change stage build directory
# (recommended for low-RAM machines and large cuda/GPU builds)
./install_seissol.sh --build-dir ${HOME}/spack/tmp

# Custom Spack location
./install_seissol.sh --spack-dir /opt/spack

# Save log to a custom path
./install_seissol.sh --log /tmp/seissol_build.log

# Build and use GCC-14 from source (compatibility option)
./install_seissol.sh --gcc-14

# Append extra Spack spec constraints (repeatable).
./install_seissol.sh --spec-extra "^cuda@12" --spec-extra "^netcdf-c@4.9:"

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
| `cuda = true` | `+cuda` |
| `asagi = false` | `~asagi` |
| `equations = elastic` | `equations=elastic` |
| `gemm_tools_list = LIBXSMM,PSpaMM` | `gemm_tools_list=LIBXSMM,PSpaMM` |

Full parameter reference:
1. <https://packages.spack.io/package.html?name=seissol>
2. <https://seissol.readthedocs.io/en/latest/build-parameters.html>

---

## Example Configurations

The `conf_examples/` directory holds examples of parameter files for
SeisSol builds. Point `--params-file` at one (or copy it to
`seissol_params.conf`) and edit as needed.

---

## License

This project is licensed under the MIT License - see [LICENSE](LICENSE) for
the full text.

SeisSol itself is licensed under the BSD 3-Clause License.
Spack is licensed under the MIT and Apache-2.0 licenses.
