#!/usr/bin/env bash
#SBATCH --job-name=rsun_tiles_v2
#SBATCH --partition=general
#SBATCH --account=general
#SBATCH --qos=normal
#SBATCH --time=48:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --output=logs/rsun_v2/rsun_%A_%a.out
#SBATCH --error=logs/rsun_v2/rsun_%A_%a.err

set -euo pipefail
IFS=$'\n\t'

mkdir -p logs/rsun_v2
echo "HOST=$(hostname) PWD=$(pwd)"
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-NA} SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-NA}"

LOG_TILE="logs/rsun_v2/rsun_tile_UNKNOWN.log"
trap 'rc=$?; echo "[$(date)] ERROR rc=$rc line=$LINENO cmd=$BASH_COMMAND" | tee -a "$LOG_TILE"; exit $rc' ERR

# ---------------- CONFIG ----------------
BASE=/cluster/pixstor/stambaughm-lab/nasadem_conus/conus
TILECSV=$BASE/02_dem_tiles/metadata/tile_windows_overlap30km_5000px.csv
VOID_LIST="${VOID_LIST:-$BASE/02_dem_tiles/metadata/tiles_VOID.txt}"
VRT=$BASE/01_dem_domain/demA_warped_epsg5070_30m_conus30km.vrt

# Tile allowlist: one tile_id per line (e.g., 000002)
# Default: nonvoid_tiles.txt — all 463 land tiles
TILELIST="${TILELIST:-$BASE/02_dem_tiles/metadata/tiles_NONVOID.txt}"
[[ -f "$TILELIST" ]] || { echo "ERROR: missing TILELIST=$TILELIST"; exit 2; }

HSTEP="${HSTEP:-10}"
HDIST="${HDIST:-20000}"
NODATA="${NODATA:--32768}"
FILL0_BELT_M="${FILL0_BELT_M:-21000}"
MIN_VALID_FRAC="${MIN_VALID_FRAC:-0.001}"

# DOYs
DOYS_STR="${DOYS:-"15 45 74 105 135 166 196 227 258 288 319 349"}"
IFS=' ' read -r -a DOYS <<< "$DOYS_STR"
IFS=$'\n\t'

# ---- OUTPUT ROOT: new directory, keeps v1 glob_rad outputs untouched ----
OUT_RAD_ROOT=$BASE/03_solar/rsun_allrad_H${HSTEP}_D${HDIST}
mkdir -p "$OUT_RAD_ROOT"

MASTER="$OUT_RAD_ROOT/master_rsun_status.tsv"
QA_TSV="$OUT_RAD_ROOT/qa_rsun_tiles.tsv"
if [[ ! -f "$MASTER" ]]; then
  echo -e "tile_id\tstate\telapsed_s\tn_written\tdem_valid_frac\tdem0_null_frac" > "$MASTER"
fi
if [[ ! -f "$QA_TSV" ]]; then
  echo -e "tile_id\tdoy\tglob_min\tglob_max\tglob_mean\tbeam_mean\tdiff_mean\tnull_frac" > "$QA_TSV"
fi

# ---------------- TASK ----------------
TIDX="${SLURM_ARRAY_TASK_ID:-}"
[[ -n "$TIDX" ]] || { echo "ERROR: run as SLURM array"; exit 2; }

TILE_ID=$(awk -v n="$TIDX" 'NR==n{gsub(/\r/,""); gsub(/[[:space:]]+/,""); print; exit}' "$TILELIST")

[[ -n "${TILE_ID:-}" ]] || { echo "ERROR: no tile_id at line $TIDX in $TILELIST"; exit 3; }
[[ "$TILE_ID" =~ ^[0-9]{6}$ ]] || { echo "ERROR: bad TILE_ID='$TILE_ID' from $TILELIST line $TIDX"; exit 4; }

LOG_TILE="logs/rsun_v2/rsun_tile_${TILE_ID}.log"

START=$(date +%s)

# ---------------- SCRATCH ----------------
if [[ -n "${SLURM_TMPDIR:-}" ]]; then
  SCRATCH_BASE="$SLURM_TMPDIR"
else
  SCRATCH_BASE="/tmp/${USER}"
fi
mkdir -p "$SCRATCH_BASE"

TMP="$SCRATCH_BASE/rsun_${TILE_ID}_${SLURM_JOB_ID:-manual}"
TMPDIR="$TMP/tmp"
DEM_TIF="$TMP/dem_${TILE_ID}.tif"

