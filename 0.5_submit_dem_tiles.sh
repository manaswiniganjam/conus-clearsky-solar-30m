#!/usr/bin/env bash
set -euo pipefail

CSV=/cluster/pixstor/stambaughm-lab/nasadem_conus/conus/02_dem_tiles/metadata/tile_windows_overlap30km_5000px.csv
N=$(( $(wc -l < "$CSV") - 1 ))

# throttle 10 at a time
sbatch --array=1-"$N"%10 /home/mgvhy/nasadem/scripts/dem_tiles.sbatch

#sbatch --array=1-640%10 dem_tiles.sbatch
#sbatch --array=1-640%10 --export=ALL,CSV_MODE=nooverlap dem_tiles.sbatch

