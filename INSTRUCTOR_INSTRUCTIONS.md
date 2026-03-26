# Instructor Instructions — Data Center Digital Twin & AI World Model
## Atlanta Robotics — David Mykel Taylor Scholars Program

---

## Overview

This guide covers everything you need to run the workshop:
- One-time infrastructure setup (do this before the first class)
- Adding student emails so they can access the GCS bucket
- Day-of checklist (morning of class)
- What runs where (what you manage vs. what students run)
- End-of-class cleanup to control costs

**GCP Project:** `hmth391`
**Region / Zone:** `us-central1` / `us-central1-a`
**Estimated cost per session:** ~$5–10 (GPU VM + Vertex AI A100 training)

---

## Part 1 — One-Time Infrastructure Setup

Run these steps **once**, before the first class session. They take about 45–60 minutes total.

---

### 1.1 — Authenticate gcloud

Open Google Cloud Shell at **https://shell.cloud.google.com** (or your local terminal with gcloud installed).

```bash
gcloud config set project hmth391
gcloud auth application-default login
gcloud auth configure-docker us-central1-docker.pkg.dev
```

---

### 1.2 — Clone the Repository

```bash
git clone https://github.com/Danny024/dc-world-model-tutorial.git
cd dc-world-model-tutorial
```

Verify config is set correctly — all values should already match:
```bash
cat deploy/config.env
```

Key values (already configured, do not change unless using a different project):
```
GCP_PROJECT_ID="hmth391"
GCP_REGION="us-central1"
GCS_BUCKET="hmth391-omniverse-assets"
GCS_TELEMETRY_BUCKET="hmth391-telemetry-ingest"
AR_REPO_MODELS="world-model-repo"
AR_REPO_KIT="omniverse-kit"
```

---

### 1.3 — Enable APIs and Create GCP Infrastructure

```bash
source deploy/config.env
bash deploy/02_gcp_setup.sh
```

This creates (idempotent — safe to re-run):
- GCS bucket `hmth391-omniverse-assets`
- Artifact Registry repos: `omniverse-kit` and `world-model-repo`
- GPU VM `datacenter-kit-vm` (g2-standard-8, 1x NVIDIA L4)
- Firewall rules for WebRTC ports (49100–49200 UDP, 8011–8012 TCP)
- IAM permissions for Cloud Build

**Takes ~5 minutes.**

---

### 1.4 — Upload USD Assets (One Time Only — From Windows Machine)

The 9.6 GB DataHall USD scene must be uploaded from your local machine (it lives on your OneDrive at `C:/Users/danie/OneDrive/Assets/DigitalTwin`). Do not run this from Cloud Shell — the files are not there.

**On Windows (Git Bash or WSL):**
```bash
source deploy/config.env
bash deploy/03_upload_assets.sh
```

**On Windows (PowerShell):**
```powershell
. deploy\config.ps1
.\deploy\03_upload_assets.ps1
```

Takes 15–30 minutes depending on your connection. The script is idempotent — it skips files already in GCS.

Verify the upload from Cloud Shell:
```bash
gcloud storage ls gs://hmth391-omniverse-assets/DigitalTwin/ | head -5
```

---

### 1.5 — Pull and Push the NVIDIA Kit Streaming Image

Requires your NGC (NVIDIA GPU Cloud) API key.

```bash
export NGC_API_KEY="your-ngc-api-key-here"
source deploy/config.env
bash deploy/04b_pull_kit_image.sh
```

This pulls `nvcr.io/nvidia/omniverse/usd-viewer:109.0.2` from NVIDIA and pushes it to your Artifact Registry so the GPU VM can pull it without needing NGC credentials.

---

### 1.6 — Build and Push the Inference Container

```bash
source deploy/config.env
bash deploy/04_build_and_push.sh
```

Cloud Shell uses Cloud Build automatically. Takes ~5–8 minutes.

Pushes to:
`us-central1-docker.pkg.dev/hmth391/world-model-repo/datacenter-inference:latest`

---

### 1.7 — Deploy Cloud Run Inference Service

```bash
source deploy/config.env
bash deploy/05_deploy_vm.sh
```

Deploys the Flask inference server as a managed Cloud Run service. Scales to zero when idle.

**Save the URL it prints** — you will give this to students for Phase 9, or it is auto-discovered with:
```bash
gcloud run services describe datacenter-inference \
  --region=us-central1 --project=hmth391 \
  --format="get(status.url)"
```

---

### 1.8 — Deploy the 3D Viewer on the GPU VM

```bash
source deploy/config.env
bash deploy/05b_deploy_kit_vm.sh   # pulls Kit image, downloads USD, starts container
bash deploy/05c_deploy_web_viewer.sh  # serves the WebRTC browser UI on port 8080
```

`05b` will take ~10 minutes the first time (downloading 9.6 GB USD from GCS to the VM disk).

Get the VM's external IP — **write this on the board for students:**
```bash
gcloud compute instances describe datacenter-kit-vm \
  --zone=us-central1-a \
  --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
```

Students open `http://VM_EXTERNAL_IP:8080` in their browser to see the 3D viewer.