cleanup() {
  echo "[$(date)] CLEANUP rm -rf $TMP" | tee -a "$LOG_TILE" || true
  rm -rf "$TMP" 2>/dev/null || true
}
on_term() {
  local elap=$(( $(date +%s) - START ))
  echo "[$(date)] PREEMPT/TERM tile=$TILE_ID elapsed_s=$elap" | tee -a "$LOG_TILE"
  flock "$MASTER" -c "echo -e '${TILE_ID}\tPREEMPT\t${elap}\t0\t.\t.' >> '$MASTER'" || true
  cleanup
  exit 143
}
trap on_term TERM INT
trap cleanup EXIT

mkdir -p "$TMP" "$TMPDIR"
export TMPDIR CPL_TMPDIR="$TMPDIR"

echo "[$(date)] SCRATCH_BASE=$SCRATCH_BASE TMP=$TMP" | tee -a "$LOG_TILE"
df -h "$SCRATCH_BASE" 2>/dev/null | tee -a "$LOG_TILE" || true

# ---------------- CONTAINER RUNTIME ----------------
module purge || true

if command -v apptainer >/dev/null 2>&1; then
  CONTAINER_RUNNER="apptainer"
elif command -v singularity >/dev/null 2>&1; then
  CONTAINER_RUNNER="singularity"
else
  echo "ERROR: neither apptainer nor singularity found in PATH."
  exit 127
fi

CONTBASE=/cluster/pixstor/stambaughm-lab/containers
SIF="$CONTBASE/grass84.sif"
OVL="$CONTBASE/grass84_py.overlay"
[[ -f "$SIF" ]] || { echo "ERROR: missing $SIF"; exit 2; }
[[ -f "$OVL" ]] || { echo "ERROR: missing $OVL"; exit 2; }

AEXEC() {
  "$CONTAINER_RUNNER" exec --overlay "${OVL}:ro" \
    --bind "$BASE:$BASE" \
    --bind "$SCRATCH_BASE:$SCRATCH_BASE" \
    "$SIF" "$@"
}

AEXEC grass --version >/dev/null
AEXEC gdal_translate --version >/dev/null
AEXEC /opt/venv/bin/python --version >/dev/null

# -------- skip void tiles --------
if [[ -f "$VOID_LIST" ]] && grep -qx "$TILE_ID" "$VOID_LIST"; then
  echo "[$(date)] SKIP void tile=$TILE_ID" | tee -a "$LOG_TILE"
  ELAP=$(( $(date +%s) - START ))
  flock "$MASTER" -c "echo -e '${TILE_ID}\tVOID_SKIP\t${ELAP}\t0\t.\t.' >> '$MASTER'"
  exit 0
fi

# ---- Read overlap + interior srcwin from TILECSV ----
export TILECSV TILE_ID
IFS=' ' read -r xoff_win yoff_win xsize_win ysize_win xoff_int yoff_int xsize_int ysize_int < <(
  AEXEC /opt/venv/bin/python - <<'PY'
import csv, os, sys
tile_id = os.environ["TILE_ID"]
path = os.environ["TILECSV"]
with open(path, newline="") as f:
    r = csv.DictReader(f)
    for row in r:
        if row["tile_id"] == tile_id:
            print(
                row["xoff_win"], row["yoff_win"], row["xsize_win"], row["ysize_win"],
                row["xoff_int"], row["yoff_int"], row["xsize_int"], row["ysize_int"]
            )
            sys.exit(0)
print(f"TILE_ID {tile_id} not found in {path}", file=sys.stderr)
sys.exit(2)
PY
)
IFS=$'\n\t'

echo "[$(date)] TILE_ID=$TILE_ID overlap srcwin=${xoff_win},${yoff_win},${xsize_win},${ysize_win}" | tee -a "$LOG_TILE"
echo "[$(date)] TILE_ID=$TILE_ID interior srcwin=${xoff_int},${yoff_int},${xsize_int},${ysize_int}" | tee -a "$LOG_TILE"

# ---- Get geotransform from VRT ----
IFS=' ' read -r x0 y0 pxw pxh < <(
  AEXEC /opt/venv/bin/python - <<PY
import json, subprocess
vrt="${VRT}"
j=json.loads(subprocess.check_output(["gdalinfo","-json",vrt], text=True))
gt=j["geoTransform"]
print(gt[0], gt[3], gt[1], gt[5])
PY
)
IFS=$'\n\t'

