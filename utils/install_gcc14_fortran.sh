#!/usr/bin/env bash
# install_gcc14_fortran.sh - A script to download, build, and install GCC & GFortran 14
set -euo pipefail

GCC_VERSION="14.2.0"
GCC_MAJOR="${GCC_VERSION%%.*}"
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.gz"
GCC_SUMS_URL="https://gcc.gnu.org/pub/gcc/releases/gcc-${GCC_VERSION}/sha512.sum"
BUILD_DIR="${HOME}/gcc-build"
INSTALL_DIR="/usr/local/gcc-${GCC_VERSION}"
CORES=$(nproc)

# Disk space required, in GB.
REQUIRED_GB=10

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

echo "========================================"
echo "  Building GCC & GFortran ${GCC_VERSION}"
echo "========================================"

echo "--- Running preinstall  checks..."

# sudo availability
if ! command -v sudo &> /dev/null; then
    if [[ "$(id -u)" -ne 0 ]]; then
        die "'sudo' not found and not running as root. Cannot install to ${INSTALL_DIR}."
    fi
    warn "'sudo' not found - running as root, will install directly."
    SUDO=""
else
    SUDO="sudo"
fi

if [[ -e "${INSTALL_DIR}" ]]; then
    if [[ -d "${INSTALL_DIR}" ]] && [[ -z "$(ls -A "${INSTALL_DIR}" 2>/dev/null || true)" ]]; then
        warn "${INSTALL_DIR} exists but is empty - reusing."
    else
        die "${INSTALL_DIR} already exists and is not empty. Remove it manually first: ${SUDO} rm -rf ${INSTALL_DIR}"
    fi
fi

# Disk space
AVAIL_KB=$(df --output=avail /tmp "${HOME}" 2>/dev/null | tail -n 1 | tr -d '[:space:]')
if [[ -z "${AVAIL_KB}" ]] || ! [[ "${AVAIL_KB}" =~ ^[0-9]+$ ]]; then
    warn "Could not determine free disk space. Build needs ~${REQUIRED_GB} GB."
else
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
    echo "    Free disk space: ~${AVAIL_GB} GB (need ~${REQUIRED_GB} GB)"
    if [[ "${AVAIL_GB}" -lt "${REQUIRED_GB}" ]]; then
        die "Insufficient free disk space (${AVAIL_GB} GB < ${REQUIRED_GB} GB required)."
    fi
fi

# ---------------------------------------------------------------------------
# OS build tools
# ---------------------------------------------------------------------------
echo "--> Installing OS build tools..."
if command -v apt-get &> /dev/null; then
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y build-essential wget tar flex bison coreutils
elif command -v dnf &> /dev/null; then
    DNF_MAJOR_VER=$(dnf --version 2>/dev/null | head -n 1 | grep -o -E '[0-9]+' | head -n 1)
    if [[ "${DNF_MAJOR_VER}" -ge 5 ]]; then
        ${SUDO} dnf group install -y "development-tools"
    else
        ${SUDO} dnf groupinstall -y "Development Tools" 2>&1
    fi
    ${SUDO} dnf install -y wget tar flex bison coreutils
elif command -v zypper &> /dev/null; then
    ${SUDO} zypper install -y gcc gcc-c++ make wget tar flex bison coreutils
elif command -v pacman &> /dev/null; then
    ${SUDO} pacman -S --needed --noconfirm base-devel wget tar flex bison coreutils
else
    warn "Unsupported package manager. Ensure build tools are installed manually."
fi

# ---------------------------------------------------------------------------
# Download & verify
# ---------------------------------------------------------------------------
echo "--> Downloading GCC ${GCC_VERSION}..."
cd /tmp
wget -q --show-progress -O "gcc-${GCC_VERSION}.tar.gz" "${GCC_URL}"

echo "--- Verifying SHA512 checksum against upstream sums file..."
wget -q -O "gcc-${GCC_VERSION}.sha512.sum" "${GCC_SUMS_URL}"
if [[ ! -s "gcc-${GCC_VERSION}.sha512.sum" ]]; then
    die "Could not fetch checksum file from ${GCC_SUMS_URL}"
fi
grep "gcc-${GCC_VERSION}.tar.gz$" "gcc-${GCC_VERSION}.sha512.sum" \
    > "gcc-${GCC_VERSION}.sha512.expected" \
    || die "No sha512 entry for gcc-${GCC_VERSION}.tar.gz in upstream sums file"
if ! sha512sum -c "gcc-${GCC_VERSION}.sha512.expected"; then
    die "SHA512 verification FAILED for gcc-${GCC_VERSION}.tar.gz. Refusing to build."
fi
echo "    Checksum OK."

echo "--- Extracting..."
tar -xzf "gcc-${GCC_VERSION}.tar.gz"
cd "gcc-${GCC_VERSION}"

echo "--> Downloading internal prerequisites (GMP, MPFR, MPC)..."
./contrib/download_prerequisites

# ---------------------------------------------------------------------------
# Configure / build / install
# ---------------------------------------------------------------------------
echo "--> Configuring GCC with Fortran support..."
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

/tmp/gcc-"${GCC_VERSION}"/configure \
    --prefix="${INSTALL_DIR}" \
    --enable-languages=c,c++,fortran \
    --disable-multilib \
    --enable-checking=release \
    --disable-libsanitizer \
    --program-suffix="-${GCC_MAJOR}"

echo "--> Compiling GCC/GFortran using ${CORES} cores..."
make -j"${CORES}"

echo "--> Installing binaries to ${INSTALL_DIR}..."
${SUDO} make install

echo "--> Cleaning up build files..."
rm -rf /tmp/gcc-"${GCC_VERSION}"
rm -rf /tmp/gcc-"${GCC_VERSION}".tar.gz
rm -rf /tmp/gcc-"${GCC_VERSION}".sha512.sum
rm -rf /tmp/gcc-"${GCC_VERSION}".sha512.expected
rm -rf "${BUILD_DIR}"

echo "========================================"
echo "GCC & GFortran ${GCC_VERSION} installed successfully!"
echo "========================================"
