#!/usr/bin/env bash
#SBATCH --job-name=merge_tile_index
#SBATCH --time=00:10:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --output=merge_tile_index_%j.log
#SBATCH --error=merge_tile_index_%j.err

set -euo pipefail

BASE=/cluster/pixstor/stambaughm-lab/nasadem_conus/conus
CSV_MODE="${CSV_MODE:-overlap}"

if [[ "$CSV_MODE" == "nooverlap" ]]; then
  OUT_DIR=$BASE/02_dem_tiles/tiles_nooverlap_5000px
  INDEX_OUT=$OUT_DIR/tile_outputs_index_nooverlap.tsv
elif [[ "$CSV_MODE" == "overlap" ]]; then
  OUT_DIR=$BASE/02_dem_tiles/tiles_overlap30km_5000px
  INDEX_OUT=$OUT_DIR/tile_outputs_index_productB.tsv
else
  echo "ERROR: CSV_MODE must be 'nooverlap' or 'overlap'"
  exit 2
fi

PARTS_DIR="$OUT_DIR/_tile_index_parts"

echo -e "tile_id\tmode\txoff\tyoff\txsize\tysize\tout_tif" > "$INDEX_OUT"
cat "$PARTS_DIR"/part_*.tsv | sort -k1,1 >> "$INDEX_OUT"

echo "Wrote index: $INDEX_OUT"
head -n 5 "$INDEX_OUT"