west=$(awk -v x0="$x0" -v dx="$pxw" -v xoff="$xoff_int" 'BEGIN{printf("%.3f", x0 + dx*xoff)}')
east=$(awk -v w="$west" -v dx="$pxw" -v xs="$xsize_int" 'BEGIN{printf("%.3f", w + dx*xs)}')
north=$(awk -v y0="$y0" -v dy="$pxh" -v yoff="$yoff_int" 'BEGIN{printf("%.3f", y0 + dy*yoff)}')
south=$(awk -v n="$north" -v dy="$pxh" -v ys="$ysize_int" 'BEGIN{printf("%.3f", n + dy*ys)}')

echo "[$(date)] TILE_ID=$TILE_ID interior bounds w/e/s/n = $west $east $south $north" | tee -a "$LOG_TILE"

# -------- output dirs per DOY: three components --------
for d in "${DOYS[@]}"; do
  d3=$(printf "%03d" "$d")
  mkdir -p "$OUT_RAD_ROOT/glob_rad/doy$d3"
  mkdir -p "$OUT_RAD_ROOT/beam_rad/doy$d3"
  mkdir -p "$OUT_RAD_ROOT/diff_rad/doy$d3"
done

# -------- fast restartability: if ALL three components exist for ALL DOYs, skip --------
ALLDONE=1
for d in "${DOYS[@]}"; do
  d3=$(printf "%03d" "$d")
  [[ -f "$OUT_RAD_ROOT/glob_rad/doy$d3/glob_tile_${TILE_ID}_d${d3}.tif" ]] || { ALLDONE=0; break; }
  [[ -f "$OUT_RAD_ROOT/beam_rad/doy$d3/beam_tile_${TILE_ID}_d${d3}.tif" ]] || { ALLDONE=0; break; }
  [[ -f "$OUT_RAD_ROOT/diff_rad/doy$d3/diff_tile_${TILE_ID}_d${d3}.tif" ]] || { ALLDONE=0; break; }
done
if [[ "$ALLDONE" -eq 1 ]]; then
  ELAP=$(( $(date +%s) - START ))
  echo "[$(date)] SKIP tile=$TILE_ID (all DOYs + all 3 components exist)" | tee -a "$LOG_TILE"
  flock "$MASTER" -c "echo -e '${TILE_ID}\tSKIP\t${ELAP}\t0\t.\t.' >> '$MASTER'"
  exit 0
fi

# -------- export overlap DEM cutout to local scratch --------
echo "[$(date)] Export DEM cutout -> $DEM_TIF" | tee -a "$LOG_TILE"
AEXEC gdal_translate \
  -srcwin "$xoff_win" "$yoff_win" "$xsize_win" "$ysize_win" \
  -of GTiff -co TILED=YES -co BIGTIFF=IF_SAFER -co COMPRESS=NONE \
  "$VRT" "$DEM_TIF" >>"$LOG_TILE" 2>&1

# ================= GRASS work =================
RUN_GRASS="$TMP/run_grass_${TILE_ID}.sh"
cat > "$RUN_GRASS" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

: "${DOYS:=15 45 74 105 135 166 196 227 258 288 319 349}"

echo "BOOT GRASS tile=$TILE_ID TMP=$TMP DEM_TIF=$DEM_TIF" >&2

GISDBASE="$TMP/grassdb"
LOCATION="loc"
MAPSET="PERMANENT"
mkdir -p "$GISDBASE"
grass -c EPSG:5070 "$GISDBASE/$LOCATION" --exec true >/dev/null
g() { grass --text "$GISDBASE/$LOCATION/$MAPSET" --exec "$@"; }

g r.external input="$DEM_TIF" output=dem --overwrite >/dev/null
g g.region raster=dem -a >/dev/null

dem_stats=$(g r.univar -g map=dem 2>/dev/null || true)
dem_n=$(printf "%s\n" "$dem_stats" | awk -F= '$1=="n"{print $2}'); dem_n=${dem_n:-0}
dem_null=$(printf "%s\n" "$dem_stats" | awk -F= '$1=="null_cells"{print $2}'); dem_null=${dem_null:-0}
dem_tot=$(awk -v n="$dem_n" -v nu="$dem_null" 'BEGIN{print n+nu}')
dem_valid_frac=$(awk -v n="$dem_n" -v t="$dem_tot" 'BEGIN{
  if(t>0) printf("%.6f", n/t);
  else print "0.000000"
}')
echo "$dem_valid_frac" > "$TMP/dem_valid_frac.txt"

