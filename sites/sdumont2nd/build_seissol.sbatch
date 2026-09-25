#!/bin/bash -l
#SBATCH --job-name=seissol-build
#SBATCH --partition=cpu_amd
#SBATCH --account=sismo_co2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --time=04:00:00
#SBATCH --output=seissol-build-%j.out
#SBATCH --error=seissol-build-%j.err
#
# Phase 2 of the offline SeisSol install on Santos Dumont: builds, without
# internet access. ONLY RUN AFTER phase 1 (--fetch-only) is already prepared on a
# login node. See README.md in this folder.
#
# The paths below must match phase 1.

BASE="/petrobr/parceirosbr/sismo_co2/<login>"
INSTALLER="${BASE}/seissol-spack-installer/install_seissol.sh"
SPACK_DIR="${BASE}/spack"
SPACK_ENV="seissol-env"
PARAMS_FILE="${BASE}/seissol-spack-installer/conf_examples/elastic_params.conf"
MIRROR_DIR="${SPACK_DIR}-mirror"

module load openmpi/gnu/5.0.5.1.0

set -euo pipefail

BUILD_DIR="${TMPDIR:-/tmp}/seissol-build-${SLURM_JOB_ID}"
build_args=()
if mkdir -p "${BUILD_DIR}" 2>/dev/null && [[ -w "${BUILD_DIR}" ]]; then
    build_args=(--build-dir "${BUILD_DIR}")
    cleanup() {
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            local keep="${SLURM_SUBMIT_DIR:-.}/seissol-build-${SLURM_JOB_ID}-logs"
            mkdir -p "${keep}"
            (cd "${BUILD_DIR}" && find . -name 'spack-build-*.txt' -exec cp --parents {} "${keep}/" \;) || true
            echo "Build failed. Spack build logs are in ${keep}"
        fi
        rm -rf "${BUILD_DIR}"
    }
    trap cleanup EXIT
else
    echo "Node-local ${BUILD_DIR} is not writable. Using Spack's default build directory."
fi

"${INSTALLER}" --offline -y --no-shell-rc \
    --spack-dir "${SPACK_DIR}" \
    --spack-env "${SPACK_ENV}" \
    --params-file "${PARAMS_FILE}" \
    --mirror-dir "${MIRROR_DIR}" \
    --log "${SLURM_SUBMIT_DIR:-.}/seissol-build-${SLURM_JOB_ID}.log" \
    ${build_args[@]+"${build_args[@]}"}
