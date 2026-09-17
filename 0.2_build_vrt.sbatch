#!/usr/bin/env bash
#SBATCH --job-name=nasadem_vrt
#SBATCH --output=/cluster/pixstor/stambaughm-lab/nasadem_conus/logs/02_build_vrt_%j.out
#SBATCH --error=/cluster/pixstor/stambaughm-lab/nasadem_conus/logs/02_build_vrt_%j.err
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G

set -euo pipefail

ROOT="/cluster/pixstor/stambaughm-lab/nasadem_conus"
HGT_DIR="${ROOT}/conus/00_raw_nasadem/hgt"
VRT="${ROOT}/conus/00_raw_nasadem/nasadem_conus.vrt"
LOG_DIR="${ROOT}/logs"
LOG="${LOG_DIR}/02_build_vrt_${SLURM_JOB_ID}_$(date +%Y%m%d_%H%M%S).log"
LIST="${ROOT}/conus/00_raw_nasadem/hgt_file_list_${SLURM_JOB_ID}.txt"

mkdir -p "${LOG_DIR}"

log() { echo "[$(date '+%F %T')] $*" | tee -a "${LOG}"; }

log "Starting VRT build"
log "ROOT=${ROOT}"
log "HGT_DIR=${HGT_DIR}"
log "VRT=${VRT}"

# ---- Load GDAL on compute node ----
module purge >> "${LOG}" 2>&1 || true
module load gdal/3.7.0_gcc_12.3.0 >> "${LOG}" 2>&1

if ! command -v gdalbuildvrt >/dev/null 2>&1; then
  log "ERROR: gdalbuildvrt not found even after module load."
  exit 1
fi
log "gdalbuildvrt: $(command -v gdalbuildvrt)"
log "gdal version: $(gdalinfo --version 2>/dev/null || true)"

# ---- Sanity checks ----
if [[ ! -d "${HGT_DIR}" ]]; then
  log "ERROR: HGT_DIR not found: ${HGT_DIR}"
  exit 1
fi

# Build file list (avoids shell arg length limit)
log "Building HGT file list -> ${LIST}"
find "${HGT_DIR}" -maxdepth 1 -type f -name "*.hgt" | sort > "${LIST}"
COUNT=$(wc -l < "${LIST}" || echo 0)
log "Found HGT files: ${COUNT}"

if [[ "${COUNT}" -eq 0 ]]; then
  log "ERROR: No .hgt files found in ${HGT_DIR}"
  exit 1
fi

log "Running gdalbuildvrt -input_file_list (robust for many tiles)"
gdalbuildvrt -overwrite -input_file_list "${LIST}" "${VRT}" >> "${LOG}" 2>&1

log "VRT build complete"
log "Wrote: ${VRT}"

