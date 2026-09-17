#!/usr/bin/env bash
#SBATCH --job-name=export_tiles
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --output=export_tiles_%A_%a.log
#SBATCH --error=export_tiles_%A_%a.err

set -euo pipefail

echo "HOST=$(hostname) PWD=$(pwd)"
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-NA} SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-NA}"

module purge || true
module load gdal || true

BASE=/cluster/pixstor/stambaughm-lab/nasadem_conus/conus
A_VRT=$BASE/01_dem_domain/demA_warped_epsg5070_30m_conus30km.vrt

# Choose at submit time:
#   CSV_MODE=nooverlap  -> clean mosaic tiles
#   CSV_MODE=overlap    -> Product B preprocessing tiles
CSV_MODE="${CSV_MODE:-overlap}"

CSV_DIR=$BASE/02_dem_tiles/metadata
if [[ "$CSV_MODE" == "nooverlap" ]]; then
  CSV=$CSV_DIR/tile_windows_nooverlap_5000px.csv
  OUT_DIR=$BASE/02_dem_tiles/tiles_nooverlap_5000px
  COL_XOFF=4; COL_YOFF=5; COL_XSIZE=6; COL_YSIZE=7
elif [[ "$CSV_MODE" == "overlap" ]]; then
  CSV=$CSV_DIR/tile_windows_overlap30km_5000px.csv
  OUT_DIR=$BASE/02_dem_tiles/tiles_overlap30km_5000px
  COL_XOFF=4; COL_YOFF=5; COL_XSIZE=6; COL_YSIZE=7
else
  echo "ERROR: CSV_MODE must be 'nooverlap' or 'overlap'"
  exit 2
fi

mkdir -p "$OUT_DIR"
PARTS_DIR="$OUT_DIR/_tile_index_parts"
mkdir -p "$PARTS_DIR"

export PROJ_NETWORK=OFF
export GDAL_CACHEMAX=2048
export GDAL_NUM_THREADS=ALL_CPUS

if [[ -z "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  echo "ERROR: submit as a SLURM array job"
  exit 3
fi

LINE=$((SLURM_ARRAY_TASK_ID + 1))
ROW=$(awk -F, -v L="$LINE" 'NR==L{print $0}' "$CSV")
if [[ -z "$ROW" ]]; then
  echo "ERROR: No CSV row for task ${SLURM_ARRAY_TASK_ID} (line ${LINE})"
  exit 4
fi

tile_id=$(echo "$ROW" | awk -F, '{print $1}')
xoff=$(echo "$ROW"    | awk -F, -v C=$COL_XOFF '{print $C}')
yoff=$(echo "$ROW"    | awk -F, -v C=$COL_YOFF '{print $C}')
xsize=$(echo "$ROW"   | awk -F, -v C=$COL_XSIZE '{print $C}')
ysize=$(echo "$ROW"   | awk -F, -v C=$COL_YSIZE '{print $C}')

OUT_TIF=$OUT_DIR/dem_tile_${tile_id}.tif
PART_TSV=$PARTS_DIR/part_${tile_id}.tsv

if [[ -f "$OUT_TIF" ]]; then
  echo "Exists, skipping export: $OUT_TIF"
  # still write part index row (idempotent)
  echo -e "${tile_id}\t${CSV_MODE}\t${xoff}\t${yoff}\t${xsize}\t${ysize}\t${OUT_TIF}" > "$PART_TSV"
  exit 0
fi

# local scratch first
SCRATCH="${SLURM_TMPDIR:-/tmp}"
LOCAL_TIF="$SCRATCH/dem_tile_${CSV_MODE}_${tile_id}_${SLURM_JOB_ID}.tif"
rm -f "$LOCAL_TIF" 2>/dev/null || true

echo "[`date`] Export $CSV_MODE tile_id=$tile_id srcwin=$xoff,$yoff,$xsize,$ysize"

gdal_translate \
  -srcwin "$xoff" "$yoff" "$xsize" "$ysize" \
  -of GTiff \
  -co TILED=YES \
  -co BIGTIFF=IF_SAFER \
  -co COMPRESS=DEFLATE \
  -co PREDICTOR=2 \
  -co NUM_THREADS=ALL_CPUS \
  "$A_VRT" \
  "$LOCAL_TIF"

# atomic move
TMP_OUT="$OUT_DIR/.tmp_${tile_id}_${SLURM_JOB_ID}.tif"
rm -f "$TMP_OUT" 2>/dev/null || true
rsync -ah --inplace "$LOCAL_TIF" "$TMP_OUT"
mv -f "$TMP_OUT" "$OUT_TIF"

# write per-tile index part (race-free)
echo -e "${tile_id}\t${CSV_MODE}\t${xoff}\t${yoff}\t${xsize}\t${ysize}\t${OUT_TIF}" > "$PART_TSV"

echo "[`date`] Done: $OUT_TIF"

#sbatch --array=1-640%10 dem_tiles.sbatch
#sbatch --array=1-640%10 --export=ALL,CSV_MODE=nooverlap dem_tiles.sbatch

