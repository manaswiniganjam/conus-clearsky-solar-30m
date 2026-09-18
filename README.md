# CONUS 30m Clear-Sky Solar Radiation Dataset — Processing Pipeline

[![DOI](https://zenodo.org/badge/DOI/ZENODO_DOI_PLACEHOLDER.svg)](https://doi.org/10.5281/zenodo.22822716)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## Dataset

The published dataset is available at:

- **Repository:** [Harvard Dataverse, DOI:10.7910/DVN/ZKSKKX]
- **Components:** Global horizontal irradiance (`glob_rad`), direct beam irradiance (`beam_rad`), diffuse irradiance (`diff_rad`)
- **Coverage:** Conterminous United States (CONUS)
- **Resolution:** 30 m, EPSG:5070 (NAD83 Albers Equal Area Conic)
- **Temporal:** 12 representative days (DOY 15, 45, 74, 105, 135, 166, 196, 227, 258, 288, 319, 349) + annual means
- **Format:** GeoTIFF, Float32, DEFLATE compressed, tiled
- **Size:** ~950 GB (422 tiles × 12 DOYs × 3 components + 3 annual mean layers)

---

## Repository Structure

```
├── 0_1_download.ipynb              # Step 1  — NASADEM download
├── 0_2_build_vrt.sbatch            # Step 2  — VRT mosaic construction
├── 0_3_dem_domain.sbatch           # Step 3  — Domain warp and tiling
├── 0_4_dem_tiles.sbatch            # Step 4  — Export individual DEM tiles
├── 0_5_submit_dem_tiles.sh         # Step 5 — SLURM array submission for tiles
├── 0_6_merge_tile_index.sbatch     # Step 6  — Merge tile metadata index
├── 0_7_conus_rhor_sun_v3.sbatch    # Step 7  — r.sun + r.horizon (main compute)
├── 2_annual_mean.sbatch            # Step 8  — annual mean post-processing
├── validation/
   ├── download_surfrad.txt         # SURFRAD data download command to use in windows powershell
   ├── preprocessing.ipynb          # SURFRAD data preprocessing, filtering
   ├── add_coordinates.ipynb        # adding precise coordinates for each site
   ├── threshold_sensitivity.ipynb  # threshold sensitivity analysis and validation tables
   └── figure 1.ipynb               # Validation analysis and figure generation
```

---

## Pipeline Overview
### Step 1 — NASADEM Download (`0_1_download.ipynb`)
Queries the NASA Common Metadata Repository (CMR) API for NASADEM HGT v001 granules within the CONUS bounding box (−125°W to −66°W, 25°N to 50°N). Downloads 1,250 individual 1°×1° HGT zip files via authenticated curl requests using NASA Earthdata credentials.

**Requires:** NASA Earthdata account with `.netrc` credentials configured.

---

### Step 2 — VRT Mosaic (`0_2_build_vrt.sbatch`)
Builds a GDAL virtual raster (VRT) mosaic from all downloaded HGT tiles using `gdalbuildvrt`. The VRT serves as the authoritative source raster for all subsequent preprocessing.

---

### Step 3 — Domain Warp and Tiling (`0_3_dem_domain.sbatch`)
Reprojects and resamples the VRT mosaic to:
- **CRS:** EPSG:5070 (NAD83 Albers Equal Area Conic)
- **Resolution:** 30 m
- **Resampling:** Cubic
- **Extent:** CONUS + 30 km buffer

Partitions the domain into a regular grid of 640 tiles (5,000 × 5,000 px interior, 30 km / 1,000 px overlap buffer). Generates tile index CSV with pixel coordinates for each tile.

---

### Step 4 + Step 5 — DEM Tile Export (`0_4_dem_tiles.sbatch` + `0_5_submit_dem_tiles.sh`)
Exports individual overlap DEM tile GeoTIFFs from the warped VRT using SLURM array jobs. Each tile includes the 1,000-pixel overlap buffer for horizon computation. `0_5_submit_dem_tiles.sh` configures the SLURM array submission.

---

### Step 6 — Tile Index (`0_6_merge_tile_index.sbatch`)
Merges per-tile metadata TSV outputs into a master tile index used for downstream job coordination.

---

### Step 7 — Solar Radiation Computation (`0_7_conus_rhor_sun_v3.sbatch`)
```bash
sbatch --array=1-462%20 0_7_conus_rhor_sun_v3.sbatch
```
Processes 422 non-void tiles, 20 concurrent jobs.
Expected wall time: 48 hours per tile.

**Primary compute step.** Runs inside a GRASS GIS 8.4 Apptainer container per tile:

1. Exports DEM cutout to local scratch
2. Fills ocean/void border pixels within 21 km belt with elevation = 0 m
3. Computes slope and aspect (`r.slope.aspect`)
4. Computes terrain horizon angles at 36 azimuths, 10° step, 20 km max distance (`r.horizon`)
5. Runs `r.sun` in clear-sky mode for 12 representative DOYs
6. Exports three radiation components per DOY as GeoTIFF:
   - `glob_rad` — global horizontal irradiance (Wh m⁻² day⁻¹)
   - `beam_rad` — direct beam irradiance (Wh m⁻² day⁻¹)
   - `diff_rad` — diffuse irradiance (Wh m⁻² day⁻¹)
  
**Key parameters:**
| Parameter | Value |
|---|---|
| Horizon directions | 36 (0°–350°, 10° step) |
| Horizon max distance | 20,000 m |
| Ocean/void fill belt | 21,000 m |
| Linke turbidity | 3.0 (r.sun default) |
| Ground albedo | 0.2 (r.sun default) |
| Void threshold | valid pixel fraction ≥ 0.001 |
| Output format | Float32 GeoTIFF, DEFLATE, tiled |
| NoData value | −32,768 |

---

### Validation (`validation/`)

- `download_surfrad.txt` — Windows PowerShell script for downloading the required 1-minute SURFRAD `.dat` files from the NOAA SURFRAD archive. Downloads data for the seven CONUS stations (Bondville IL, Fort Peck MT, Goodwin Creek MS, Table Mountain CO, Desert Rock NV, Penn State PA, and Sioux Falls SD) for 2015–2024 at the 12 selected days of year (DOYs: 015, 045, 074, 105, 135, 166, 196, 227, 258, 288, 319, and 349). The files are organized locally by station and year under `C:\Users\<username>\surfrad_data\`. No additional software or PowerShell modules are required. Run the script in Windows PowerShell before executing `preprocessing.ipynb`.
- `preprocessing.ipynb` — Reads local 1-minute SURFRAD .dat files (2015–2024) for 7 CONUS stations. Applies QC filtering, clear-sky detection (DHI/GHI < threshold), beam horizontal derivation, daily integration, and multi-year mean computation. Run at five threshold values (0.20–0.40) to support the sensitivity analysis below. Outputs surfrad_daily_clearsky.csv, surfrad_multiyear_means.csv, surfrad_data_availability.csv per threshold.
- `SURFRAD stations used (7)` - Bondville IL, Fort Peck MT, Goodwin Creek MS, Table Mountain CO, Desert Rock NV, Penn State PA, Sioux Falls SD
- `add_coordinates.ipynb` — Replaces approximate station coordinates in the SURFRAD outputs with precise solar tracker instrument coordinates.
- `extract_station_values.sbatch` — Extracts r.sun modeled radiation values at the 7 SURFRAD station coordinates from the CONUS tile mosaics, via gdaltransform/gdallocationinfo. Outputs rsun_station_values.csv.
- `threshold_sensitivity.ipynb` — Joins r.sun station values with SURFRAD multi-year means across all five thresholds. Computes validation statistics (R², RMSE, MBE, rMBE) at threshold = 0.30 (manuscript Table 1), performs seasonal/spatial signal decomposition (manuscript Table 3: seasonal R² = 0.955, spatial R² = 0.435), and generates the threshold sensitivity figure justifying the 0.30 selection.
- `figure 1.ipynb` — Generates the manuscript's Figure 1 (r.sun modeled vs. SURFRAD measured scatter plot, 3 panels).
  
---

## Computational Requirements
The computational workflows use Apptainer containers on the Hellbender HPC
cluster to provide reproducible and compatible software environments. The
containers should be set up using the specified software versions because
GRASS GIS, GDAL, Python, and their associated libraries can have version
dependencies that affect the execution of the workflows.

Different stages of the workflow use different containers according to their
software requirements:

| Container | Environment | Use |
|---|---|---|
| `grass83.sif` | GRASS GIS 8.3 environment + GDAL | Workflows requiring GRASS GIS 8.3 |
| `grass84.sif` | GRASS GIS 8.4 environment + GDAL | Workflows requiring GRASS GIS 8.4 |
| `nasadem_py310.sif` | Python 3.10 + GRASS GIS 8.3 + GDAL | NASADEM/tile-processing workflows requiring Python 3.10 and GRASS GIS 8.3 |

The appropriate container must be specified in each SLURM script or workflow.
`grass83.sif` and `grass84.sif` are not interchangeable when a workflow
depends on a specific GRASS GIS version.

### Container setup

Apptainer is provided through the Hellbender HPC environment. Containers
should be generated from their corresponding Apptainer definition (`.def`)
files using the required base image and pinned software versions. For example:

```bash
module load apptainer

apptainer build grass83.sif grass83.def
apptainer build grass84.sif grass84.def
apptainer build nasadem_py310.sif nasadem_py310.def

apptainer exec grass83.sif grass --version
apptainer exec grass84.sif grass --version
apptainer exec nasadem_py310.sif grass --version
apptainer exec nasadem_py310.sif python3 --version

```
------

| Resource | Specification |
|---|---|
| HPC cluster | Hellbender, University of Missouri |
| Job scheduler | SLURM |
| Container runtime | Apptainer (formerly Singularity) |
| Container | GRASS GIS 8.4 + GDAL + Python 3 |
| Tiles processed | 422 non-void tiles |
| Concurrent jobs | 20 (configurable via `%N` in `--array`) |
| Wall time per tile | 48 hours (terrain complexity dependent) |
| Typical runtime per tile | 2–4 hours (terrain complexity dependent) |
| Scratch storage per tile | ~5 GB (auto-cleaned after job) |
| Total output size | ~950 GB |

---

## Dependencies

| Tool | Version | Purpose |
|---|---|---|
| GRASS GIS | 8.4 | `r.sun`, `r.horizon`, `r.slope.aspect` |
| GDAL | ≥ 3.4 | VRT, warp, translate, gdallocationinfo |
| Apptainer | ≥ 1.0 | Container runtime |
| Python | ≥ 3.9 | Tile index generation, void classification |
| pandas | ≥ 1.5 | SURFRAD preprocessing |
| numpy | ≥ 1.23 | Validation statistics |
| matplotlib | ≥ 3.6 | Figures |
| scipy | ≥ 1.9 | Regression statistics |
| SLURM | any | Job scheduling |

---

## Quickstart — Reproducing the Dataset

1. Configure NASA Earthdata credentials (see Step 1)
2. Run Steps 1–6 sequentially on the cluster
3. Submit Step 7 array: `sbatch --array=1-461%20 0_7_conus_rhor_sun_v2.sbatch`
4. After completion, compute annual means: `sbatch 2_annual_mean.sbatch`

## Acknowledgements
SURFRAD data used for validation provided by NOAA GML.
Augustine et al. (2000); Augustine et al. (2005).

## Data Citation

If you use the dataset, please cite:

> Ganjam, M., Dickinson, M., Rau, B., & Stambaugh, M. (2026). Thirty-meter resolution clear-sky solar radiation for the conterminous United States with terrain horizon correction [Data set]. Harvard Dataverse, V1. https://doi.org/10.7910/DVN/ZKSKKX

And the code repository:

> [Author names] ([Year]). CONUS 30m Clear-Sky Solar Radiation — Processing Pipeline. Zenodo. DOI: TBD

---

## References

- Augustine, J. A., DeLuisi, J. J., & Long, C. N. (2000). SURFRAD—A National Surface Radiation Budget Network for Atmospheric Research. Bulletin of the American Meteorological Society, 81(10), 2341–2357. https://doi.org/10.1175/1520-0477(2000)081%3C2341:SANSRB%3E2.3.CO;2
- Augustine, J. A., Hodges, G. B., Cornwall, C. R., Michalsky, J. J., & Medina, C. I. (2005). An Update on SURFRAD—The GCOS Surface Radiation Budget Network for the Continental United States. Journal of Atmospheric and Oceanic Technology, 22(10), 1460–1472. https://doi.org/10.1175/JTECH1806.1

---
## License

Code: [MIT License](LICENSE)  
Dataset: [Creative Commons Zero v1.0 Universal (CC0 1.0)](https://creativecommons.org/publicdomain/zero/1.0/)

---

## Contact

Manaswini Ganjam, Centre for Tree-Ring Science, University of Missouri  
For dataset questions: mgvhy@umsystem.edu  
For code issues: please open a GitHub issue.
