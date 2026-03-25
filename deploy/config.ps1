# ============================================================
# STEP 0 (Windows) — Edit this file before running any .ps1 script
# This is the PowerShell equivalent of config.env
# ============================================================

# Your GCP project ID (e.g. my-datacenter-twin-001)
$env:GCP_PROJECT_ID = "hmth391"

# GCP region and zone
$env:GCP_REGION = "us-central1"
$env:GCP_ZONE   = "us-central1-a"

# ── GCS Buckets ──────────────────────────────────────────────────────────────
# Primary bucket: USD assets + training data + model artefacts
$env:GCS_BUCKET = "$($env:GCP_PROJECT_ID)-omniverse-assets"

# Telemetry ingest bucket: real sensor data from Jetson Nano edge devices
# Provisioned externally — do NOT recreate in 02_gcp_setup.ps1
$env:GCS_TELEMETRY_BUCKET = "hmth391-telemetry-ingest"

# ── Artifact Registry ────────────────────────────────────────────────────────
# Kit Streaming container repo (Phase 4b / 5b)
$env:AR_REPO_KIT    = "omniverse-kit"

# World Model + DINO encoder repo (Phase 4 inference, edge deployment)
# Provisioned by Nolan: us-central1-docker.pkg.dev/hmth391/world-model-repo
$env:AR_REPO_MODELS = "world-model-repo"

# ── Image URIs ───────────────────────────────────────────────────────────────
$env:KIT_IMAGE_URI  = "$($env:GCP_REGION)-docker.pkg.dev/$($env:GCP_PROJECT_ID)/$($env:AR_REPO_KIT)/usd-viewer:latest"
$env:IMAGE_TAG      = "datacenter-inference:latest"
$env:IMAGE_URI      = "$($env:GCP_REGION)-docker.pkg.dev/$($env:GCP_PROJECT_ID)/$($env:AR_REPO_MODELS)/$($env:IMAGE_TAG)"
$env:DINO_IMAGE_TAG = "dino-encoder:latest"
$env:DINO_IMAGE_URI = "$($env:GCP_REGION)-docker.pkg.dev/$($env:GCP_PROJECT_ID)/$($env:AR_REPO_MODELS)/$($env:DINO_IMAGE_TAG)"

# ── GPU VM ───────────────────────────────────────────────────────────────────
$env:VM_NAME         = "datacenter-kit-vm"
$env:VM_MACHINE_TYPE = "g2-standard-8"
$env:VM_DISK_SIZE    = "200"

# ── USD Asset Paths ──────────────────────────────────────────────────────────
# Root of the DigitalTwin folder on your Windows machine (Windows-style path)
$env:USD_ASSETS_LOCAL_WIN = "C:\Users\danie\OneDrive\Assets\DigitalTwin"

# Bash-style path (used only if running scripts in Git Bash)
$env:USD_ASSETS_LOCAL = "/c/Users/danie/OneDrive/Assets/DigitalTwin"

# Relative path to the stage file from the root
$env:USD_STAGE_RELATIVE = "Assets/Datacenter/Facilities/Stages/Data_Hall/DataHall_Full_01.usd"

# Derived full paths
$env:USD_STAGE_LOCAL  = "$($env:USD_ASSETS_LOCAL_WIN)\$($env:USD_STAGE_RELATIVE -replace '/','\')"
$env:USD_ASSETS_GCS   = "gs://$($env:GCS_BUCKET)/DigitalTwin"
$env:USD_STAGE_GCS    = "$($env:USD_ASSETS_GCS)/$($env:USD_STAGE_RELATIVE)"

# ── Vertex AI ────────────────────────────────────────────────────────────────
$env:VERTEX_REGION       = "us-central1"

# ── GCS Data Paths ───────────────────────────────────────────────────────────
$env:TRAINING_DATA_GCS   = "gs://$($env:GCS_BUCKET)/training-data"
$env:LIVE_TELEMETRY_GCS  = "gs://$($env:GCS_TELEMETRY_BUCKET)"
$env:MODEL_ARTEFACT_GCS  = "gs://$($env:GCS_BUCKET)/models"
$env:EDGE_MODEL_GCS      = "gs://$($env:GCS_BUCKET)/models/edge"
