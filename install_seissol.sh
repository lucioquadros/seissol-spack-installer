#!/usr/bin/env bash
# ===========================================================================
#  install_seissol.sh - SeisSol installation via Spack
#  Targets (incl. WSL): Ubuntu/Debian, RHEL/Fedora, openSUSE, Arch
# ===========================================================================
# Usage: ./install_seissol.sh [OPTIONS]
#
# Options:
#  --params-file FILE   SeisSol build-parameter file
#                       (default: seissol_params.conf in the script directory)
#  --install-deps       Install system dependencies for Spack via the OS
#                       package manager.
#  -j, --jobs N         Parallel build jobs (default: SLURM_CPUS_PER_TASK if
#                       set, otherwise nproc − 1)
#  --spack-dir DIR      Where to clone or find Spack (default: ~/spack)
#  --no-spack-update    Use an existing Spack clone as is (no git fetch/pull)
#  --no-shell-rc        Do not modify ~/.bashrc or ~/.zshrc
#  --spack-env STR      Spack environment name (default: seissol-env)
#  --packages-yaml FILE Site YAML configuration to be included in the Spack
#                       environment
#  --target TARGET      Pin the CPU microarchitecture for all packages
#                       (e.g. zen4), independent of the build host
#  --fetch-only         Phase 1 of an offline install: concretize and download
#                       all sources into the mirror, without building
#  --offline            Phase 2 of an offline install: build from the mirror
#                       and lockfile of phase 1, without network access
#  --mirror-dir DIR     Source mirror for offline installs
#                       (default: <spack-dir>-mirror)
#  --build-dir DIR      Build staging dir; sets TMPDIR to DIR
#                       (default: system TMPDIR).
#  --log FILE           Custom log file path
#                       (default: ~/seissol_install_YYYYMMDD_HHMMSS.log)
#  --gcc-14             Build gcc-14 from source / export it to PATH
#  --spec-extra SPEC    Extra Spack spec constraints appended to the SeisSol
#                       spec (repeatable).
#  -y, --yes            Skip the confirmation prompt
#  -h, --help           Show usage and exit
# ===========================================================================

set -euo pipefail

# ===========================================================================
# DEFAULT CONFIGURATION
# ===========================================================================
SPACK_DIR="${HOME}/spack"
SPACK_ENV_NAME="seissol-env"
JOBS=""                     # empty = auto-detect
LOG_FILE="${HOME}/seissol_install_$(date +%Y%m%d_%H%M%S).log"
SPACK_BRANCH="releases/v1.1"
SEISSOL_PARAMS_FILE="seissol_params.conf"
PARAMS_FILE_SET=false
BUILD_GCC=false
GCC_V=""
AUTO_YES=false
INSTALL_DEPS=false
SPACK_UPDATE=true
SHELL_RC_UPDATE=true
OFFLINE=false
SPEC_EXTRA=""
PACKAGES_YAML=""
TARGET=""
FETCH_ONLY=false
MIRROR_DIR=""               # empty = <SPACK_DIR>-mirror
MIRROR_NAME="seissol-installer"
FETCH_MARKER=".seissol-installer-fetch"
BUILTIN_REPO_DIR=""
SEISSOL_POROELASTIC=false   # auto set true when equations=poroelastic (seissol workaround)

# Populated by GCC helper
GCC_HELPER=""
GCC_VERSION=""
GCC_MAJOR=""
GCC_PREFIX=""

# Build staging directory
BUILD_TMPDIR=""

# ===========================================================================
# COLOUR / LOGGING
# ===========================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

_ts()         { date '+%Y-%m-%d %H:%M:%S'; }
_log()        { echo -e "[$(_ts)] $*" | tee -a "${LOG_FILE}"; }
log_info()    { _log "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { _log "${GREEN}[OK]${NC}    $*"; }
log_warn()    { _log "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { _log "${RED}[ERROR]${NC} $*"; }
log_section() { _log "${BOLD}${CYAN}>>> $* <<<${NC}"; }
log_step()    { _log "${BOLD}----- $* ${NC}"; }

die() { log_error "$*"; exit 1; }

# ===========================================================================
# ARGUMENT PARSING AND HELP
# ===========================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --params-file|-j|--jobs|--spack-dir|--spack-env|--packages-yaml|\
            --target|--mirror-dir|--build-dir|--log|--spec-extra)
                [[ $# -ge 2 ]] || die "$1 requires a value. Run with -h for help." ;;
        esac
        case "$1" in
            --params-file) SEISSOL_PARAMS_FILE="$2"; PARAMS_FILE_SET=true; shift 2 ;;
            --install-deps) INSTALL_DEPS=true;                             shift 1 ;;
            -j|--jobs)     JOBS="$2";                                      shift 2 ;;
            --spack-dir)   SPACK_DIR="$2";                                 shift 2 ;;
            --spack-env)   SPACK_ENV_NAME="$2";                            shift 2 ;;
            --no-spack-update) SPACK_UPDATE=false;                         shift 1 ;;
            --no-shell-rc) SHELL_RC_UPDATE=false;                          shift 1 ;;
            --packages-yaml) PACKAGES_YAML="$2";                           shift 2 ;;
            --target)      TARGET="$2";                                    shift 2 ;;
            --fetch-only)  FETCH_ONLY=true;                                shift 1 ;;
            --offline)     OFFLINE=true;                                   shift 1 ;;
            --mirror-dir)  MIRROR_DIR="$2";                                shift 2 ;;
            --build-dir)   BUILD_TMPDIR="$2";                              shift 2 ;;
            --log)         LOG_FILE="$2";                                  shift 2 ;;
            --gcc-14)      BUILD_GCC=true;                                 shift 1 ;;
            --spec-extra)  SPEC_EXTRA="${SPEC_EXTRA:+${SPEC_EXTRA} }$2";   shift 2 ;;
            -y|--yes)      AUTO_YES=true;                                  shift 1 ;;
            -h|--help)     usage; exit 0 ;;  
            *) die "Unknown option: $1. Run with -h for help." ;;
        esac
    done
}

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

