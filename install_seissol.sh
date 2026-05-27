#!/usr/bin/env bash
# ===========================================================================
#  install_seissol.sh - SeisSol installation via Spack
#  Targets (incl. WSL): Ubuntu/Debian, RHEL/Fedora, openSUSE/SLES (?), Arch
# ===========================================================================
# Usage: ./install_seissol.sh [OPTIONS]
#
# Options:
#  --params-file FILE   SeisSol build-parameter file
#                       (default: seissol_params.conf in the script directory)
#  -j, --jobs N         Parallel build jobs (default: nproc − 1)
#  --spack-dir DIR      Where to clone or find Spack (default: ~/spack)
#  --log FILE           Custom log file path
#                       (default: ~/seissol_install_YYYYMMDD_HHMMSS.log)
#  --gcc-14             Build gcc-14 from source / export it to PATH
#  -y, --yes            Skip the confirmation prompt 
#  -h, --help           Show usage and exit
# ===========================================================================

set -euo pipefail
IFS=$'\n\t'

# ===========================================================================
# DEFAULT CONFIGURATION
# ===========================================================================
SPACK_DIR="${HOME}/spack"
SPACK_ENV_NAME="seissol-env"
JOBS=""                     # empty = auto-detect
LOG_FILE="${HOME}/seissol_install_$(date +%Y%m%d_%H%M%S).log"
SPACK_BRANCH="develop"
SEISSOL_PARAMS_FILE="seissol_params.conf"
BUILD_GCC=false
GCC_V=""
AUTO_YES=false

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
            --params-file) SEISSOL_PARAMS_FILE="$2"; shift 2 ;;
            -j|--jobs)     JOBS="$2";                shift 2 ;;
            --spack-dir)   SPACK_DIR="$2";           shift 2 ;;
            --log)         LOG_FILE="$2";            shift 2 ;;
            --gcc-14)      BUILD_GCC=true;           shift 1 ;;
            -y|--yes)      AUTO_YES=true;            shift 1 ;;
            -h|--help)     usage; exit 0 ;;
            *) die "Unknown option: $1. Run with -h for help." ;;
        esac
    done
}

usage() {
    grep '^#' "$0" | grep -E '^\# ' | sed 's/^# //' | head -16
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
    echo -e "   1. Install Spack requirements and compiler packages via your package"
    echo -e "      manager (apt / dnf / zypper / pacman)."
    echo -e "   2. ${BOLD}${YELLOW}[Arch Linux only]${NC} Run a full system package database sync"
    echo -e "      (pacman -Sy). Package installation is targeted, but the"
    echo -e "      database sync may surface upgrades for existing packages."
    echo -e "   3. ${BOLD}${YELLOW}[RHEL / AlmaLinux / Rocky only]${NC} Permanently enable the EPEL"
    echo -e "      and CRB (CodeReady Builder) package repositories. These"
    echo -e "      remain enabled after the installer finishes."
    echo -e "   4. ${BOLD}${YELLOW}[optional --gcc-14 flag only]${NC} Build GCC 14.2.0 from source"
    echo -e "      and install it to /usr/local/gcc-14.2.0. This installation"
    echo -e "      persists after the script finishes and has no automatic"
    echo -e "      uninstall. To remove it manually: rm -rf /usr/local/gcc-14.2.0"
    echo ""
    echo -e "  ${BOLD}Changes to your home directory (no sudo):${NC}"
    echo -e "   5. Clone Spack from GitHub and install SeisSol, all its"
    echo -e "      dependencies and configuration files under ${BOLD}~/spack${NC}"
    echo -e "      and in the hidden folder ${BOLD}~/.spack${NC}."
    echo -e "      Everything under these folders are self-contained and can"
    echo -e "      be removed at any time with: rm -rf ~/spack ~/.spack"
    echo -e "   6. Append a Spack activation line to ${BOLD}~/.bashrc${NC} or ${BOLD}~/.zshrc${NC}"
    echo -e "      so that Spack is available in new shells after installation."
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
IS_WSL=false # <- not really used, maybe remove?

detect_os() {
    log_step "Detecting operating system"

    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-0}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        die "macOS detected. This script targets Linux. Aborted."
    else
        die "Cannot detect OS - /etc/os-release not found."
    fi

    if grep -qEi "(microsoft|wsl)" /proc/version 2>/dev/null; then
        IS_WSL=true
        log_info "WSL environment detected."
    fi

    log_info "OS: ${OS_ID} ${OS_VERSION}  (WSL: ${IS_WSL})"

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
    wget curl patchelf
)