---

## Part 2 — Adding Student Emails

**You must do this before students run `student_setup.sh`.** If their email is not added, setup fails at Step 3 with a bucket access error.

### Single student
```bash
bash deploy/instructor_grant_access.sh student@gmail.com
```

### Whole class from a file (recommended)

Create `class_roster.txt` (one email per line):
```
alice@gmail.com
bob@gmail.com
carol@university.edu
# lines starting with # are ignored
```

Then:
```bash
bash deploy/instructor_grant_access.sh --file class_roster.txt
```

### Google Group (easiest for large classes)

Create a Google Group at https://groups.google.com, add all student emails, then:
```bash
bash deploy/instructor_grant_access.sh --group your-class@googlegroups.com
```

Students just need to join the group — no per-student commands.

### What students get access to
- **Read-only** on `gs://hmth391-omniverse-assets` (USD assets, training data, trained models)
- No write access — they cannot delete or overwrite anything
- They do NOT have access to `gs://hmth391-telemetry-ingest` by default (live Jetson data)

### Verify who has access
```bash
gcloud storage buckets get-iam-policy gs://hmth391-omniverse-assets \
  --format="table(bindings.role, bindings.members)"
```

### Remove a student's access
```bash
gcloud storage buckets remove-iam-policy-binding gs://hmth391-omniverse-assets \
  --member="user:student@gmail.com" \
  --role="roles/storage.objectViewer"
```

---

## Part 3 — Day-of Class Checklist

### 07:00 AM — 30 Minutes Before Students Arrive

```bash
# 1. Start the GPU VM (if stopped from last session)
gcloud compute instances start datacenter-kit-vm --zone=us-central1-a

# 2. Wait ~90 seconds, then verify Kit is running on the VM
gcloud compute ssh datacenter-kit-vm --zone=us-central1-a \
  --command="docker ps | grep datacenter-kit"

# 3. If Kit is not running, restart it
bash deploy/05b_deploy_kit_vm.sh

# 4. Verify Cloud Run is healthy
SERVICE_URL=$(gcloud run services describe datacenter-inference \
  --region=us-central1 --format="get(status.url)")
curl "${SERVICE_URL}/health"
# Expected: {"status": "ok", "model_loaded": true}

# 5. Get the VM IP and write it on the board
gcloud compute instances describe datacenter-kit-vm \
  --zone=us-central1-a \
  --format="get(networkInterfaces[0].accessConfigs[0].natIP)"

# 6. Open the 3D viewer in your browser to confirm it loads
# http://VM_EXTERNAL_IP:8080

# 7. Verify student workstations are up (if using Scholar VMs)
gcloud compute instances list \
  --filter="name~scholar-workstation" \
  --zones=us-central1-a
```

### Write on the Board for Students
```
Cloud Shell URL : https://shell.cloud.google.com
Repo            : git clone https://github.com/Danny024/dc-world-model-tutorial.git
3D Viewer       : http://VM_EXTERNAL_IP:8080
```

---

## Part 4 — What Students Run vs. What You Manage

| Phase | Who runs it | Where |
|---|---|---|
| Phase 0 — Clone repo | Student | Cloud Shell |
| Phase 1 — gcloud install | **Skip** (Cloud Shell has it) | — |
| Phase 2 — GCP infra | **You (one time)** | Cloud Shell |
| Phase 3 — Upload USD assets | **You (one time)** | Windows machine |
| Phase 4 — Build inference container | **You (one time)** | Cloud Shell |
| Phase 4b — Pull Kit image | **You (one time)** | Cloud Shell |
| Phase 5 — Deploy Cloud Run | **You (one time)** | Cloud Shell |
| Phase 5b — Start GPU VM + Kit | **You (each session)** | Cloud Shell |
| Phase 5c — Web viewer | **You (each session)** | Cloud Shell |
| Phase 6 — Generate data | Student | Cloud Shell |
| Phase 7 — Quick local train | Student | Cloud Shell (CPU) |
| Phase 8 — Vertex AI training | Student | Cloud Shell → Vertex AI A100 |
| Phase 9 — Inference bridge | Student | Cloud Shell |
| 3D viewer | Student (browser) | GPU VM → browser |

---

## Part 5 — Phase-by-Phase Teaching Notes

### Phase 6 — Synthetic Data (5 min)
- Run `python3 deploy/06_generate_failure_data.py` live in class
- While it runs: explain why we simulate rather than use real data (failures are rare, data is confidential)
- Show the CSV output: `head -5 sensor_timeseries.csv`
- Key concept: 4 failure types × 48 racks × 30 days = realistic but controlled dataset

### Phase 7 — Quick Training (10 min demo)
- Run with `--epochs 5` so it finishes in class
- While it trains: draw the model architecture on the board
  - Input: 12 timesteps × 4 features
  - Transformer encoder: 3 layers, 4 heads, d_model=64
  - Output: 3 probability heads (1h, 6h, 24h failure)
- Show loss curve decreasing — this is the model learning
- Key concept: sliding window prediction, multi-horizon output