validate_args() {
    if [[ "${FETCH_ONLY}" == "true" && "${OFFLINE}" == "true" ]]; then
        die "--fetch-only and --offline are separate phases. Use one at a time."
    fi
    if [[ "${OFFLINE}" == "true" ]]; then
        local phase1_only=()
        [[ "${INSTALL_DEPS}" == "false" ]] || phase1_only+=(--install-deps)
        [[ -z "${PACKAGES_YAML}" ]] || phase1_only+=(--packages-yaml)
        [[ -z "${TARGET}" ]] || phase1_only+=(--target)
        [[ "${BUILD_GCC}" == "false" ]] || phase1_only+=(--gcc-14)
        if [[ ${#phase1_only[@]} -gt 0 ]]; then
            die "--offline cannot be combined with ${phase1_only[*]} (these belong to phase 1, --fetch-only)."
        fi
        if [[ -n "${SPEC_EXTRA}" && "${PARAMS_FILE_SET}" == "false" ]]; then
            die "With --offline, --spec-extra is only used together with --params-file."
        fi
        SPACK_UPDATE=false
    fi
    if [[ "${OFFLINE}" == "false" || "${PARAMS_FILE_SET}" == "true" ]]; then
        [[ -f "${SEISSOL_PARAMS_FILE}" && -r "${SEISSOL_PARAMS_FILE}" ]] || \
            die "--params-file: file not found or not readable: ${SEISSOL_PARAMS_FILE}"
    fi
    if [[ -n "${PACKAGES_YAML}" ]]; then
        [[ -f "${PACKAGES_YAML}" && -r "${PACKAGES_YAML}" ]] || \
            die "--packages-yaml: file not found or not readable: ${PACKAGES_YAML}"
    fi
    if [[ -n "${TARGET}" && ! "${TARGET}" =~ ^[A-Za-z0-9_]+$ ]]; then
        die "--target: invalid target name '${TARGET}' (expected e.g. zen4, x86_64_v3)."
    fi
    if [[ -n "${MIRROR_DIR}" && "${FETCH_ONLY}" == "false" && "${OFFLINE}" == "false" ]]; then
        die "--mirror-dir is only used together with --fetch-only or --offline."
    fi
    if [[ "${FETCH_ONLY}" == "true" ]]; then
        MIRROR_DIR="${MIRROR_DIR:-${SPACK_DIR}-mirror}"
    fi
}

# ===========================================================================
# USER CONFIRMATION
# ===========================================================================
confirm_with_user() {
    echo ""
    echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${YELLOW}║              SEISSOL SPACK INSTALLER - PLEASE READ                   ║${NC}"
    echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  This script will make the following changes to your system:"
    echo ""
    echo -e "  ${BOLD}Changes requiring sudo (system-wide):${NC}"
    echo -e "   1. ${BOLD}${YELLOW}[--install-deps flag only]${NC} Install Spack requirements and"
    echo -e "      compiler packages via your package manager (apt / dnf / zypper /"
    echo -e "      pacman). Without --install-deps these dependencies are assumed"
    echo -e "      to be already installed and this step is skipped."
    echo -e "   2. ${BOLD}${YELLOW}[Arch Linux only]${NC} Run a full system upgrade"
    echo -e "      (pacman -Syu). Arch may not support partial upgrades, so this is"
    echo -e "      required to keep the system consistent. ALL installed packages"
    echo -e "      will be upgraded to their latest versions."
    echo -e "   3. ${BOLD}${YELLOW}[RHEL / AlmaLinux / Rocky only]${NC} Permanently enable the EPEL"
    echo -e "      and CRB (CodeReady Builder) package repositories. These"
    echo -e "      remain enabled after the installer finishes."
    echo -e "   4. ${BOLD}${YELLOW}[optional --gcc-14 flag only]${NC} Build GCC ${GCC_VERSION} from source"
    echo -e "      and install it to ${GCC_PREFIX}. This installation"
    echo -e "      persists after the script finishes and has no automatic"
    echo -e "      uninstall. To remove it manually: rm -rf ${GCC_PREFIX}"
    echo ""
    echo -e "  ${BOLD}Changes to your home directory (no sudo):${NC}"
    echo -e "   5. Clone Spack from GitHub and install SeisSol, all its"
    echo -e "      dependencies and configuration files under ${BOLD}${SPACK_DIR}${NC}"
    echo -e "      and in the hidden folder ${BOLD}~/.spack${NC}."
    echo -e "      Everything under these folders are self-contained and can"
    echo -e "      be removed at any time with: rm -rf ${SPACK_DIR} ~/.spack"
    if [[ "${FETCH_ONLY}" == "true" ]]; then
        echo -e "      ${BOLD}${YELLOW}[--fetch-only]${NC} Nothing is built: all sources are"
        echo -e "      downloaded to ${BOLD}${MIRROR_DIR}${NC}."
    fi
    if [[ "${OFFLINE}" == "true" ]]; then
        echo -e "      ${BOLD}${YELLOW}[--offline]${NC} Nothing is downloaded (phase 2): SeisSol is built from"
        echo -e "      the sources and lockfile prepared by --fetch-only in phase 1."
    fi
    if [[ "${SHELL_RC_UPDATE}" == "true" ]]; then
        echo -e "   6. Append a Spack activation line to ${BOLD}~/.bashrc${NC} or ${BOLD}~/.zshrc${NC}"
        echo -e "      so that Spack is available in new shells after installation."
        echo -e "   7. ${BOLD}${YELLOW}[optional --gcc-14 flag only]${NC} Append a PATH and"
        echo -e "      LD_LIBRARY_PATH line for ${GCC_PREFIX} to ${BOLD}~/.bashrc${NC} or"
        echo -e "      ${BOLD}~/.zshrc${NC} so future shells can find the compiled GCC."
    else
        echo -e "   6. ${BOLD}${YELLOW}[skipped: --no-shell-rc]${NC} ~/.bashrc and ~/.zshrc will"
        echo -e "      not be modified."
    fi
    echo ""
    echo -e "  ${BOLD}Notes:${NC}"
    echo -e "   - The installation is mostly unattended once confirmed."
    echo -e "     Few prompts may appear on some systems."
    echo -e "   - A full log of every action is written to:"
    echo -e "     ${BOLD}${LOG_FILE}${NC}"
    echo -e "   - To skip the confirmation prompt in future runs: pass ${BOLD}-y${NC} or ${BOLD}--yes${NC}."
    echo ""
    echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "${AUTO_YES}" == "true" ]]; then
        log_info "Auto-confirmed via --yes flag."
        return 0
    fi

    if [[ ! -t 0 ]]; then
        die "No interactive terminal detected and --yes was not passed. Re-run with -y / --yes to confirm non-interactively."
    fi

    local reply
    while true; do
        read -r -p "  Do you want to continue? [yes/no]: " reply
        case "${reply,,}" in
            yes|y)
                echo ""
                log_info "User confirmed. Starting installation."
                echo ""
                break
                ;;
            no|n)
                echo ""
                echo "  Installation cancelled."
                exit 0
                ;;
            *)
                echo "  Please type 'yes' or 'no'."
                ;;
        esac
    done
}

# ===========================================================================
# OS DETECTION
# ===========================================================================
OS_ID=""
OS_VERSION=""
OS_FAMILY=""

