#!/usr/bin/env bash
# ===========================================================================
#  install_seissol.sh - SeisSol installation via Spack
#  Targets (incl. WSL): Ubuntu/Debian, RHEL/Fedora, openSUSE/SLES, Arch
# ===========================================================================
# Usage: ./install_seissol.sh [OPTIONS]
#
# Options:
#  --params-file FILE   SeisSol build-parameter file
#                       (default: seissol_params.conf in the script directory)
#  --install-deps       Install system dependencies for Spack via the OS
#                       package manager.
#  -j, --jobs N         Parallel build jobs (default: nproc − 1)
#  --spack-dir DIR      Where to clone or find Spack (default: ~/spack)
#  --spack-env STR      Spack environment name (default: seissol-env)
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
BUILD_GCC=false
GCC_V=""
AUTO_YES=false
INSTALL_DEPS=false
SPEC_EXTRA=""               
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
            --params-file) SEISSOL_PARAMS_FILE="$2";                     shift 2 ;;
            --install-deps) INSTALL_DEPS=true;                           shift 1 ;;
            -j|--jobs)     JOBS="$2";                                    shift 2 ;;
            --spack-dir)   SPACK_DIR="$2";                               shift 2 ;;
            --spack-env)   SPACK_ENV_NAME="$2";                          shift 2 ;;
            --build-dir)   BUILD_TMPDIR="$2";                            shift 2 ;;
            --log)         LOG_FILE="$2";                                shift 2 ;;
            --gcc-14)      BUILD_GCC=true;                               shift 1 ;;
            --spec-extra)  SPEC_EXTRA="${SPEC_EXTRA:+${SPEC_EXTRA} }$2"; shift 2 ;;
            -y|--yes)      AUTO_YES=true;                                shift 1 ;;
            -h|--help)     usage; exit 0 ;;
            *) die "Unknown option: $1. Run with -h for help." ;;
        esac
    done
}

usage() {
    grep '^#' "$0" | grep -E '^# ' | sed 's/^# //' | head -23
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
    echo -e "   6. Append a Spack activation line to ${BOLD}~/.bashrc${NC} or ${BOLD}~/.zshrc${NC}"
    echo -e "      so that Spack is available in new shells after installation."
    echo -e "   7. ${BOLD}${YELLOW}[optional --gcc-14 flag only]${NC} Append a PATH and"
    echo -e "      LD_LIBRARY_PATH line for ${GCC_PREFIX} to ${BOLD}~/.bashrc${NC} or"
    echo -e "      ${BOLD}~/.zshrc${NC} so future shells can find the compiled GCC."
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
        die "Cannot detect OS - /etc/os-release not found."
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
            die "Unknown distro '${OS_ID}'. Aborted!" ;;
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
    git gzip lsb-release patch
    python3 python3-dev
    tar unzip xz-utils zstd
    wget curl patchelf zlib1g-dev
)

RHEL_PKGS=(
    file bzip2 ca-certificates
    gcc gcc-c++ gcc-gfortran
    git gzip patch which
    python3 python3-devel
    tar unzip xz zstd
    wget curl patchelf zlib-static
)

SUSE_PKGS=(
    file bzip2 ca-certificates
    gcc gcc-c++ gcc-fortran
    git gzip lsb-release patch
    python3 python3-devel
    tar unzip xz zstd wget curl which
    patchelf zlib-devel-static zlib-devel
)

ARCH_PKGS=(
    base-devel gcc-fortran
    git bzip2 lsb-release
    python which
    tar unzip xz zstd
    wget curl patchelf zlib
)

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
            ${SUDO} dnf install -y "${RHEL_PKGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
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
            ${SUDO} dnf install -y "${RHEL_PKGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
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
    if [[ -d "${SPACK_DIR}/.git" ]]; then
        log_info "Spack already present at ${SPACK_DIR}. Pulling latest changes."
        git -C "${SPACK_DIR}" fetch origin "${SPACK_BRANCH}" \
            2>&1 | tee -a "${LOG_FILE}"
        git -C "${SPACK_DIR}" checkout "${SPACK_BRANCH}" \
            2>&1 | tee -a "${LOG_FILE}"
        git -C "${SPACK_DIR}" pull --ff-only \
            2>&1 | tee -a "${LOG_FILE}"
    else
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
    if   [[ -f "${HOME}/.bashrc" ]]; then SHELL_RC="${HOME}/.bashrc"
    elif [[ -f "${HOME}/.zshrc"  ]]; then SHELL_RC="${HOME}/.zshrc"
    fi
    if [[ -n "${SHELL_RC}" ]] && ! grep -qF "${SPACK_INIT_LINE}" "${SHELL_RC}"; then
        log_info "Adding Spack init to ${SHELL_RC}"
        { echo ""; echo "# Spack - added by install_seissol.sh"; \
          echo "${SPACK_INIT_LINE}"; } >> "${SHELL_RC}"
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
install_seissol() {
    log_section "Installing SeisSol via Spack"

    if [[ -z "${JOBS}" ]]; then
        JOBS=$(nproc --all 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
        JOBS=$(( JOBS > 1 ? JOBS - 1 : JOBS ))
    fi
    log_info "Using ${JOBS} parallel jobs."

    log_step "Creating Spack environment '${SPACK_ENV_NAME}'"
    if spack env list 2>/dev/null | grep -qE "^[*[:space:]]*${SPACK_ENV_NAME}$"; then
        log_info "  Removing '${SPACK_ENV_NAME}', if it fails, deactivate it first:"
        log_info "  spack env deactivate"
        spack env remove --yes-to-all "${SPACK_ENV_NAME}" 2>&1 | tee -a "${LOG_FILE}"
    fi
    spack env create "${SPACK_ENV_NAME}" 2>&1 | tee -a "${LOG_FILE}"

    spack env activate "${SPACK_ENV_NAME}" 2>&1

    parse_seissol_config

    ensure_poroelastic_lapack

    log_step "Installing SeisSol (this will take a while - follow ${LOG_FILE} for progress)"
    spack add "${SEISSOL_SPEC}" 2>&1 | tee -a "${LOG_FILE}"

    spack install \
        --jobs "${JOBS}" \
        --fail-fast \
        --yes-to-all \
        2>&1 | tee -a "${LOG_FILE}"
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
    log_ok "Done. Bye."
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
        log_warn "disk by re-running with: --build-dir ${HOME}/spack/tmp"
    fi
    log_ok "RAM checks complete."
}

# ---------------------------------------------------------------------------
# PREREQUISITE CHECK
# ---------------------------------------------------------------------------
check_prerequisites() {
    log_section "Checking base prerequisites"
    local AVAIL_KB AVAIL_GB
    AVAIL_KB=$(df --output=avail "${HOME}" 2>/dev/null | tail -1 || \
               df "${HOME}" | tail -1 | awk '{print $4}')
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
    log_info "Available disk space in ${HOME}: ~${AVAIL_GB} GB"
    if [[ "${AVAIL_GB}" -lt 30 ]]; then
        log_warn "Less than 30 GB free. Spack + SeisSol may need more."
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

    resolve_gcc_helper_metadata
    confirm_with_user
    detect_os
    check_prerequisites
    mem_checks
    install_packages
    setup_spack
    install_seissol
    print_summary
}

main "$@"