RHEL_PKGS=(
    file bzip2 ca-certificates
    gcc gcc-c++ gcc-gfortran
    git gzip patch
    python3 python3-devel
    tar unzip xz zstd
    wget curl patchelf
)

SUSE_PKGS=(
    file bzip2 ca-certificates
    gcc gcc-c++ gcc-fortran
    git gzip lsb-release patch
    python3 python3-devel
    tar unzip xz zstd
    wget curl patchelf
)

ARCH_PKGS=(
    base-devel gcc-fortran
    git bzip2 lsb-release
    python
    tar unzip xz zstd
    wget curl patchelf
)

install_packages() {
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
	    ${SUDO} pacman -Sy --noconfirm 2>&1 | tee -a "${LOG_FILE}"
	    ${SUDO} pacman -S --noconfirm --needed "${ARCH_PKGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
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
        git -C "${SPACK_DIR}" fetch --depth=2 origin "${SPACK_BRANCH}" \
            2>&1 | tee -a "${LOG_FILE}"
        git -C "${SPACK_DIR}" checkout "${SPACK_BRANCH}" \
            2>&1 | tee -a "${LOG_FILE}"
        git -C "${SPACK_DIR}" pull --ff-only \
            2>&1 | tee -a "${LOG_FILE}"
    else
        log_step "Cloning Spack (branch: ${SPACK_BRANCH})"
        git clone --depth=2 --branch "${SPACK_BRANCH}" \
            https://github.com/spack/spack.git "${SPACK_DIR}" \
            2>&1 | tee -a "${LOG_FILE}"
    fi

    [[ -f "${SPACK_DIR}/share/spack/setup-env.sh" ]] || \
        die "Spack setup script not found at ${SPACK_DIR}/share/spack/setup-env.sh"

    # Activate Spack in the current shell                                 
    log_step "Activating Spack"
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
        export PATH="/usr/local/gcc-14.2.0/bin:${PATH}"
        export LD_LIBRARY_PATH="/usr/local/gcc-14.2.0/lib64:${LD_LIBRARY_PATH:-}"
        local GCC_SH
        GCC_SH="$(dirname "${BASH_SOURCE[0]}")/utils/install_gcc14_fortran.sh"
        if [[ ! -f "${GCC_SH}" || ! -x "${GCC_SH}" ]]; then
            die "${GCC_SH} not found or not executable - check utils/"
        fi
        if ! command -v "gcc-14" &>/dev/null; then
            log_info "Compiling gcc-14 from source"
            "${GCC_SH}" 2>&1 | tee -a "${LOG_FILE}"
        else
            log_info "gcc-14 already compiled. Skipped."
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
        grep -oE 'gcc@[0-9]+\.[0-9]+\.[0-9]+' | \
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
        die "No GCC < 15 found and no interactive terminal to prompt. " \
            "Re-run with --gcc-14 or pass -y / --yes to continue anyway."
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

    # netcdf-c 4.8.x is incompatible with C23
    SEISSOL_SPEC+=" ^netcdf-c@4.9:"

    # matplotlib 3.2.x is incompatible with FreeType >= 2.11
    SEISSOL_SPEC+=" ^py-matplotlib@3.5:"

    log_ok "Spec assembled: ${SEISSOL_SPEC}"
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
        spack env remove --yes-to-all "${SPACK_ENV_NAME}" 2>&1 | tee -a "${LOG_FILE}"
    fi
    spack env create "${SPACK_ENV_NAME}" 2>&1 | tee -a "${LOG_FILE}"

    spack env activate "${SPACK_ENV_NAME}" 2>&1

    parse_seissol_config

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
    log_info "To use SeisSol in a new shell:"
    log_info "  source ${SPACK_DIR}/share/spack/setup-env.sh"
    log_info "  spack env activate ${SPACK_ENV_NAME}"
    log_info ""
    log_info "To add another configuration to the same environment:"
    log_info "  spack env activate ${SPACK_ENV_NAME}"
    log_info "  spack add seissol convergence_order=6 equations=poroelastic [...]"
    log_info "  spack install"
    log_info ""
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
    if [[ "${TOTAL_MEM_GB}" -lt 8 ]]; then
        log_warn "Less than 8 GB RAM detected. Large parallel builds may fail."
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
    if [[ "${AVAIL_GB}" -lt 20 ]]; then
        log_warn "Less than 20 GB free. Spack + SeisSol may need more."
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