detect_os() {
    log_step "Detecting operating system"

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-0}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        die "macOS detected. This script targets Linux. Aborted."
    else
        OS_ID="unknown"
        OS_VERSION="0"
        log_warn "Cannot detect OS: /etc/os-release not found."
    fi

    log_info "OS: ${OS_ID} ${OS_VERSION}"

    case "${OS_ID}" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali)
            OS_FAMILY="debian" ;;
        rhel|centos|almalinux|rocky|ol)
            OS_FAMILY="rhel" ;;
        fedora)
            OS_FAMILY="fedora" ;;
        opensuse*|sles)
            OS_FAMILY="suse" ;;
        arch|manjaro|endeavouros|garuda)
            OS_FAMILY="arch" ;;
        *)
            if [[ "${INSTALL_DEPS}" == "true" ]]; then
                die "Unknown distro '${OS_ID}': cannot install packages with --install-deps. Aborted!"
            fi
            log_warn "Unknown distro '${OS_ID}'. Distro ID only needed for --install-deps. Continuing..."
            OS_FAMILY="unknown" ;;
    esac
}

# ===========================================================================
# GCC HELPER METADATA
# ===========================================================================
resolve_gcc_helper_metadata() {
    GCC_HELPER="$(dirname "${BASH_SOURCE[0]}")/utils/install_gcc14_fortran.sh"
    if [[ ! -f "${GCC_HELPER}" ]]; then
        die "GCC helper not found at ${GCC_HELPER}. Re-clone the repository."
    fi
    GCC_VERSION=$(awk -F'"' '/^GCC_VERSION=/{print $2; exit}' "${GCC_HELPER}")
    if [[ -z "${GCC_VERSION}" ]]; then
        die "Could not parse GCC_VERSION from ${GCC_HELPER}"
    fi
    GCC_MAJOR="${GCC_VERSION%%.*}"
    GCC_PREFIX="/usr/local/gcc-${GCC_VERSION}"
    log_info "GCC helper version: ${GCC_VERSION} (major: ${GCC_MAJOR}, prefix: ${GCC_PREFIX})"
}

# ===========================================================================
# SYSTEM PACKAGE INSTALLATION
# ===========================================================================
# Dependencies required to get Spack to run
# ===========================================================================

DEBIAN_PKGS=(
    file bzip2 ca-certificates
    g++ gcc gfortran
    git gzip lsb-release patch diffutils
    python3 python3-dev
    tar unzip xz-utils zstd
    wget curl patchelf zlib1g-dev
)

RHEL_PKGS=(
    file bzip2 ca-certificates
    gcc gcc-c++ gcc-gfortran
    git gzip patch diffutils which
    python3 python3-devel
    tar unzip xz zstd
    wget curl patchelf zlib-static
)

SUSE_PKGS=(
    file bzip2 ca-certificates
    gcc gcc-c++ gcc-fortran
    git gzip lsb-release patch diffutils
    python3 python3-devel
    tar unzip xz zstd wget curl which
    patchelf zlib-devel-static zlib-devel
)

ARCH_PKGS=(
    base-devel gcc-fortran
    git bzip2 lsb-release diffutils
    python which
    tar unzip xz zstd
    wget curl patchelf zlib
)

# Minimal RHEL-family images ship curl-minimal, which conflicts with the curl package.
# Skip curl if curl-minimal exists.
rhel_packages() {
    local pkg
    for pkg in "${RHEL_PKGS[@]}"; do
        if [[ "${pkg}" == "curl" ]] && command -v curl &>/dev/null; then continue; fi
        echo "${pkg}"
    done
}

install_packages() {
    if [[ "${INSTALL_DEPS}" == "false" ]]; then
        log_warn "Assuming dependencies are met... continuing with Spack install."
        log_warn "(Re-run with --install-deps to install the system dependencies for"
        log_warn " Spack via your OS package manager if a later step fails)."
        return 0
    fi

    log_section "Installing system dependencies"

    if ! command -v sudo &>/dev/null; then
        log_warn "'sudo' not found - attempting package install as root."
        SUDO=""
    else
        SUDO="sudo"
    fi

    case "${OS_FAMILY}" in

        debian)
            log_step "Updating apt cache and installing base packages"
            ${SUDO} apt-get update -y 2>&1 | tee -a "${LOG_FILE}"
            DEBIAN_FRONTEND=noninteractive ${SUDO} apt-get install -y \
                "${DEBIAN_PKGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
            ;;

        rhel)
            if ! command -v dnf &>/dev/null; then
                die "dnf not found on RHEL-family system. Aborted!"
            fi
            local DNF_MAJOR_VER
            DNF_MAJOR_VER=$(dnf --version 2>/dev/null | head -n 1 | \
                            grep -oE '[0-9]+' | head -n 1)

            log_info "Enabling EPEL and CRB repositories (these persist after installation)"
            ${SUDO} dnf install -y epel-release 2>&1 | tee -a "${LOG_FILE}" || true
            ${SUDO} dnf config-manager --set-enabled crb 2>&1 | tee -a "${LOG_FILE}" || \
                ${SUDO} dnf config-manager --set-enabled powertools \
                    2>&1 | tee -a "${LOG_FILE}" || true

            if [[ "${DNF_MAJOR_VER}" -ge 5 ]]; then
                ${SUDO} dnf group install -y "development-tools" 2>&1 | tee -a "${LOG_FILE}"
            else
                ${SUDO} dnf groupinstall -y "Development Tools" 2>&1 | tee -a "${LOG_FILE}"
            fi
            local -a RPM_PKGS
            mapfile -t RPM_PKGS < <(rhel_packages)
            ${SUDO} dnf install -y "${RPM_PKGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
            ;;

        fedora)
            if ! command -v dnf &>/dev/null; then
                die "dnf not found on Fedora system. Aborted!"
            fi
            local DNF_MAJOR_VER
            DNF_MAJOR_VER=$(dnf --version 2>/dev/null | head -n 1 | \
                            grep -oE '[0-9]+' | head -n 1)

            if [[ "${DNF_MAJOR_VER}" -ge 5 ]]; then
                ${SUDO} dnf group install -y "development-tools" 2>&1 | tee -a "${LOG_FILE}"
            else
                ${SUDO} dnf groupinstall -y "Development Tools" 2>&1 | tee -a "${LOG_FILE}"
            fi
            local -a RPM_PKGS
            mapfile -t RPM_PKGS < <(rhel_packages)
            ${SUDO} dnf install -y "${RPM_PKGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
            ;;

        suse)
            ${SUDO} zypper refresh 2>&1 | tee -a "${LOG_FILE}"
            ${SUDO} zypper install -y "${SUSE_PKGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
            ;;

        arch)
             ${SUDO} pacman -Syu --noconfirm --needed "${ARCH_PKGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
            ;;
    esac

    log_ok "System packages installed."
}