is_empty=$(awk -v vf="$dem_valid_frac" -v mv="$MIN_VALID_FRAC" 'BEGIN{ print (vf < mv) ? 1 : 0 }')
if [[ "$is_empty" -eq 1 ]]; then
  echo "EMPTY" > "$TMP/state.txt"
  echo "0" > "$TMP/n_written.txt"
  echo "." > "$TMP/dem0_null_frac.txt"
  exit 0
fi

g r.mask -r >/dev/null 2>&1 || true
g r.grow.distance input=dem distance=dist --overwrite >/dev/null
g r.mapcalc --overwrite expression="mask_belt = if(isnull(dem), if(dist <= $FILL0_BELT_M, 1, null()), 1)" >/dev/null
g r.mask raster=mask_belt --overwrite >/dev/null
g r.mapcalc --overwrite expression="dem0 = if(isnull(dem), 0.0, dem)" >/dev/null
g g.region raster=dem0 -a >/dev/null

dem0_stats=$(g r.univar -g map=dem0 2>/dev/null || true)
dem0_n=$(printf "%s\n" "$dem0_stats" | awk -F= '$1=="n"{print $2}'); dem0_n=${dem0_n:-0}
dem0_null=$(printf "%s\n" "$dem0_stats" | awk -F= '$1=="null_cells"{print $2}'); dem0_null=${dem0_null:-0}
dem0_tot=$(awk -v n="$dem0_n" -v nu="$dem0_null" 'BEGIN{print n+nu}')
dem0_null_frac=$(awk -v nu="$dem0_null" -v t="$dem0_tot" 'BEGIN{
  if(t>0) printf("%.6f", nu/t);
  else print "1.000000"
}')
echo "$dem0_null_frac" > "$TMP/dem0_null_frac.txt"

g r.slope.aspect elevation=dem0 slope=slope aspect=aspect --overwrite >/dev/null

hor_base="hor_${TILE_ID}_"

