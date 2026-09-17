#!/usr/bin/env bash
#SBATCH --job-name=demA_vrt_csvs
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --output=demA_vrt_csvs_%j.log
#SBATCH --error=demA_vrt_csvs_%j.err

set -euo pipefail

echo "HOST=$(hostname) PWD=$(pwd)"
echo "HOME=$HOME"
echo "PIXSTOR_OK=$(ls -d /cluster/pixstor/stambaughm-lab >/dev/null 2>&1 && echo yes || echo no)"

module purge || true
module load gdal || true

# ---- Conda for python GDAL bindings (matches your old Code 2 pattern) ----
source /cluster/pixstor/stambaughm-lab/miniconda3/etc/profile.d/conda.sh
conda activate nasadem_py310

# -------------------- Paths --------------------
BASE=/cluster/pixstor/stambaughm-lab/nasadem_conus/conus
RAW=$BASE/00_raw_nasadem
OUTA=$BASE/01_dem_domain
OUTMETA=$OUTA/metadata
OUTCSV=$BASE/02_dem_tiles/metadata
mkdir -p "$OUTMETA" "$OUTCSV"

RAW_VRT=$RAW/nasadem_conus.vrt

# CONUS + 30 km buffer polygon (already EPSG:5070)
CUTLINE=/cluster/pixstor/stambaughm-lab/nasadem_conus/shapefile_conus_30km/conus_epsg5070_30km.shp

# Outputs
A_VRT=$OUTA/demA_warped_epsg5070_30m_conus30km.vrt
A_INFO=$OUTMETA/gdalinfo_demA_warped_vrt.txt

CSV_NO=$OUTCSV/tile_windows_nooverlap_5000px.csv
CSV_OV=$OUTCSV/tile_windows_overlap30km_5000px.csv

META_NO=$OUTCSV/tile_windows_nooverlap_5000px_meta.txt
META_OV=$OUTCSV/tile_windows_overlap30km_5000px_meta.txt

# Tile definition indices (no output paths yet)
INDEX_NO=$OUTCSV/index_nooverlap_5000px.tsv
INDEX_OV=$OUTCSV/index_productB_overlap30km_5000px.tsv

# Quick summaries
SUMMARY_NO=$OUTCSV/tile_windows_nooverlap_5000px_summary.txt
SUMMARY_OV=$OUTCSV/tile_windows_overlap30km_5000px_summary.txt

# -------------------- Warp params --------------------
NODATA=-32768
export PROJ_NETWORK=OFF
export GDAL_CACHEMAX=2048
export GDAL_NUM_THREADS=ALL_CPUS

echo "[`date`] Step 0.1: Build warped/clipped VRT"
rm -f "$A_VRT" 2>/dev/null || true

gdalwarp \
  -overwrite \
  -t_srs EPSG:5070 \
  -tr 30 30 -tap \
  -r cubic \
  -cutline "$CUTLINE" -crop_to_cutline \
  -srcnodata "$NODATA" -dstnodata "$NODATA" \
  -multi -wo NUM_THREADS=ALL_CPUS \
  -of VRT \
  "$RAW_VRT" \
  "$A_VRT"

gdalinfo "$A_VRT" > "$A_INFO"

echo "[`date`] Step 0.2: Build BOTH tile CSVs + meta + tile-definition indices"
python - <<PY
import math, csv
from osgeo import gdal

A_VRT = r"$A_VRT"

CSV_NO  = r"$CSV_NO"
CSV_OV  = r"$CSV_OV"
META_NO = r"$META_NO"
META_OV = r"$META_OV"

INDEX_NO = r"$INDEX_NO"
INDEX_OV = r"$INDEX_OV"

INTERIOR_PX = 5000
BUFFER_M = 30000
RES_M = 30
OVERLAP_PX = math.ceil(BUFFER_M / RES_M)  # 1000

ds = gdal.Open(A_VRT, gdal.GA_ReadOnly)
if ds is None:
    raise RuntimeError(f"Cannot open {A_VRT}")

W, H = ds.RasterXSize, ds.RasterYSize
gt = ds.GetGeoTransform()
proj = ds.GetProjection()

ncol = math.ceil(W / INTERIOR_PX)
nrow = math.ceil(H / INTERIOR_PX)

def clamp(v, lo, hi): return max(lo, min(hi, v))

rows_no = []
rows_ov = []
tile_id = 0