# ===========================================================================
# SPACK SETUP
# ===========================================================================
setup_spack() {
    log_section "Setting up Spack"

    # Clone or update Spack
    if [[ -d "${SPACK_DIR}/.git" && "${SPACK_UPDATE}" == "false" ]]; then
        log_info "Spack already present at ${SPACK_DIR}. Using it as is (--no-spack-update)."
    elif [[ -d "${SPACK_DIR}/.git" ]]; then
        log_info "Spack already present at ${SPACK_DIR}. Pulling latest changes."
        git -C "${SPACK_DIR}" fetch origin "${SPACK_BRANCH}" \
            2>&1 | tee -a "${LOG_FILE}"
        git -C "${SPACK_DIR}" checkout "${SPACK_BRANCH}" \
            2>&1 | tee -a "${LOG_FILE}"
        git -C "${SPACK_DIR}" pull --ff-only \
            2>&1 | tee -a "${LOG_FILE}"
    else
        [[ "${OFFLINE}" == "false" ]] || \
            die "No Spack clone at ${SPACK_DIR}. Run phase 1 (--fetch-only) with the same --spack-dir first."
        log_step "Cloning Spack (branch: ${SPACK_BRANCH})"
        git clone --branch "${SPACK_BRANCH}" \
            https://github.com/spack/spack.git "${SPACK_DIR}" \
            2>&1 | tee -a "${LOG_FILE}"
    fi

    # Build staging directory.
    if [[ -n "${BUILD_TMPDIR}" ]]; then
        mkdir -p "${BUILD_TMPDIR}"
        export TMPDIR="${BUILD_TMPDIR}"
        log_info "Build staging dir (TMPDIR): ${BUILD_TMPDIR}"
    else
        log_info "Build staging dir (TMPDIR): system default (${TMPDIR:-/tmp})."
    fi

    [[ -f "${SPACK_DIR}/share/spack/setup-env.sh" ]] || \
        die "Spack setup script not found at ${SPACK_DIR}/share/spack/setup-env.sh"

    log_step "Activating Spack"
    # shellcheck source=/dev/null
    source "${SPACK_DIR}/share/spack/setup-env.sh"

    # Persist activation for future interactive shells
    local SPACK_INIT_LINE=". ${SPACK_DIR}/share/spack/setup-env.sh"
    local SHELL_RC=""
    if [[ "${SHELL_RC_UPDATE}" == "false" ]]; then
        log_info "Not modifying ~/.bashrc or ~/.zshrc (--no-shell-rc)."
    elif [[ -f "${HOME}/.bashrc" ]]; then SHELL_RC="${HOME}/.bashrc"
    elif [[ -f "${HOME}/.zshrc"  ]]; then SHELL_RC="${HOME}/.zshrc"
    fi
    if [[ -n "${SHELL_RC}" ]] && ! grep -qF "${SPACK_INIT_LINE}" "${SHELL_RC}"; then
        log_info "Adding Spack init to ${SHELL_RC}"
        { echo ""; echo "# Spack - added by install_seissol.sh"; \
          echo "${SPACK_INIT_LINE}"; } >> "${SHELL_RC}"
    fi

    if [[ "${OFFLINE}" == "true" ]]; then
        log_info "Skipping compiler detection (--offline): the compiler is recorded in the lockfile."
        log_ok "Spack is ready."
        return 0
    fi

    # Compiler detection
    log_step "Detecting compilers"

    if [[ "${BUILD_GCC}" == "true" ]]; then
        export PATH="${GCC_PREFIX}/bin:${PATH}"
        export LD_LIBRARY_PATH="${GCC_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
        if [[ ! -f "${GCC_HELPER}" || ! -x "${GCC_HELPER}" ]]; then
            die "${GCC_HELPER} not found or not executable - check utils/"
        fi
        if ! command -v "gcc-${GCC_MAJOR}" &>/dev/null; then
            log_info "Compiling gcc-${GCC_MAJOR} from source"
            "${GCC_HELPER}" 2>&1 | tee -a "${LOG_FILE}"
        else
            log_info "gcc-${GCC_MAJOR} already compiled. Skipped."
        fi

        # Persist GCC PATH for future interactive shells
        if [[ -n "${SHELL_RC}" ]] && ! grep -qF "${GCC_PREFIX}/bin" "${SHELL_RC}"; then
            log_info "Adding gcc-${GCC_MAJOR} to PATH in ${SHELL_RC}"
            {
                echo ""
                echo "# GCC ${GCC_VERSION} - added by install_seissol.sh"
                echo "export PATH=\"${GCC_PREFIX}/bin:\$PATH\""
                echo "export LD_LIBRARY_PATH=\"${GCC_PREFIX}/lib64:\${LD_LIBRARY_PATH:-}\""
            } >> "${SHELL_RC}"
        fi
    fi

    spack compiler find 2>&1 | tee -a "${LOG_FILE}"

    log_info "Available compilers:"
    local SPACK_COMPILERS_OUT
    SPACK_COMPILERS_OUT=$(spack compilers 2>&1 | tee -a "${LOG_FILE}")
    echo "${SPACK_COMPILERS_OUT}"

    # Select the highest GCC below 15 to avoid C23-default issues (GCC 15+).
    local MAJOR_LIMIT=15
    local LIMIT_GCC_V
    LIMIT_GCC_V=$(printf '%s\n' "${SPACK_COMPILERS_OUT}" | \
        grep -oE 'gcc@=?[0-9]+\.[0-9]+\.[0-9]+' | \
        sed 's/@=/@/' | \
        awk -F'@' -v limit="${MAJOR_LIMIT}" \
            '{split($2,v,"."); if(v[1]+0 < limit+0) print $0}' | \
        sort -V | tail -n 1)
    LIMIT_GCC_V="${LIMIT_GCC_V//[[:space:]]/}"

    if [[ -z "${LIMIT_GCC_V}" ]]; then
        log_warn "No GCC < 15 found on this system."
        log_warn "GCC 15+ defaults to C23 (-std=gnu23), which may break"
        log_warn "some packages in SeisSol's dependency tree (e.g., netcdf, libxsmm)."
        log_warn "Consider re-running with --gcc-14 to build GCC 14 from source."
        echo ""

        if [[ "${AUTO_YES}" == "true" ]]; then
            log_warn "Auto-confirmed via --yes flag. Continuing with no compiler pin."
        elif [[ ! -t 0 ]]; then
            die "No GCC < 15 found and no interactive terminal to prompt. Re-run with --gcc-14 or pass -y / --yes to continue anyway."
        else
            local reply
            while true; do
                read -r -p "  Continue without a GCC version pin? [yes/no]: " reply
                case "${reply,,}" in
                    yes|y)
                        echo ""
                        log_warn "Continuing. Build failures are possible."
                        echo ""
                        break
                        ;;
                    no|n)
                        echo ""
                        echo "  Installation stopped. Re-run with --gcc-14 to resolve this."
                        exit 0
                        ;;
                    *)
                        echo "  Please type 'yes' or 'no'."
                        ;;
                esac
            done
        fi

        GCC_V=""
    else
        log_info "Pinning ${LIMIT_GCC_V} to SeisSol build."
        GCC_V="%${LIMIT_GCC_V}"
    fi

    log_ok "Spack is ready."
}