for ang in $(seq -w 0 "$HSTEP" 350); do
  hmap="hor_${TILE_ID}__${ang}"
  if ! g r.horizon elevation=dem0 direction=$((10#$ang)) maxdistance="$HDIST" output="$hor_base" --overwrite >/dev/null
  then
    fallback_dist=$(( HDIST > 2000 ? HDIST - 1000 : HDIST ))
    g r.horizon elevation=dem0 direction=$((10#$ang)) maxdistance="$fallback_dist" output="$hor_base" --overwrite >/dev/null \
      || { echo "RHORIZON_FAIL_$ang" > "$TMP/state.txt"; exit 5; }
  fi
  g r.mapcalc --overwrite expression="$hmap = if(isnull($hmap), null(), if($hmap >= 89.999, 89.999, if($hmap < 0, 0, $hmap)))" >/dev/null
done

n_written=0
for d in $DOYS; do
  d3=$(printf "%03d" "$d")

  glob_out="$OUT_RAD_ROOT/glob_rad/doy${d3}/glob_tile_${TILE_ID}_d${d3}.tif"
  beam_out="$OUT_RAD_ROOT/beam_rad/doy${d3}/beam_tile_${TILE_ID}_d${d3}.tif"
  diff_out="$OUT_RAD_ROOT/diff_rad/doy${d3}/diff_tile_${TILE_ID}_d${d3}.tif"

  # Skip this DOY only if all three outputs already exist
  if [[ -f "$glob_out" && -f "$beam_out" && -f "$diff_out" ]]; then
    echo "DOY $d3 already complete, skipping" >&2
    continue
  fi

  g g.region n=$north s=$south e=$east w=$west -a >/dev/null

  mg="rad_glob_${TILE_ID}_${d3}"
  mb="rad_beam_${TILE_ID}_${d3}"
  md="rad_diff_${TILE_ID}_${d3}"

  # === KEY CHANGE: r.sun now outputs all three components ===
  g r.sun elevation=dem0 slope=slope aspect=aspect day=$d \
    horizon_basename="hor_${TILE_ID}_" horizon_step="$HSTEP" \
    glob_rad="$mg" \
    beam_rad="$mb" \
    diff_rad="$md" \
    --overwrite >/dev/null

  # QA stats for glob_rad
  ustats=$(g r.univar -g map="$mg" 2>/dev/null || true)
  rn=$(printf "%s\n" "$ustats" | awk -F= '$1=="n"{print $2}'); rn=${rn:-0}
  rnu=$(printf "%s\n" "$ustats" | awk -F= '$1=="null_cells"{print $2}'); rnu=${rnu:-0}
  rmin=$(printf "%s\n" "$ustats" | awk -F= '$1=="min"{print $2}'); rmin=${rmin:-.}
  rmax=$(printf "%s\n" "$ustats" | awk -F= '$1=="max"{print $2}'); rmax=${rmax:-.}
  rmean=$(printf "%s\n" "$ustats" | awk -F= '$1=="mean"{print $2}'); rmean=${rmean:-.}
  rtot=$(awk -v n="$rn" -v u="$rnu" 'BEGIN{print n+u}')
  rf=$(awk -v u="$rnu" -v t="$rtot" 'BEGIN{print (t>0)?u/t:1}')

  # QA stats for beam_rad and diff_rad (mean only)
  bstats=$(g r.univar -g map="$mb" 2>/dev/null || true)
  bmean=$(printf "%s\n" "$bstats" | awk -F= '$1=="mean"{print $2}'); bmean=${bmean:-.}
  dstats=$(g r.univar -g map="$md" 2>/dev/null || true)
  dmean=$(printf "%s\n" "$dstats" | awk -F= '$1=="mean"{print $2}'); dmean=${dmean:-.}

  echo -e "${TILE_ID}\t${d3}\t${rmin}\t${rmax}\t${rmean}\t${bmean}\t${dmean}\t${rf}" >> "$OUT_RAD_ROOT/qa_rsun_tiles.tsv"

  # Export all three components
  g r.out.gdal -c input="$mg" output="$glob_out" \
    nodata="$NODATA" type=Float32 format=GTiff \
    createopt="COMPRESS=DEFLATE,TILED=YES,BIGTIFF=IF_SAFER" --overwrite >/dev/null

  g r.out.gdal -c input="$mb" output="$beam_out" \
    nodata="$NODATA" type=Float32 format=GTiff \
    createopt="COMPRESS=DEFLATE,TILED=YES,BIGTIFF=IF_SAFER" --overwrite >/dev/null

  g r.out.gdal -c input="$md" output="$diff_out" \
    nodata="$NODATA" type=Float32 format=GTiff \
    createopt="COMPRESS=DEFLATE,TILED=YES,BIGTIFF=IF_SAFER" --overwrite >/dev/null

  g g.remove -f type=raster name="$mg,$mb,$md" >/dev/null 2>&1 || true
  n_written=$((n_written+1))
done

echo "$n_written" > "$TMP/n_written.txt"
echo "DONE" > "$TMP/state.txt"

hor_list=$(seq -w 0 "$HSTEP" 350 | awk -v t="$TILE_ID" '{printf "hor_%s__%s,", t, $1}' | sed 's/,$//')
g g.remove -f type=raster name="dem,dem0,dist,mask_belt,slope,aspect,${hor_list}" >/dev/null 2>&1 || true
EOS
chmod +x "$RUN_GRASS"

export TILE_ID HSTEP HDIST NODATA FILL0_BELT_M MIN_VALID_FRAC OUT_RAD_ROOT
export DOYS="$(printf "%s " "${DOYS[@]}")"
export west east south north
export TMP DEM_TIF

set +e
AEXEC bash "$RUN_GRASS" 2>&1 | tee -a "$LOG_TILE"
rc=${PIPESTATUS[0]}
set -e

ELAP=$(( $(date +%s) - START ))
state=$(cat "$TMP/state.txt" 2>/dev/null || echo "FAIL")
n_written=$(cat "$TMP/n_written.txt" 2>/dev/null || echo "0")
dem_valid_frac=$(cat "$TMP/dem_valid_frac.txt" 2>/dev/null || echo ".")
dem0_null_frac=$(cat "$TMP/dem0_null_frac.txt" 2>/dev/null || echo ".")

if (( rc != 0 )) && [[ "$state" == "DONE" ]]; then
  state="FAIL_RC${rc}"
fi

flock "$MASTER" -c "echo -e '${TILE_ID}\t${state}\t${ELAP}\t${n_written}\t${dem_valid_frac}\t${dem0_null_frac}' >> '$MASTER'"

echo "[$(date)] ${state} tile=$TILE_ID elapsed_s=$ELAP n_written=$n_written valid_frac=$dem_valid_frac" | tee -a "$LOG_TILE"

# cleanup via trap EXIT