for r in range(nrow):
    for c in range(ncol):
        tile_id += 1
        x0 = c * INTERIOR_PX
        y0 = r * INTERIOR_PX

        xsize_int = min(INTERIOR_PX, W - x0)
        ysize_int = min(INTERIOR_PX, H - y0)

        # no-overlap window == interior
        rows_no.append({
            "tile_id": f"{tile_id:06d}",
            "row": r, "col": c,
            "xoff": int(x0), "yoff": int(y0),
            "xsize": int(xsize_int), "ysize": int(ysize_int),
            "interior_px": int(INTERIOR_PX)
        })

        # overlap window
        x0_win = clamp(x0 - OVERLAP_PX, 0, W)
        y0_win = clamp(y0 - OVERLAP_PX, 0, H)
        x1_win = clamp(x0 + xsize_int + OVERLAP_PX, 0, W)
        y1_win = clamp(y0 + ysize_int + OVERLAP_PX, 0, H)

        rows_ov.append({
            "tile_id": f"{tile_id:06d}",
            "row": r, "col": c,

            "xoff_win": int(x0_win),
            "yoff_win": int(y0_win),
            "xsize_win": int(x1_win - x0_win),
            "ysize_win": int(y1_win - y0_win),

            "xoff_int": int(x0),
            "yoff_int": int(y0),
            "xsize_int": int(xsize_int),
            "ysize_int": int(ysize_int),

            "overlap_px": int(OVERLAP_PX),
            "interior_px": int(INTERIOR_PX)
        })

# Write CSVs
with open(CSV_NO, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows_no[0].keys()))
    w.writeheader(); w.writerows(rows_no)

with open(CSV_OV, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows_ov[0].keys()))
    w.writeheader(); w.writerows(rows_ov)

# Meta writers
def write_meta(path, mode, ntiles, extra):
    with open(path, "w") as f:
        f.write(f"Raster: {A_VRT}\n")
        f.write(f"Raster size: {W} x {H}\n")
        f.write(f"GeoTransform: {gt}\n")
        f.write(f"Projection: {'set' if proj else 'EMPTY'}\n")
        f.write(f"Mode: {mode}\n")
        f.write(f"Interior px: {INTERIOR_PX}\n")
        for k, v in extra.items():
            f.write(f"{k}: {v}\n")
        f.write(f"Tiles: {ntiles}\n")

write_meta(META_NO, "no-overlap", len(rows_no), {})
write_meta(META_OV, "overlap(productB)", len(rows_ov), {"Buffer_m": BUFFER_M, "Overlap_px": OVERLAP_PX})

# Tile-definition indices (TSV)  these are stable and easy to join later.
# No-overlap index: one window per tile for mosaic exports
with open(INDEX_NO, "w", newline="") as f:
    f.write("tile_id\trow\tcol\txoff\tyoff\txsize\tysize\n")
    for r in rows_no:
        f.write(f"{r['tile_id']}\t{r['row']}\t{r['col']}\t{r['xoff']}\t{r['yoff']}\t{r['xsize']}\t{r['ysize']}\n")

# Product B index: includes interior + overlap in one row (key file you asked for)
with open(INDEX_OV, "w", newline="") as f:
    f.write("tile_id\trow\tcol\t"
            "xoff_int\tyoff_int\txsize_int\tysize_int\t"
            "xoff_win\tyoff_win\txsize_win\tysize_win\t"
            "overlap_px\tinterior_px\n")
    for r in rows_ov:
        f.write(f"{r['tile_id']}\t{r['row']}\t{r['col']}\t"
                f"{r['xoff_int']}\t{r['yoff_int']}\t{r['xsize_int']}\t{r['ysize_int']}\t"
                f"{r['xoff_win']}\t{r['yoff_win']}\t{r['xsize_win']}\t{r['ysize_win']}\t"
                f"{r['overlap_px']}\t{r['interior_px']}\n")

print(f"Wrote: {CSV_NO}")
print(f"Wrote: {CSV_OV}")
print(f"Wrote index: {INDEX_NO}")
print(f"Wrote index: {INDEX_OV}")
print(f"Tiles: {len(rows_no)}")
PY

echo "[`date`] Step 0.3: Summaries"
N_NO=$(( $(wc -l < "$CSV_NO") - 1 ))
N_OV=$(( $(wc -l < "$CSV_OV") - 1 ))

{
  echo "CSV: $CSV_NO"
  echo "N tiles: $N_NO"
  echo "Header:"
  head -n 1 "$CSV_NO"
  echo "First 3 tiles:"
  head -n 4 "$CSV_NO"
  echo "Last 3 tiles:"
  tail -n 3 "$CSV_NO"
  echo "Index TSV: $INDEX_NO"
  head -n 3 "$INDEX_NO"
} > "$SUMMARY_NO"

{
  echo "CSV: $CSV_OV"
  echo "N tiles: $N_OV"
  echo "Header:"
  head -n 1 "$CSV_OV"
  echo "First 3 tiles:"
  head -n 4 "$CSV_OV"
  echo "Last 3 tiles:"
  tail -n 3 "$CSV_OV"
  echo "Index TSV: $INDEX_OV"
  head -n 3 "$INDEX_OV"
} > "$SUMMARY_OV"

echo "[`date`] Done."
echo "VRT:        $A_VRT"
echo "CSV no-ov:  $CSV_NO"
echo "CSV ov:     $CSV_OV"
echo "Index no:   $INDEX_NO"
echo "Index B:    $INDEX_OV"