# ===========================================================================
# PARSE SEISSOL PARAMS FILE
# ===========================================================================
parse_seissol_config() {
    local config_file="${SEISSOL_PARAMS_FILE}"

    [[ -f "${config_file}" ]] || die "Params file not found: ${config_file}"
    [[ -r "${config_file}" ]] || die "Params file not readable: ${config_file}"

    log_step "Reading SeisSol build parameters from: ${config_file}"

    local pkg_version="master"
    SEISSOL_SPEC="seissol"

    local line_num=0
    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        (( line_num++ )) || true

        local line
        line="${raw_line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue

        if [[ "${line}" != *=* ]]; then
            log_warn "  [line ${line_num}] Ignored (no '=' found): ${raw_line}"
            continue
        fi

        local key raw_val
        key="${line%%=*}"
        raw_val="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}";   key="${key%"${key##*[![:space:]]}"}"
        raw_val="${raw_val#"${raw_val%%[![:space:]]*}"}"; raw_val="${raw_val%"${raw_val##*[![:space:]]}"}"

        [[ -z "${key}" ]] && { log_warn "  [line ${line_num}] Empty key - skipped."; continue; }

        log_info "  param: ${key} = ${raw_val}"

        local lower_val
        lower_val=$(printf '%s' "${raw_val}" | tr '[:upper:]' '[:lower:]')

        case "${key}" in
            version) pkg_version="${raw_val}" ;;
            equations)
                SEISSOL_SPEC+=" equations=${raw_val}"
                if [[ "${lower_val}" == "poroelastic" ]]; then
                    SEISSOL_POROELASTIC=true
                fi
                ;;
            *)
                case "${lower_val}" in
                    true|yes|on)   SEISSOL_SPEC+=" +${key}" ;;
                    false|no|off)  SEISSOL_SPEC+=" ~${key}" ;;
                    *)             SEISSOL_SPEC+=" ${key}=${raw_val}" ;;
                esac
                ;;
        esac
    done < "${config_file}"

    SEISSOL_SPEC="seissol@${pkg_version}${SEISSOL_SPEC#seissol} ${GCC_V}"

    if [[ -n "${SPEC_EXTRA}" ]]; then
        SEISSOL_SPEC+=" ${SPEC_EXTRA}"
        log_info "  Appended extra spec constraints (--spec-extra): ${SPEC_EXTRA}"
    fi

    log_ok "Spec assembled: ${SEISSOL_SPEC}"
}

# ===========================================================================
# POROELASTIC LAPACK WORKAROUND
# ===========================================================================
# Maybe upstream issue?
# The SeisSol Spack recipe cites special-cases for poroelastic equations for
# Fortran (depends_on fortran ...  when="equations=poroelastic") but omits a
# matching LAPACK dependency. As a result, a poroelastic build fails at CMake
# with "Could NOT find BLAS", unless a BLAS/LAPACK provider is a *direct*
# dependency of seissol.
#
# As a workaround, I add "depends_on("lapack", when="equations=poroelastic")" to
# the SeisSol Spack recipe. 
# ===========================================================================
ensure_poroelastic_lapack() {
    [[ "${SEISSOL_POROELASTIC}" == "true" ]] || return 0

    log_step "Poroelastic selected - ensuring the SeisSol recipe declares a LAPACK dependency"

    local pkg_dir pkg_file
    pkg_dir=$(spack location --package-dir seissol 2>/dev/null) \
        || die "Could not locate the seissol package (spack location --package-dir seissol)."
    pkg_file="${pkg_dir}/package.py"
    [[ -f "${pkg_file}" ]] || die "seissol package.py not found at ${pkg_file}"

    if grep -qE 'depends_on\("lapack"' "${pkg_file}"; then
        log_info "  Recipe already declares a LAPACK dependency - nothing to do."
        return 0
    fi

    local anchor='depends_on("fortran", type="build", when="equations=poroelastic")'
    if ! grep -qF "${anchor}" "${pkg_file}"; then
        log_warn "  Expected anchor line not found in ${pkg_file}"
        log_warn "  (the recipe layout may have changed upstream)."
        log_warn "  Add this line to the seissol package.py manually, then re-run:"
        log_warn '      depends_on("lapack", when="equations=poroelastic")'
        die "Aborting to avoid a poroelastic build that would fail at 'find BLAS'."
    fi

    cp -p "${pkg_file}" "${pkg_file}.seissol-installer.bak"
    if ! awk '
        { print }
        /depends_on\("fortran", type="build", when="equations=poroelastic"\)/ {
            print "    depends_on(\"lapack\", when=\"equations=poroelastic\")"
        }' "${pkg_file}" > "${pkg_file}.tmp"; then
        rm -f "${pkg_file}.tmp"
        die "Failed to rewrite ${pkg_file} (original left untouched)."
    fi
    mv "${pkg_file}.tmp" "${pkg_file}"

    if grep -qE 'depends_on\("lapack", when="equations=poroelastic"\)' "${pkg_file}"; then
        log_ok "  Added: depends_on(\"lapack\", when=\"equations=poroelastic\")"
        log_info "  Backup: ${pkg_file}.seissol-installer.bak"
    else
        die "Patch verification failed for ${pkg_file} - see the .bak backup."
    fi
}

