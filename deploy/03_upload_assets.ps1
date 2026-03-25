# Phase 3 — Upload USD Assets to GCS (Windows PowerShell)
# Uploads the full DataHall digital twin (9.6 GB) to GCS.
# Prerequisites: gcloud authenticated, config.ps1 present
#
# Usage (from repo root):
#   .\deploy\03_upload_assets.ps1

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\config.ps1"

$USD_ASSETS_LOCAL = $env:USD_ASSETS_LOCAL_WIN
$USD_STAGE_LOCAL  = "$USD_ASSETS_LOCAL\$env:USD_STAGE_RELATIVE" -replace "/","\"
$USD_ASSETS_GCS   = $env:USD_ASSETS_GCS
$USD_STAGE_GCS    = $env:USD_STAGE_GCS

Write-Host "=== Phase 3: Upload USD Assets to GCS ===" -ForegroundColor Cyan
Write-Host "  Source : $USD_ASSETS_LOCAL"
Write-Host "  Dest   : $USD_ASSETS_GCS"
Write-Host ""

if (-not (Test-Path $USD_ASSETS_LOCAL)) {
    Write-Error "Asset directory not found: $USD_ASSETS_LOCAL`nUpdate USD_ASSETS_LOCAL_WIN in deploy/config.ps1"
    exit 1
}

if (-not (Test-Path $USD_STAGE_LOCAL)) {
    Write-Error "Stage file not found: $USD_STAGE_LOCAL"
    exit 1
}

# Check size
$size = (Get-ChildItem $USD_ASSETS_LOCAL -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host "Source size: $([math]::Round($size/1GB, 2)) GB"
Write-Host ""

# Idempotency check
$exists = gcloud storage ls $USD_STAGE_GCS 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Stage file already exists in GCS: $USD_STAGE_GCS" -ForegroundColor Green
    Write-Host "     Skipping upload. To force re-upload, run:"
    Write-Host "     gcloud storage rm -r $USD_ASSETS_GCS"
    Write-Host ""
    Write-Host "Next step: .\deploy\04_build_and_push.ps1"
    exit 0
}

Write-Host "Starting upload (10-30 min depending on bandwidth)..." -ForegroundColor Yellow
# Do NOT use --gzip-in-flight — USD files must be stored uncompressed for Kit.
gcloud storage cp -r $USD_ASSETS_LOCAL $USD_ASSETS_GCS
if ($LASTEXITCODE -ne 0) { Write-Error "Upload failed."; exit 1 }

Write-Host ""
Write-Host "=== Upload complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Verifying GCS structure:"
gcloud storage ls "$USD_ASSETS_GCS/" | Select-Object -First 20

Write-Host ""
Write-Host "Stage GCS path:"
Write-Host "  $USD_STAGE_GCS"
Write-Host ""
Write-Host "Next step: .\deploy\04_build_and_push.ps1"