### Phase 8 — Vertex AI (20 min, mostly waiting)
- Show students the gcloud console while the job runs: https://console.cloud.google.com/vertex-ai/training/custom-jobs
- Explain what an A100 is and why it trains 10x faster than the CPU demo
- Use the wait time to discuss: what would happen with real sensor data vs. synthetic?

### Phase 9 — Inference Bridge (10 min)
- Run with `--no-kit` first, show the console alerts
- Then run with the full Kit connection and show racks turning red in the browser
- Key concept: this closes the loop — the twin that generated training data now displays the model's output

---

## Part 6 — End of Class Cleanup

**Do this every session to avoid unnecessary charges.**

```bash
# Stop the GPU VM (~$0.40/hr if left running)
gcloud compute instances stop datacenter-kit-vm --zone=us-central1-a

# Cloud Run scales to zero automatically — no action needed
# Vertex AI jobs are billed only while running — no action needed
```

Cloud Run and Vertex AI have no idle costs. Only the GPU VM charges when stopped.

---

## Part 7 — Cost Management

| Resource | Rate | When billed |
|---|---|---|
| GPU VM (g2-standard-8, L4) | ~$0.40/hr | While RUNNING — stop after class |
| Cloud Run | ~$0.00/hr idle | Only when handling requests |
| Vertex AI A100 training | ~$3.00/hr | Only while job runs (~20 min = ~$1) |
| GCS storage (10 GB) | ~$0.20/month | Always |
| Cloud Build | ~$0.30 per build | Per `04_build_and_push.sh` run |

**Per-session cost estimate:** $3.20 (VM × 8 hrs) + $1.00 (A100 × 20 min) = **~$4.50**

Set a billing alert:
```bash
# Alert at $20 total spend — adjust as needed
gcloud billing budgets create \
  --billing-account=$(gcloud beta billing accounts list --format="value(name)" | head -1) \
  --display-name="DC Twin Tutorial Budget" \
  --budget-amount=20 \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9
```

---

## Part 8 — Troubleshooting Reference

| Problem | Cause | Fix |
|---|---|---|
| Student bucket access denied | Email not added | `bash deploy/instructor_grant_access.sh student@gmail.com` |
| `gcloud auth` errors in Cloud Shell | Session expired | Student clicks account icon → re-authenticate |
| Kit container not starting on VM | Docker not configured | Re-run `bash deploy/05b_deploy_kit_vm.sh` |
| Phase 8 fails: `quota exceeded` | A100 quota shared | Only a few students submit at once; stagger submissions |
| Cloud Run returns 503 | Model not loaded | Check `MODEL_GCS_URI` env var and verify `best_model.pt` is in GCS |
| WebRTC viewer blank | Firewall rule missing | Re-run `bash deploy/02_gcp_setup.sh` to recreate firewall rules |
| Phase 8 fails: image not found | `.py310` suffix missing | Image is `pytorch-gpu.2-1.py310:latest` — already set in `08_vertex_training.py` |
| Student Cloud Shell disk full | pip `--user` packages | Student runs `rm -rf ~/.cache ~/.local/lib` |
| Kit viewer freezes | VM under memory pressure | Restart Kit: `gcloud compute ssh datacenter-kit-vm -- docker restart datacenter-kit` |
| Phase 9 bridge `Connection refused` | Kit WebSocket not up yet | Wait 60 seconds after Kit starts, then retry |

### Useful diagnostic commands
```bash
# Check Kit container logs
gcloud compute ssh datacenter-kit-vm --zone=us-central1-a \
  --command="docker logs datacenter-kit --tail 50"

# Check Cloud Run logs
gcloud logging read "resource.type=cloud_run_revision" \
  --project=hmth391 --limit=20

# List Vertex AI training jobs
gcloud ai custom-jobs list --region=us-central1 --project=hmth391

# Check what's in the models bucket
gcloud storage ls gs://hmth391-omniverse-assets/models/

# Verify a student's bucket access
gcloud storage buckets get-iam-policy gs://hmth391-omniverse-assets \
  --format="table(bindings.role, bindings.members)" | grep student@gmail.com
```

---

## Quick Reference Card

```
Project ID         : hmth391
Region / Zone      : us-central1 / us-central1-a
Assets bucket      : gs://hmth391-omniverse-assets
Telemetry bucket   : gs://hmth391-telemetry-ingest
Inference image    : us-central1-docker.pkg.dev/hmth391/world-model-repo/datacenter-inference:latest
Cloud Run service  : datacenter-inference
GPU VM             : datacenter-kit-vm
3D viewer port     : http://VM_IP:8080

Add student        : bash deploy/instructor_grant_access.sh email@gmail.com
Add class roster   : bash deploy/instructor_grant_access.sh --file class_roster.txt
Start GPU VM       : gcloud compute instances start datacenter-kit-vm --zone=us-central1-a
Stop GPU VM        : gcloud compute instances stop datacenter-kit-vm --zone=us-central1-a
Get VM IP          : gcloud compute instances describe datacenter-kit-vm --zone=us-central1-a --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
Health check       : curl $(gcloud run services describe datacenter-inference --region=us-central1 --format="get(status.url)")/health
```
