#!/usr/bin/env bash
# install_gcc14_fortran.sh - A script to download, build, and install GCC & GFortran 14
set -euo pipefail

GCC_VERSION="14.2.0"
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.gz"
BUILD_DIR="${HOME}/gcc-build"
INSTALL_DIR="/usr/local/gcc-${GCC_VERSION}"
CORES=$(nproc)

YELLOW='\033[1;33m'
NC='\033[0m'
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "========================================"
echo "  Building GCC & GFortran ${GCC_VERSION}"
echo "========================================"

echo "--> Installing OS build tools..."
if command -v apt-get &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y build-essential wget tar flex bison
elif command -v dnf &> /dev/null; then
    DNF_MAJOR_VER=$(dnf --version 2>/dev/null | head -n 1 | grep -o -E '[0-9]+' | head -n 1)
    if [[ "${DNF_MAJOR_VER}" -ge 5 ]]; then
        sudo dnf group install -y "development-tools"
    else
        sudo dnf groupinstall -y "Development Tools" 2>&1
    fi
    sudo dnf install -y wget tar flex bison
elif command -v zypper &> /dev/null; then
    sudo zypper install -y gcc gcc-c++ make wget tar flex bison
elif command -v pacman &> /dev/null; then
    sudo pacman -S --needed base-devel wget tar flex bison
else
    warn "Unsupported package manager. Ensure build tools are installed manually."
fi

echo "--> Downloading GCC ${GCC_VERSION}..."
cd /tmp
wget -q --show-progress -O gcc-"${GCC_VERSION}".tar.gz "${GCC_URL}"

echo "--> Extracting..."
tar -xzf gcc-"${GCC_VERSION}".tar.gz
cd gcc-"${GCC_VERSION}"

echo "--> Downloading internal prerequisites (GMP, MPFR, MPC)..."
./contrib/download_prerequisites

echo "--> Configuring GCC with Fortran support..."
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

/tmp/gcc-"${GCC_VERSION}"/configure \
    --prefix="${INSTALL_DIR}" \
    --enable-languages=c,c++,fortran \
    --disable-multilib \
    --enable-checking=release \
    --disable-libsanitizer \
    --program-suffix=-14

echo "--> Compiling GCC/GFortran using ${CORES} cores..."
make -j"${CORES}"

echo "--> Installing binaries to ${INSTALL_DIR}..."
sudo make install

echo "--> Cleaning up build files..."
rm -rf /tmp/gcc-"${GCC_VERSION}"
rm -rf /tmp/gcc-"${GCC_VERSION}".tar.gz
rm -rf "${BUILD_DIR}"

echo "========================================"
echo "GCC & GFortran ${GCC_VERSION} installed successfully!"
echo "========================================"