# ===========================================================================
# SEISSOL INSTALLATION
# ===========================================================================
resolve_jobs() {
    local source="--jobs"
    if [[ -z "${JOBS}" && -n "${SLURM_CPUS_PER_TASK:-}" ]]; then
        JOBS="${SLURM_CPUS_PER_TASK}"
        source="SLURM_CPUS_PER_TASK"
    elif [[ -z "${JOBS}" ]]; then
        JOBS=$(env -u OMP_NUM_THREADS -u OMP_THREAD_LIMIT nproc 2>/dev/null \
               || sysctl -n hw.ncpu 2>/dev/null || echo 4)
        JOBS=$(( JOBS > 1 ? JOBS - 1 : 1 ))
        source="nproc - 1"
    fi
    [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "Invalid job count '${JOBS}' (from ${source})."
    log_info "Using ${JOBS} parallel jobs (from ${source})."
}

check_env_options() {
    if [[ -n "${TARGET}" ]]; then
        spack arch --known-targets 2>/dev/null | awk '/^ / { print $1 }' | grep -x -- "${TARGET}" >/dev/null || \
            die "--target: '${TARGET}' is not a target known to Spack (see: spack arch --known-targets)."
    fi

    [[ -n "${PACKAGES_YAML}" ]] || return 0
    # Avoiding spack failing if the packages file is not readable.
    local scope_dir
    scope_dir=$(mktemp -d)
    cp "${PACKAGES_YAML}" "${scope_dir}/packages.yaml"
    if ! spack -C "${scope_dir}" config get packages >/dev/null 2>>"${LOG_FILE}"; then
        rm -rf "${scope_dir}"
        die "Spack could not read your packages file: ${PACKAGES_YAML}. Check ${LOG_FILE} for errors."
    fi
    rm -rf "${scope_dir}"
}

configure_env() {
    [[ -n "${PACKAGES_YAML}" || -n "${TARGET}" ]] || return 0
    log_step "Configuring Spack environment '${SPACK_ENV_NAME}'"

    if [[ -n "${PACKAGES_YAML}" ]]; then
        local env_dir
        env_dir=$(spack location -e "${SPACK_ENV_NAME}")
        cp "${PACKAGES_YAML}" "${env_dir}/site-packages.yaml"
        spack --env="${SPACK_ENV_NAME}" config add "include:[site-packages.yaml]" \
            2>&1 | tee -a "${LOG_FILE}"
        log_info "  Included ${PACKAGES_YAML} (copied to ${env_dir}/site-packages.yaml)"
    fi

    if [[ -n "${TARGET}" ]]; then
        # Without host_compatible:false Spack rejects targets the build host cannot run.
        spack --env="${SPACK_ENV_NAME}" config add "packages:all:require:'target=${TARGET}'" \
            2>&1 | tee -a "${LOG_FILE}"
        spack --env="${SPACK_ENV_NAME}" config add "concretizer:targets:host_compatible:false" \
            2>&1 | tee -a "${LOG_FILE}"
        log_info "  All packages will be built for target=${TARGET}"
    fi
}

recreate_env() {
    log_step "Creating Spack environment '${SPACK_ENV_NAME}'"
    if spack env list 2>/dev/null | grep -qE "^[*[:space:]]*${SPACK_ENV_NAME}$"; then
        log_info "  Removing '${SPACK_ENV_NAME}', if it fails, deactivate it first:"
        log_info "  spack env deactivate"
        spack env remove --yes-to-all "${SPACK_ENV_NAME}" 2>&1 | tee -a "${LOG_FILE}"
    fi
    spack env create "${SPACK_ENV_NAME}" 2>&1 | tee -a "${LOG_FILE}"

    spack env activate "${SPACK_ENV_NAME}" 2>&1
}

install_seissol() {
    log_section "Installing SeisSol via Spack"

    check_env_options

    recreate_env

    configure_env

    parse_seissol_config

    ensure_poroelastic_lapack

    log_step "Installing SeisSol (this will take a while - follow ${LOG_FILE} for progress)"
    spack add "${SEISSOL_SPEC}" 2>&1 | tee -a "${LOG_FILE}"

    spack install \
        --jobs "${JOBS}" \
        --fail-fast \
        --yes-to-all \
        2>&1 | tee -a "${LOG_FILE}" \
        || die "Spack install failed. See the errors above and ${LOG_FILE}"
}

# ===========================================================================
# OFFLINE PHASE 1: FETCH SOURCES
# ===========================================================================
prepare_offline_assets() {
    log_step "Preparing Spack for offline use"
    spack bootstrap now 2>&1 | tee -a "${LOG_FILE}"
    BUILTIN_REPO_DIR=$(spack location --repo builtin 2>>"${LOG_FILE}") || \
        die "Could not locate Spack's builtin package repository - see ${LOG_FILE}"
    log_info "  Concretizer bootstrap: $(spack bootstrap root)"
    log_info "  Builtin package repository: ${BUILTIN_REPO_DIR}"
}

env_marker() {
    echo "$(spack location -e "${SPACK_ENV_NAME}")/${FETCH_MARKER}"
}

marker_value() {
    sed -n "s/^$1=//p" "$(env_marker)" 2>/dev/null | head -n 1
}

packages_yaml_sum() {
    if [[ -n "${PACKAGES_YAML}" ]]; then
        sha256sum "${PACKAGES_YAML}" | awk '{ print $1 }'
    else
        echo "none"
    fi
}

write_marker() {
    local marker
    marker=$(env_marker)
    {
        echo "status=$1"
        echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "spack_version=$(spack --version)"
        echo "spec=${SEISSOL_SPEC}"
        echo "gcc_pin=${GCC_V}"
        echo "target=${TARGET}"
        echo "packages_yaml_sha256=$(packages_yaml_sum)"
        echo "mirror_dir=${MIRROR_DIR}"
        echo "builtin_repo=${BUILTIN_REPO_DIR}"
    } > "${marker}.tmp"
    mv "${marker}.tmp" "${marker}"
}

can_reuse_env() {
    spack env list 2>/dev/null | grep -qE "^[*[:space:]]*${SPACK_ENV_NAME}$" || return 1
    [[ -f "$(spack location -e "${SPACK_ENV_NAME}")/spack.lock" && -f "$(env_marker)" ]] || return 1
    [[ "$(marker_value spec)" == "${SEISSOL_SPEC}" \
       && "$(marker_value target)" == "${TARGET}" \
       && "$(marker_value packages_yaml_sha256)" == "$(packages_yaml_sum)" \
       && "$(marker_value spack_version)" == "$(spack --version)" ]]
}

check_cacheable() {
    log_step "Checking that every source can be stored in the mirror"
    local script bad
    script=$(mktemp --suffix=.py)
    cat > "${script}" <<'EOF'
import spack.environment as ev
import spack.fetch_strategy as fs

for spec in ev.active_environment().all_specs():
    if spec.external or not spec.package.has_code:
        continue
    if not fs.for_package_version(spec.package).cachable:
        print(spec.format("{name}@{version}"))
EOF
    if ! bad=$(spack --env="${SPACK_ENV_NAME}" python "${script}" 2>>"${LOG_FILE}"); then
        rm -f "${script}"
        die "Could not check the concretized specs - see ${LOG_FILE}"
    fi
    rm -f "${script}"

    if [[ -n "${bad}" ]]; then
        log_error "These versions cannot be stored in a mirror (no fixed commit or checksum):"
        local line
        while IFS= read -r line; do log_error "  ${line}"; done <<< "${bad}"
        if grep -q '^seissol@' <<< "${bad}"; then
            log_error "Pin SeisSol to a commit in the params file, e.g.:"
            log_error "  version = git.<40-char-sha>=master"
        fi
        die "These packages cannot be installed offline."
    fi
    log_ok "  All sources can be mirrored."
}

add_env_mirror() {
    if spack --env="${SPACK_ENV_NAME}" mirror list 2>/dev/null | awk '{ print $1 }' \
            | grep -x -- "${MIRROR_NAME}" >/dev/null; then
        spack --env="${SPACK_ENV_NAME}" mirror remove "${MIRROR_NAME}" 2>&1 | tee -a "${LOG_FILE}"
    fi
    spack --env="${SPACK_ENV_NAME}" mirror add --type source "${MIRROR_NAME}" "file://${MIRROR_DIR}" \
        2>&1 | tee -a "${LOG_FILE}"
    log_info "  Environment uses mirror '${MIRROR_NAME}': file://${MIRROR_DIR}"
}

create_mirror() {
    log_step "Downloading all sources into ${MIRROR_DIR}"
    local workers=$(( JOBS < 8 ? JOBS : 8 ))
    local out rc=0 failed
    out=$(mktemp)
    spack --env="${SPACK_ENV_NAME}" mirror create -d "${MIRROR_DIR}" --all --private -j "${workers}" \
        2>&1 | tee -a "${LOG_FILE}" "${out}" || rc=$?
    failed=$(awk '/^ *[0-9]+ +failed to fetch/ { print $1 }' "${out}")

    if [[ ${rc} -ne 0 || "${failed:-unknown}" != "0" ]]; then
        log_error "Mirror creation failed (exit code ${rc}, failed downloads: ${failed:-unknown}):"
        local line
        while IFS= read -r line; do log_error "  ${line}"; done \
            < <(awk 'found && NF == 1 { print $1 } /^ *[0-9]+ +failed to fetch/ { found = 1 }' "${out}")
        rm -f "${out}"
        die "Re-run the same command to retry. Sources already downloaded are kept."
    fi
    log_ok "  Mirror complete: $(awk '/^ *[0-9]+ +already present/ { p = $1 } /^ *[0-9]+ +added/ { a = $1 }
        END { print p " already present, " a " added" }' "${out}")"
    rm -f "${out}"
}

fetch_sources() {
    log_section "Fetching SeisSol sources for an offline install"

    check_env_options
    mkdir -p "${MIRROR_DIR}"
    MIRROR_DIR=$(realpath "${MIRROR_DIR}")
    prepare_offline_assets
    parse_seissol_config

    if can_reuse_env; then
        log_info "Reusing the concretized environment '${SPACK_ENV_NAME}'"
        log_info "(same spec, target, packages.yaml and Spack version as the previous run)."
        spack env activate "${SPACK_ENV_NAME}" 2>&1
        write_marker concretized
        ensure_poroelastic_lapack
    else
        recreate_env
        configure_env
        ensure_poroelastic_lapack
        spack add "${SEISSOL_SPEC}" 2>&1 | tee -a "${LOG_FILE}"
        log_step "Concretizing the environment"
        spack concretize 2>&1 | tee -a "${LOG_FILE}"
        write_marker concretized
    fi

    check_cacheable
    add_env_mirror
    create_mirror
    write_marker fetched
}

# ===========================================================================
# OFFLINE PHASE 2: BUILD FROM THE MIRROR
# ===========================================================================
check_offline_env() {
    log_step "Checking the environment prepared in phase 1"
    local rerun="Run phase 1 (--fetch-only) on a machine with internet access first."

    spack env list 2>/dev/null | grep -qE "^[*[:space:]]*${SPACK_ENV_NAME}$" || \
        die "Spack environment '${SPACK_ENV_NAME}' not found in ${SPACK_DIR}. ${rerun}"
    local env_dir
    env_dir=$(spack location -e "${SPACK_ENV_NAME}")
    [[ -f "${env_dir}/spack.lock" ]] || die "No spack.lock in ${env_dir}. ${rerun}"
    [[ -f "${env_dir}/${FETCH_MARKER}" ]] || \
        die "Environment '${SPACK_ENV_NAME}' was not prepared by --fetch-only. ${rerun}"
    local status
    status=$(marker_value status)
    [[ "${status}" == "fetched" ]] || \
        die "Phase 1 did not finish downloading (status: ${status:-unknown}). Re-run --fetch-only."
    [[ "$(marker_value spack_version)" == "$(spack --version)" ]] || \
        die "Spack changed since phase 1 (version: $(marker_value spack_version)). Re-run --fetch-only."

    local mirror
    mirror=$(marker_value mirror_dir)
    if [[ -n "${MIRROR_DIR}" && "$(realpath -m "${MIRROR_DIR}")" != "${mirror}" ]]; then
        die "--mirror-dir ${MIRROR_DIR} is not the mirror used in phase 1 (${mirror})."
    fi
    [[ -d "${mirror}/_source-cache" ]] || die "Source mirror not found at ${mirror}."
    MIRROR_DIR="${mirror}"

    # Without its package repository, Spack tries to clone it again from GitHub.
    local repo cache
    repo=$(marker_value builtin_repo)
    cache=$(realpath -m "${SPACK_USER_CACHE_PATH:-${HOME}/.spack}")
    if [[ ! -d "${repo}" || "$(realpath -m "${repo}")" != "${cache}"/* ]]; then
        die "Spack's package repository from phase 1 (${repo:-unknown}) is not in ${cache}. Use the same SPACK_USER_CACHE_PATH as in phase 1."
    fi
    log_ok "  Environment, lockfile, mirror and package repository found."
}

check_offline_spec() {
    local recorded
    recorded=$(marker_value spec)
    [[ "${recorded,,}" != *equations=poroelastic* ]] || SEISSOL_POROELASTIC=true

    if [[ "${PARAMS_FILE_SET}" == "false" ]]; then
        log_info "Building the spec prepared in phase 1: ${recorded}"
        return 0
    fi
    GCC_V=$(marker_value gcc_pin)
    parse_seissol_config
    if [[ "${SEISSOL_SPEC}" != "${recorded}" ]]; then
        log_error "The params file gives a different spec than phase 1:"
        log_error "  phase 1: ${recorded}"
        log_error "  now:     ${SEISSOL_SPEC}"
        die "Re-run phase 1 (--fetch-only) with this params file."
    fi
}

build_offline() {
    log_section "Building SeisSol offline"

    check_offline_env
    check_offline_spec
    if [[ "${SEISSOL_POROELASTIC}" == "true" ]] && ! command -v gfortran &>/dev/null; then
        die "gfortran is required for poroelastic builds but was not found."
    fi

    spack env activate "${SPACK_ENV_NAME}" 2>&1
    ensure_poroelastic_lapack

    log_step "Installing SeisSol from ${MIRROR_DIR} (this will take a while, follow ${LOG_FILE} for progress)"
    # A short timeout makes an unexpected download attempt fail quickly instead of hanging.
    spack -c config:connect_timeout:5 install \
        --jobs "${JOBS}" \
        --fail-fast \
        --yes-to-all \
        2>&1 | tee -a "${LOG_FILE}" \
        || die "Spack install failed. See the errors above and ${LOG_FILE}"
}

# ===========================================================================
# POST-INSTALL REPORT
# ===========================================================================
print_summary() {
    log_section "Installation Summary"
    log_info "Spack location  : ${SPACK_DIR}"
    log_info "Spack env       : ${SPACK_ENV_NAME}"
    log_info "Log file        : ${LOG_FILE}"
    log_info ""
    log_info "To use SeisSol:"
    log_info "  source ${SPACK_DIR}/share/spack/setup-env.sh"
    log_info "  spack env activate ${SPACK_ENV_NAME}"
    if [[ "${OFFLINE}" == "true" ]]; then
        log_info "[HPC] Use the same two lines in batch scripts, after loading any modules."
    fi
    log_ok "Done. Bye."
}

print_fetch_summary() {
    log_section "Fetch Summary"
    log_info "Spack location  : ${SPACK_DIR}"
    log_info "Spack env       : ${SPACK_ENV_NAME}"
    log_info "Source mirror   : ${MIRROR_DIR}"
    log_info "Log file        : ${LOG_FILE}"
    log_info ""
    local cmd
    cmd="$(realpath "$0") --offline -y --no-shell-rc"
    cmd+=" --spack-dir $(printf '%q' "$(realpath "${SPACK_DIR}")")"
    cmd+=" --spack-env $(printf '%q' "${SPACK_ENV_NAME}")"
    cmd+=" --mirror-dir $(printf '%q' "${MIRROR_DIR}")"
    cmd+=" --params-file $(printf '%q' "$(realpath "${SEISSOL_PARAMS_FILE}")")"
    [[ -n "${SPEC_EXTRA}" ]] && cmd+=" --spec-extra $(printf '%q' "${SPEC_EXTRA}")"
    log_info "Next step: build without internet (e.g. in a batch job) with:"
    log_info "  ${cmd}"
    log_info "On Santos Dumont, submit sites/sdumont2nd/build_seissol.sbatch instead."
    if [[ -z "${TARGET}" ]]; then
        log_warn "No --target given: packages are pinned to this machine's CPU ($(spack arch --target))."
        log_warn "Pass --target if the offline build runs on a different CPU."
    fi
    local var
    for var in SPACK_USER_CACHE_PATH SPACK_USER_CONFIG_PATH; do
        if [[ -n "${!var:-}" ]]; then
            log_info "Keep ${var}=${!var} for the offline build."
        fi
    done
    log_ok "Sources fetched."
}

# ===========================================================================
# RAM CHECK
# ===========================================================================
mem_checks() {
    log_section "RAM checks"
    local TOTAL_MEM_KB TOTAL_MEM_GB
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_GB=$(( TOTAL_MEM_KB / 1024 / 1024 ))
    log_info "Available memory: ~${TOTAL_MEM_GB} GB"
    if [[ "${TOTAL_MEM_GB}" -le 16 ]]; then
        log_warn "16 GB RAM or less detected. Large builds (e.g. cuda/GPU)"
        log_warn "may fail or become very slow. Recommended: stage builds on"
        log_warn "disk by re-running with: --build-dir ${SPACK_DIR}/tmp"
    fi
    log_ok "RAM checks complete."
}

# ---------------------------------------------------------------------------
# PREREQUISITE CHECK
# ---------------------------------------------------------------------------
params_equations() {
    [[ -r "${SEISSOL_PARAMS_FILE}" ]] || return 0
    awk -F'=' '{ sub(/#.*/, "") }
        $1 ~ /^[[:space:]]*equations[[:space:]]*$/ { v = $2; gsub(/[[:space:]]/, "", v); print tolower(v) }' \
        "${SEISSOL_PARAMS_FILE}" | tail -n 1
}

check_prerequisites() {
    log_section "Checking base prerequisites"

    local probe="${SPACK_DIR}"
    while [[ ! -e "${probe}" ]]; do probe=$(dirname "${probe}"); done
    local AVAIL_KB AVAIL_GB
    AVAIL_KB=$(df --output=avail "${probe}" 2>/dev/null | tail -1 || \
               df "${probe}" | tail -1 | awk '{print $4}')
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
    log_info "Available disk space for ${SPACK_DIR}: ~${AVAIL_GB} GB"
    if [[ "${AVAIL_GB}" -lt 30 ]]; then
        log_warn "Less than 30 GB free. Spack + SeisSol may need more."
    fi

    local required=(git gcc g++ patch diff tar gzip bzip2 xz unzip python3 file)
    [[ "${OFFLINE}" == "true" ]] || required+=(curl)
    if [[ "$(params_equations)" == "poroelastic" && "${BUILD_GCC}" == "false" ]]; then
        required+=(gfortran)
    fi

    local missing=() cmd
    for cmd in "${required[@]}"; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "${INSTALL_DEPS}" == "true" ]]; then
            log_info "Missing commands: ${missing[*]}. Attempting to install via package manager."
        else
            log_error "Missing required commands: ${missing[*]}"
            log_error "Re-run with --install-deps to install them (sudo option)"
            log_error "or ask your system administrators."
            die "Prerequisite check failed."
        fi
    fi
    log_ok "Prerequisites OK."
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "====== SeisSol install log - $(date) ======" > "${LOG_FILE}"

    log_section "SeisSol Spack Installer"
    log_info "Log: ${LOG_FILE}"

    validate_args
    resolve_jobs
    resolve_gcc_helper_metadata
    confirm_with_user
    detect_os
    check_prerequisites
    mem_checks
    install_packages
    setup_spack
    if [[ "${FETCH_ONLY}" == "true" ]]; then
        fetch_sources
        print_fetch_summary
    elif [[ "${OFFLINE}" == "true" ]]; then
        build_offline
        print_summary
    else
        install_seissol
        print_summary
    fi
}

main "$@"
