# SeisSol on Santos Dumont 2nd (SDumont)

This guide installs SeisSol on the
[Santos Dumont 2nd](https://github.com/lncc-sered/manual-sdumont2nd/wiki)
supercomputer (LNCC) with the installer in this repository.

SDumont's compute nodes have no internet access, and processes on the login
nodes are stopped after 30 minutes. The installation is therefore split in two
phases:

| Phase | Where | What it does |
|---|---|---|
| 1. `--fetch-only` | login node (internet) | sets up Spack, resolves all versions, downloads every source into a local mirror |
| 2. `--offline` | compute node, batch job (no internet) | builds SeisSol from that mirror |

In a local test (AlmaLinux 9 container, elastic order 5), phase 1 took about
6 minutes and phase 2 about 1 hour on 8 cores. Times on SDumont will differ.

---

## Table of Contents

- [Before You Start](#before-you-start)
- [1. Where to Put Things](#1-where-to-put-things)
- [2. Phase 1 on a Login Node](#2-phase-1-on-a-login-node)
- [3. Phase 2: the Build Job](#3-phase-2-the-build-job)
- [4. Quick Test](#4-quick-test)
- [5. Using SeisSol in Jobs](#5-using-seissol-in-jobs)
- [6. Several Configurations Side by Side](#6-several-configurations-side-by-side)

---

## Before You Start

> **Note:** `sismo_co2` in the commands below is the project's folder under `/petrobr/parceirosbr/`.

The commands also use one placeholder:

| Placeholder | Meaning |
|---|---|
| `<login>` | the folder you create for yourself inside the project folder. Typically following your login name. |

```bash
mkdir -p /petrobr/parceirosbr/sismo_co2/<login>
cd /petrobr/parceirosbr/sismo_co2/<login>
git clone https://github.com/lucioquadros/seissol-spack-installer.git
```

---

## 1. Where to Put Things

Keep the installer, Spack and the source mirror in your folder inside the
project space:

```
/petrobr/parceirosbr/sismo_co2/<login>/
├── seissol-spack-installer/   # this repository
├── spack/                     # Spack and all installed packages
└── spack-mirror/              # downloaded sources (phase 1)
```

- **Home quota:** your home directory (`$HOME`) has a 100 GB quota. Your
  `<login>` folder in the project space does not count toward it, and files
  there belong to the project group, so colleagues in the project can use the
  same build.
- **File quota:** each user may own at most 10 million files on `/petrobr`,
  home directory (`$HOME`) included.
- **`~/.spack`:** Spack keeps its package recipes and tools there (about
  200 MB). To move them out of your home, set `SPACK_USER_CACHE_PATH` in
  `~/.bashrc`. Both phases must see the **same** value.
- **Simulation output:** ideally should be within the `<login>` folder.

---

## 2. Phase 1 on a Login Node

```bash
cd /petrobr/parceirosbr/sismo_co2/<login>/seissol-spack-installer

./install_seissol.sh --fetch-only -y --no-shell-rc \
    --spack-dir /petrobr/parceirosbr/sismo_co2/<login>/spack \
    --spack-env seissol-env \
    --params-file conf_examples/elastic_params.conf \
    --packages-yaml sites/sdumont2nd/packages.yaml \
    --target zen4
```

| Option | Why |
|---|---|
| `--packages-yaml sites/sdumont2nd/packages.yaml` | uses the system OpenMPI (module `openmpi/gnu/5.0.5.1.0`) instead of building MPI |
| `--target zen4` | builds for the AMD Zen 4 CPUs of the `cpu_amd` nodes |
| `--no-shell-rc` | Make no changes to `~/.bashrc`. |

If the login node stops the run, start the same command again with
`--no-spack-update`: it reuses what was already resolved and downloads only
what is missing.

### Parameter files

| File | Build |
|---|---|
| `conf_examples/elastic_params.conf` | SeisSol 1.3.1, elastic, order 5 |
| `conf_examples/poroelastic_params.conf` | SeisSol 1.3.1, poroelastic, order 6 |

For the [TPV6 benchmark](https://seissol.readthedocs.io/en/latest/tpv6.html)
(order 4), use a copy of `elastic_params.conf` with `convergence_order = 4`:

```bash
cp conf_examples/elastic_params.conf ../tpv6_params.conf
sed -i 's/^convergence_order .*/convergence_order      = 4/' ../tpv6_params.conf
```

and pass it with `--params-file ../tpv6_params.conf`.

---

## 3. Phase 2: the Build Job

Open `sites/sdumont2nd/build_seissol.sbatch` and edit:

- `<login>` in `BASE`,
- `SPACK_ENV`, `PARAMS_FILE` and `MIRROR_DIR`, if you changed them in phase 1.
  They must be the same as in phase 1.

Then submit it from a login node:

```bash
cd /petrobr/parceirosbr/sismo_co2/<login>
sbatch seissol-spack-installer/sites/sdumont2nd/build_seissol.sbatch
squeue -u $USER
tail -f seissol-build-<jobid>.out
```

The job runs on one `cpu_amd` node with 32 cores for up to 1.5 hours. A full build
is expected to take about 45-50 minutes; if the limit is ever reached, submit the
job again to continue.

It writes `seissol-build-<jobid>.out`, `.err` and `.log` to the folder you
submitted from.

---

## 4. Quick test

A short run of SeisSol's proxy on the development partition `cpu_amd_dev`
(20 minutes, one job at a time):

```bash
export PMIX_MCA_psec=^munge
srun -p cpu_amd_dev --account=sismo_co2 -N 1 -n 1 -c 16 -t 00:10:00 bash -lc '
    module load openmpi/gnu/5.0.5.1.0
    source /petrobr/parceirosbr/sismo_co2/<login>/spack/share/spack/setup-env.sh
    spack env activate seissol-env
    export OMP_NUM_THREADS=16
    proxy=$(compgen -c SeisSol_proxy_ | head -n 1)
    echo "Running ${proxy}"
    "${proxy}" 1000 10 all'
```

It ends with a performance summary (`GFLOPS (non-zero) for seissol proxy`, …).

---

## 5. Using SeisSol in Jobs

```bash
module load openmpi/gnu/5.0.5.1.0
source /petrobr/parceirosbr/sismo_co2/<login>/spack/share/spack/setup-env.sh
spack env activate seissol-env

compgen -c SeisSol_          # list the SeisSol binaries
```

Launch SeisSol with `srun`, after `export PMIX_MCA_psec=^munge` (see the
[SDumont manual](https://github.com/lncc-sered/manual-sdumont2nd/wiki)).

---

## 6. Several Configurations Side by Side

Give each configuration its own `--spack-env` and parameter file, and share the
Spack folder and the mirror:

```bash
./install_seissol.sh --fetch-only -y --no-shell-rc \
    --spack-dir /petrobr/parceirosbr/sismo_co2/<login>/spack \
    --spack-env seissol-poroelastic \
    --params-file conf_examples/poroelastic_params.conf \
    --packages-yaml sites/sdumont2nd/packages.yaml \
    --target zen4
```

Only sources that are not in the mirror yet are downloaded. Dependencies that are
already built are reused.

For phase 2, make a copy of the batch script per configuration with its own
`SPACK_ENV` and `PARAMS_FILE`. Run the builds one after another:

```bash
sbatch build_seissol_elastic.sbatch                           # prints the job id
sbatch --dependency=afterok:<jobid> build_seissol_poroelastic.sbatch
```
