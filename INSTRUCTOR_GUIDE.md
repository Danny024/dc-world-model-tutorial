# Instructor Guide — Data Center Digital Twin + AI World Model
## David Mykel Taylor Scholars Program

This guide is for you, the instructor. It covers everything a student guide does not:
pre-class setup, GCP account management, what each script actually does under the hood,
known edge cases, cost controls, and the full 9-phase lesson plan with teaching notes.

---

## Table of Contents

1. [Repository Overview](#1-repository-overview)
2. [One-Time Infrastructure Setup](#2-one-time-infrastructure-setup)
3. [Before Each Class Session](#3-before-each-class-session)
4. [Managing Student Access](#4-managing-student-access)
5. [Phase-by-Phase Teaching Guide](#5-phase-by-phase-teaching-guide)
6. [Advanced Phases (8b–9): Edge AI and Live Digital Twin](#6-advanced-phases-8b9-edge-ai-and-live-digital-twin)
7. [Cost Management](#7-cost-management)
8. [Troubleshooting Reference](#8-troubleshooting-reference)
9. [Architecture Deep Dive](#9-architecture-deep-dive)

---

## 1. Repository Overview

### What the Digital Twin Does — Your Opening Explanation

Use this framing when you introduce the project. It answers the first question every student asks: "Why do we need a 3D model if we're doing AI?"

The digital twin plays **three roles** across the nine phases:

**Role 1 — The Mirror (Phases 5b/5c)**
It is a 3D visual replica of a real NVIDIA data center: 48 server racks, DGX A100s, network switches, liquid cooling. It renders on a cloud GPU and streams to any browser. Students see what data center engineers see on their monitoring dashboards.

**Role 2 — The Simulator (Phase 6)**
Real server failure data is rare (<0.1% of time), confidential, and expensive to label. The digital twin's rack layout becomes a factory: we simulate four failure types across all 48 racks over 30 days, producing a fully labeled training dataset. No simulation = no training data = no AI.

**Role 3 — The Output Screen (Phase 9)**
Once the model is trained and deployed, the inference bridge writes failure probabilities back onto each rack's USD prim via Kit's WebSocket. The static 3D model becomes a live risk dashboard — racks approaching failure glow red in the browser.

The full loop: the twin generates the data that trains the model, and the model's output updates the twin. Students see a system that feeds itself.

---

### What this project teaches

Students build a complete production AI pipeline end-to-end:

```
Jetson Nano (edge)                  Google Cloud
──────────────────    telemetry     ──────────────────────────────────────
 Real server sensors ──────────────► GCS telemetry bucket
                                          │
                                          ▼
                                    Inference Bridge
                                     (09_inference_bridge.py)
                                          │  POST /predict/batch
                                          ▼
                                    Cloud Run (inference_server.py)
                                     └── Temporal Transformer (07_world_model.py)
                                          │  failure probs per rack
                                          ▼
                                    Kit WebSocket (/script endpoint)
                                          │  USD prim attribute writes
                                          ▼
                                    GPU VM (NVIDIA USD Viewer)
                                          │  WebRTC
                                          ▼
                                    Student browsers ← 3D racks glow red
```

### What is NEW since the original repo

These files were built or completely rewritten for this class and are not in the
original skeleton. Read these before teaching Phases 7b–9:

| File | What it does |
|---|---|
| `deploy/dino_encoder.py` | Self-supervised DINO encoder for sensor time-series |
| `deploy/telemetry_ingest.py` | Reads live Jetson Nano data from GCS, feeds inference bridge |
| `deploy/09_inference_bridge.py` | Connects Cloud Run predictions to USD rack prims |
| `deploy/export_edge.py` | Exports PyTorch model → ONNX for Jetson TensorRT |
| `deploy/world_model.py` | Importlib shim so `from world_model import ...` works outside Docker |
| `deploy/build_edge_image.sh/.ps1` | Builds ARM64 Docker image for Jetson Nano |
| `Dockerfile.jetson` | Jetson-specific container (l4t-pytorch base + ONNX Runtime GPU) |
| `requirements_jetson.txt` | Jetson dependencies (excludes PyTorch — already in base image) |
| `deploy/config.ps1` | Windows PowerShell equivalent of `config.env` |
| `deploy/03_upload_assets.ps1` | Windows PowerShell equivalent of upload script |

---

## 2. One-Time Infrastructure Setup

Run these steps **once**, before the first class session. They take about 45 minutes.

### 2.1 Clone and configure the repo

```bash
git clone https://github.com/Danny024/dc-world-model-tutorial.git
cd dc-world-model-tutorial

# Open config.env — all values are already set for project hmth391
# Only change these if you use a different GCP project:
nano deploy/config.env
```

Key values in `deploy/config.env` (already configured):

```bash
GCP_PROJECT_ID="hmth391"
GCP_REGION="us-central1"
GCS_BUCKET="hmth391-omniverse-assets"
GCS_TELEMETRY_BUCKET="hmth391-telemetry-ingest"
AR_REPO_KIT="omniverse-kit"
AR_REPO_MODELS="world-model-repo"
USD_ASSETS_LOCAL="/c/Users/danie/OneDrive/Assets/DigitalTwin"
```

> **Windows students** use `deploy/config.ps1` instead of `config.env`.
> The values are identical — only the shell syntax differs.

### 2.2 Authenticate gcloud

```bash
gcloud auth login
gcloud config set project hmth391
gcloud auth application-default login   # needed for Python SDKs
gcloud auth configure-docker us-central1-docker.pkg.dev
```

### 2.3 Run the GCP setup script

```bash
source deploy/config.env
bash deploy/02_gcp_setup.sh
```

This enables all required APIs, creates both GCS buckets, creates both Artifact
Registry repositories, creates the GPU VM (`datacenter-kit-vm`, g2-standard-8, L4),
and opens firewall rules. Runtime: ~5 minutes.

### 2.4 Upload the USD assets

This only needs to run once. The 9.6 GB DataHall asset tree on your OneDrive is
uploaded to `gs://hmth391-omniverse-assets`.

```bash
source deploy/config.env
bash deploy/03_upload_assets.sh

# On Windows PowerShell:
. deploy\config.ps1
.\deploy\03_upload_assets.ps1
```

The script checks for existing files first (idempotent — safe to re-run).
Upload takes 15–30 minutes depending on your connection.

**Verify:**
```bash
gcloud storage ls "gs://hmth391-omniverse-assets/DigitalTwin/" | head -5
```

### 2.5 Pull and re-tag the Kit Streaming image

This requires your NGC API key. Add it to `config.env` first:

```bash
export NGC_API_KEY="your-key-here"
source deploy/config.env
bash deploy/04b_pull_kit_image.sh
```

This pulls `nvcr.io/nvidia/omniverse/usd-viewer:109.0.2` and pushes it to
`us-central1-docker.pkg.dev/hmth391/omniverse-kit/usd-viewer:109.0.2`.
The VM can then pull it without needing NGC credentials.

### 2.6 Build and push the inference container

```bash
source deploy/config.env
bash deploy/04_build_and_push.sh
```

### 2.7 Deploy Cloud Run inference service

```bash
source deploy/config.env
bash deploy/05_deploy_vm.sh
```

Save the Cloud Run URL it prints. You'll give this to students for Phase 9.

### 2.8 Deploy the GPU VM (3D viewer)

```bash
bash deploy/05b_deploy_kit_vm.sh   # runs on the VM, starts Kit
bash deploy/05c_deploy_web_viewer.sh  # serves browser client on :8080
```

The VM external IP is your class demo URL:
```bash
gcloud compute instances describe datacenter-kit-vm \
  --zone=us-central1-a --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
```

---

## 3. Before Each Class Session

Quick 10-minute pre-class checklist:

```bash
# 1. Start the GPU VM (if it was stopped to save costs)
gcloud compute instances start datacenter-kit-vm --zone=us-central1-a

# 2. Wait ~90 seconds, then verify Kit is running
gcloud compute ssh datacenter-kit-vm --zone=us-central1-a \
  --command="docker ps | grep datacenter-kit"

# 3. Verify Cloud Run is healthy
curl https://YOUR_CLOUD_RUN_URL/health
# → {"status": "ok", "model_loaded": true}

# 4. Open the 3D viewer in your browser to confirm it loads
# http://VM_EXTERNAL_IP:8080
```

**At end of class:**
```bash
# Stop the GPU VM (~$0.40/hr if left running)
gcloud compute instances stop datacenter-kit-vm --zone=us-central1-a
```

---

## 4. Managing Student Access

### Recommended student setup: Google Cloud Shell

Tell every student to go to **shell.cloud.google.com** and run:

```bash
git clone https://github.com/Danny024/dc-world-model-tutorial.git
cd dc-world-model-tutorial
bash deploy/student_setup.sh
```

That is the entire setup. Cloud Shell is already authenticated with their Google
account, already has gcloud and Docker installed, and the setup script detects
Cloud Shell and skips the 9.6 GB USD download (which wouldn't fit anyway — Cloud
Shell has 5 GB of persistent home storage). Students access the 3D viewer through
their browser using the GPU VM IP you provide.

Benefits for you:
- No "gcloud install failed" support tickets
- No Windows path issues
- Works on any device with a browser
- Students are authenticated as themselves — GCS IAM controls which bucket they can read

### Grant a student access to the GCS asset bucket

```bash
bash deploy/instructor_grant_access.sh student@gmail.com
```

### Grant access to the whole class at once

Create a file `class_roster.txt` with one email per line:
```
alice@gmail.com
bob@gmail.com
carol@university.edu
```

Then:
```bash
bash deploy/instructor_grant_access.sh --file class_roster.txt
```

### Grant access via Google Group (easiest for large classes)

Create a Google Group at [groups.google.com](https://groups.google.com), add all
student emails, then:
```bash
bash deploy/instructor_grant_access.sh --group your-class@googlegroups.com
```

### What students get access to

- **Read-only** on `gs://hmth391-omniverse-assets` (USD assets + trained models)
- **No write access** — they cannot delete or overwrite anything
- They do NOT get access to `gs://hmth391-telemetry-ingest` by default (Jetson data)

### If a student needs their own GCP project

For advanced students doing the full Phases 8–9 independently, they need their own
GCP project. Walk them through:
1. `gcloud projects create THEIR_PROJECT_ID`
2. Enable billing
3. Edit their `deploy/config.env` with their project ID
4. Run `bash deploy/02_gcp_setup.sh`

---

## 5. Phase-by-Phase Teaching Guide

### Phase 0 — Fork and Clone

**Teaching point:** Explain the difference between the instructor's repo (source of
truth) and a student fork (their personal working copy). Explain why we never commit
directly to the instructor's `main` branch.

**Common issue:** Students on Windows may have `git` from Git Bash but not from
the Windows system PATH. Have them open "Git Bash" specifically, not PowerShell.

---

### Phase 1 — gcloud CLI

> **Cloud Shell students skip this phase entirely.** gcloud is pre-installed and they are
> already authenticated. Tell them to proceed directly to Phase 2.

**Teaching point:** The `gcloud` CLI is a thin client — it just makes REST API calls
to Google Cloud. Any `gcloud` command is equivalent to clicking around in the console.
This is what engineers call "infrastructure as code."

**Windows students:** Direct them to `winget install Google.CloudSDK` or the installer
at `cloud.google.com/sdk`. After install, they must restart their terminal.
Recommend they switch to Google Cloud Shell instead — it eliminates this step entirely.

**Common issue:** `gcloud auth application-default login` vs `gcloud auth login`.
Explain: `auth login` is for `gcloud` CLI commands. `auth application-default login`
is for Python code that calls Google APIs. Students need both.
In Cloud Shell, both are set automatically.

---

### Phase 2 — GCP Infrastructure

**Teaching point:** Walk through `02_gcp_setup.sh` line by line in class. Key concepts:
- **APIs** must be explicitly enabled before use (billing protection)
- **GCS buckets** must have globally unique names — that's why we prefix with the project ID
- **Artifact Registry** is a private container registry (like Docker Hub but yours)
- **Firewall rules** are what allow your laptop to reach the VM — explain the concept of a
  network "port" as a door number on a building

**For the instructor demo:** After the script runs, show the GCP Console UI — let
students see the exact same resources the script created. This makes the CLI-to-UI
connection concrete.

---

### Phase 3 — USD Assets Upload

**Teaching point:** The 9.6 GB DataHall USD is your class asset. Explain:
- USD (Universal Scene Description) is a file format from Pixar, adopted by NVIDIA
- It's like a Photoshop PSD but for 3D scenes — layers, references, overrides
- The DataHall has 48 server racks, each addressable as `/World/w_42U_01` through
  `/World/w_42U_48` in the USD hierarchy

**Students do NOT run Phase 3.** You ran it in one-time setup. Students run
`deploy/student_setup.sh` which downloads from the bucket you already populated.

**Show students the prim hierarchy** using the Kit viewer once it's live:
open the Stage panel and show them `/World/w_42U_01`. This makes Phase 9 click.

---

### Phase 4 — Docker and the Inference Container

**Teaching point:** This is the most important Docker lesson in the course.
Walk through the `Dockerfile` line by line:

```dockerfile
FROM python:3.11-slim          # ← base layer (someone else's work)
RUN pip install torch ...      # ← CPU-only torch (important: ~700 MB not 2 GB)
COPY requirements.txt .        # ← copy the manifest
RUN pip install -r requirements.txt  # ← install everything else
COPY deploy/07_world_model.py ./world_model.py   # ← the model code
COPY deploy/inference_server.py ./inference_server.py
CMD ["python", "inference_server.py"]            # ← what runs on startup
```

**Key teaching moment:** The `COPY deploy/07_world_model.py ./world_model.py` line
renames the file — Python can't import files that start with digits (`07_...`), so
Docker renames it. Outside Docker, `deploy/world_model.py` (the importlib shim) does
the same thing. This is a real-world Python packaging pattern.

**Let every student run this phase themselves.** Building a Docker image is a skill
they must do at least once.

---

### Phase 5 — Cloud Run

**Teaching point:** Cloud Run is "serverless containers." No VM to manage, no SSH,
no `systemctl`. You give it a container image and it handles the rest. It scales to
zero when idle — zero cost when no one is using it.

**Show them the Cloud Run console:** After deploying, open the Cloud Run section in
GCP Console. Show the revision, traffic split, and logs. Click through a live request
in the Logs Explorer. This makes logs real.

**Key concept — IAM and public vs. private services:**
`05_deploy_vm.sh` deploys with `--allow-unauthenticated` so students can call it
without credentials. In production, you'd use a service account. Phase 9 config
has an `[auth]` section for this — mention it but don't require it for the class.

---

### Phase 5b/5c — 3D Viewer (optional but impressive)

**Teaching point:** This is the "wow" phase. Once it loads, students can see the
3D data center in their browser. Walk them through:
- WebRTC is how Zoom/Google Meet stream video — here we use it to stream a 3D scene
- The GPU VM renders the scene on a real NVIDIA L4 GPU
- Their laptop receives compressed video frames — no GPU needed locally

**Classroom tip:** Keep one browser tab on the 3D viewer throughout the later phases.
When Phase 9 runs, students can watch racks turn red in real time.

**Start the VM before class** — it takes ~2 minutes to boot Kit after the VM starts.
Run `05b_deploy_kit_vm.sh` the day before the session and leave the VM running.

---

### Phase 6 — Synthetic Data Generation

**Teaching point:** Real data center failure data is extremely rare (less than 0.1%
of time), confidential, and expensive to label. Synthetic data from simulation is
how robotics and industrial AI teams bootstrap training data.

Walk through the failure simulation code in `06_generate_failure_data.py`. Key points:
- Each failure type has a distinct sensor signature (different features, different rates)
- The `label` column is the "ground truth" we're training toward
- We deliberately simulate failures to create class imbalance in the dataset —
  ask students how they'd handle class imbalance (hint: weighted loss)

**Discussion question:** "What can go wrong when you train only on synthetic data
and deploy on real data?" (distribution shift — a core ML safety concept)

---

### Phase 7 — Temporal Transformer

**Teaching point:** This is the ML core of the course. Teach the following:

1. **Why not LSTM?** LSTMs process tokens sequentially — slow, hard to train.
   Transformers process all timesteps in parallel using attention.

2. **What attention learns here:** Which past sensor reading matters most for
   predicting failure. For overheating, it learns to attend to the temperature
   spike 3 timesteps ago. For disk degradation, it attends to the slow health decline.

3. **Multi-horizon heads:** We predict 1h/6h/24h simultaneously because the
   model shares its understanding of the past — only the "how far ahead?" question
   differs. This is called multi-task learning.

4. **Rack-aware train/val split:** The 5 held-out racks are never seen in training.
   This tests *generalization across racks*, not just temporal generalization.
   A naive random split would leak future data from the same rack — explain why
   this matters.

**Local training works fine for demonstration:**
```bash
python deploy/07_world_model.py --csv /tmp/sensor_timeseries.csv --epochs 5
```
5 epochs takes ~2 minutes on CPU. Use this in class. Send students to Phase 8
for the full 50-epoch A100 run.

---

### Phase 7b — DINO Encoder (advanced, optional)

This is an advanced topic — teach it only if you have time or for advanced students.

**Teaching point:** DINO is a self-supervised learning method from Meta/INRIA.
We adapted it from images to time-series. The key idea:
- A "teacher" network and a "student" network see different augmented versions
  of the same sensor window
- The student tries to match the teacher's output
- The teacher is an exponential moving average of the student — it's more stable
- No labels needed — the model learns structure from unlabeled data

The encoder outputs a 64-dimensional embedding ("representation") of a sensor window.
When plugged into the world model, this embedding replaces the raw 4-feature input —
richer features → better predictions.

**File:** `deploy/dino_encoder.py`
**CLI:**
```bash
python deploy/dino_encoder.py \
  --csv sensor_timeseries.csv \
  --output-dir model_output/ \
  --epochs 30
```

---

### Phase 8 — Vertex AI Training

**Teaching point:** Show the Vertex AI Jobs console during training. Students can
watch GPU utilization live. Key concept: the training code runs on a remote A100 —
students' laptops do nothing after submitting the job.

**Important:** The job creates a `trainer.tar.gz` package that bundles
`world_model.py` alongside `task.py`. This solves the Python-can't-import-digits
problem on the Vertex AI worker node. Explain this packaging pattern.

**After the job completes:**
- Model is saved to `gs://hmth391-omniverse-assets/models/best_model.pt`
- Students copy the endpoint resource name into `09_inference_config.toml`

---

### Phase 9 — Inference Bridge

**Teaching point:** This is the closing-the-loop moment. The inference bridge:
1. Polls sensor data every N seconds (from GCS or a local CSV)
2. POSTs all 48 rack windows to Cloud Run in a single batch call
3. Receives 48 × 3 failure probabilities back
4. Writes them to USD rack prims via Kit's built-in WebSocket

**The Kit WebSocket trick:** Kit exposes a `/script` WebSocket endpoint (Kit 104+)
that executes arbitrary Python inside the running Kit process. We use this to set
USD custom attributes without writing a custom Omniverse extension. This is a
production pattern — no C++ SDK required.

**Demo in class:**
```bash
# Console-only demo (no GPU VM needed):
python deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url https://YOUR_CLOUD_RUN_URL \
  --no-kit

# Full demo (with GPU VM running):
python deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url https://YOUR_CLOUD_RUN_URL
```

Point students to the 3D viewer — they should see rack attributes update in the
Stage panel.

**Dry-run mode (no Cloud Run required):**
```bash
python deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url https://placeholder \
  --dry-run --no-kit
```

Use `--dry-run` when debugging or demoing without the Cloud Run service active.

---

## 6. Advanced Phases (8b–9): Edge AI and Live Digital Twin

These phases cover Jetson Nano edge deployment and real-time telemetry ingestion.
They are optional add-ons for advanced students or a second class session.

### Phase 8b — ONNX Export for Jetson

Exports the trained PyTorch model to ONNX format for edge deployment:

```bash
python deploy/export_edge.py \
  --model-ckpt model_output/best_model.pt \
  --output-dir model_output/edge/ \
  --gcs-upload
```

This creates:
- `model_output/edge/world_model.onnx` — the model in ONNX format
- `model_output/edge/metadata.json` — window_size, features, horizons, registry paths
- Uploads both to `gs://hmth391-omniverse-assets/models/edge/`

**Why ONNX?** TensorRT (on Jetson) can compile ONNX models for the specific Jetson
GPU (Ampere or Maxwell), achieving 3–5× lower latency than native PyTorch.

### Phase 8c — Build Jetson Docker Image

```bash
# One-time: create the ARM64 buildx builder
docker buildx create --name jetson-builder --driver docker-container --use
docker buildx inspect --bootstrap

# Build and push
source deploy/config.env
bash deploy/build_edge_image.sh

# On Windows:
. deploy\config.ps1
.\deploy\build_edge_image.ps1
```

This cross-compiles an ARM64 container on your x86 laptop using Docker buildx QEMU
emulation. It builds `Dockerfile.jetson` and pushes to:
`us-central1-docker.pkg.dev/hmth391/world-model-repo/datacenter-inference:jetson-latest`

**Note:** First build takes 20–40 minutes due to ARM64 emulation. Subsequent builds
with layer caching are much faster.

### Live Telemetry (Phase 9 with GCS)

The `TelemetryIngestor` in `deploy/telemetry_ingest.py` monitors the GCS bucket
`gs://hmth391-telemetry-ingest` for new CSV files from Jetson Nanos.

Each Jetson writes a file like:
```
gs://hmth391-telemetry-ingest/rack_12/2026-03-25T14:30:00.csv
```

The ingestor:
- Scans for files modified in the last 10 minutes
- Parses `timestamp, rack_id, temp_c, power_kw, disk_health, cpu_load`
- Maintains a rolling 288-entry deque per rack (24 hours at 5-min intervals)
- Deduplicates by timestamp
- Returns the most recent 12-step window per rack

To run the bridge with live GCS telemetry (instead of a local CSV), omit `--csv`:
```bash
python deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --service-url https://YOUR_CLOUD_RUN_URL
```

---

## 7. Cost Management

### Active cost centers and how to control them

| Resource | Hourly cost | How to stop |
|---|---|---|
| GPU VM (g2-standard-8, L4) | ~$0.40/hr | `gcloud compute instances stop datacenter-kit-vm --zone=us-central1-a` |
| Cloud Run | $0 when idle | Auto-scales to zero — no action needed |
| Vertex AI training (A100) | ~$3/hr | One-time run per student; delete endpoint after class |
| GCS storage (10 GB) | ~$0.20/month | Leave as-is; cost is negligible |
| Artifact Registry | ~$0.10/month | Leave as-is |

### Instructor-recommended cost controls

1. **Stop the GPU VM after every class session** — it's the only resource with
   meaningful idle cost. Set a calendar reminder.

2. **Delete Vertex AI endpoints after students copy the endpoint ID:**
   ```bash
   gcloud ai endpoints list --region=us-central1
   gcloud ai endpoints delete ENDPOINT_ID --region=us-central1
   ```

3. **Cloud Run scales to zero automatically** — no action needed between sessions.

4. **Estimated total cost for a 4-week course (1 session/week):**
   - GPU VM: 4 sessions × 4 hours = 16 hrs × $0.40 = $6.40
   - Vertex AI training: 1 run per student × $6 = $6 × class_size
   - GCS + AR: ~$1/month
   - **For a 10-student class: ~$75 total**

### Budget alerts

Set a budget alert in the GCP Console (Billing → Budgets & Alerts) at $50 and $100.
This emails you before costs spiral. Project `hmth391` has pre-configured quota for
A100 and L4 — confirm this is still active by checking:

```bash
gcloud compute regions describe us-central1 \
  --format="yaml(quotas)" | grep -A2 "NVIDIA_A100"
```

---

## 8. Troubleshooting Reference

### Student issues (most common)

**"I can't authenticate gcloud"**
- Windows: make sure they ran the installer and restarted the terminal
- Run: `gcloud auth login --no-browser` and paste the URL manually if browser auth fails

**"403 Forbidden when accessing GCS"**
- Run `gcloud auth application-default login` — they probably did `gcloud auth login`
  only, which doesn't set up application-default credentials for Python
- If they're accessing the asset bucket: confirm their email is in the ACL with
  `bash deploy/instructor_grant_access.sh their@email.com`

**"docker build fails: COPY deploy/inference_server.py not found"**
- They're building from inside the `deploy/` directory. The `docker build` command
  must be run from the repo root: `docker build -t datacenter-inference .`

**"ModuleNotFoundError: No module named 'world_model'"**
- They're running `inference_server.py` or `export_edge.py` directly from the
  `deploy/` directory without the importlib shim on their path.
- Fix: always `cd` to the repo root and add `deploy/` to `PYTHONPATH`, or
  run via `python deploy/script.py` from the repo root with
  `sys.path.insert(0, "deploy")` already handled by the shim.

**"Vertex AI training job fails immediately with import error"**
- Usually a `world_model` import error inside the Vertex AI worker.
- Check the job logs: `gcloud ai custom-jobs list --region=us-central1`
- This is fixed in the current `08_vertex_training.py` (world_model.py is bundled
  into the trainer package). If students cloned before this fix, have them pull latest.

**"Kit WebSocket connection refused in Phase 9"**
- The GPU VM is not running or Kit hasn't finished loading (takes ~60 s)
- Check: `gcloud compute ssh datacenter-kit-vm --zone=us-central1-a --command="docker ps"`
- Port 8012 must be open: `gcloud compute firewall-rules list | grep kit`
- Test: `python -c "import websockets, asyncio; asyncio.run(websockets.connect('ws://VM_IP:8012/script'))"`

**"Batch predictions all return 0.0"**
- Model checkpoint is untrained (random weights). Students need to complete Phase 7
  or 8 first. The `--dry-run` flag bypasses this for testing.

**"Black screen at http://VM_IP:8080"**
- Kit is still loading. Wait 60 seconds and refresh.
- If still black after 2 minutes: `gcloud compute ssh datacenter-kit-vm --zone=us-central1-a --command="docker logs --tail=50 datacenter-kit"`
- Look for `[Kit] Application is running` in the logs.

### Infrastructure issues (instructor-level)

**"GPU VM fails to start Kit due to nvidia-smi errors"**
- CDI mode issue. SSH into VM and run:
  ```bash
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
  sudo systemctl stop nvidia-cdi-refresh.service
  sudo systemctl disable nvidia-cdi-refresh.service
  ```

**"02_gcp_setup.sh fails with quota exceeded"**
- L4 or A100 GPU quota is 0 in your project. Contact Nolan Code (the GCP contact
  from the project setup email) — the `hmth391` project should have pre-approved quota.

**"ONNX export fails with opset error"**
- PyTorch and ONNX opset mismatch. Use opset 17 (default) with PyTorch 2.1+.
  Check: `python -c "import torch; print(torch.__version__)"`

---

## 9. Architecture Deep Dive

### Why each technology was chosen

| Technology | Alternative considered | Why we chose this |
|---|---|---|
| NVIDIA USD / Kit | Three.js, Unity | USD is the industry standard for digital twins at NVIDIA, Boeing, Siemens. Kit is the production tool, not a toy. |
| Temporal Transformer | LSTM, GRU | Transformers are the current state-of-the-art for time-series and transfer better to new sensor configurations. |
| Cloud Run | Kubernetes, VM | Zero-ops for students. Scale to zero = zero cost when idle. |
| Vertex AI | SageMaker, local GPU | Native GCP integration, A100 quota available, same CLI as everything else. |
| ONNX / TensorRT | TorchScript, CoreML | ONNX is hardware-agnostic. TensorRT gives Jetson Nano 3–5× speedup over PyTorch. |
| DINO self-supervision | Contrastive (SimCLR), supervised | DINO does not require negative pairs, is stable to train, and the CLS token is a clean representation for downstream tasks. |
| Google Cloud Storage | Local NFS, S3 | GCS is the GCP-native choice, integrates with Vertex AI and Cloud Run without extra auth. |

### Data flow for a single prediction cycle

1. **Sensor collection** (Jetson Nano, every 5 minutes)
   - Temperature, power, disk health, CPU load sampled from IPMI
   - Written as CSV row to `gs://hmth391-telemetry-ingest/rack_N/TIMESTAMP.csv`

2. **Telemetry ingestion** (`telemetry_ingest.py`, running on your laptop or a VM)
   - `TelemetryIngestor` polls GCS every `interval_seconds`
   - Validates schema (must have timestamp, rack_id, 4 sensor columns)
   - Appends to a per-rack rolling deque of 288 entries (24 hours)
   - Returns the 12 most recent rows per rack as a `np.ndarray(12, 4)`

3. **Batch inference** (`09_inference_bridge.py → Cloud Run`)
   - All 48 rack windows packed into one JSON payload: `{"windows": [[[...], ...], ...]}`
   - Single POST to `/predict/batch` — one round-trip for all racks
   - Response: list of `{"1h": float, "6h": float, "24h": float}` dicts

4. **Alert evaluation** (`print_alerts()`)
   - Thresholds from `09_inference_config.toml`: `alert_1h=0.7`, `alert_6h=0.6`, `alert_24h=0.5`
   - Any rack above threshold prints a WARNING-level log line

5. **USD attribute write** (`KitConnector.write_predictions()`)
   - Generates a Python script string that calls `prim.CreateAttribute(...).Set(value)`
   - POSTs the script over WebSocket to `ws://VM_IP:8012/script`
   - Kit executes it inside the live USD stage
   - Rack prims now have `datacenter:failureProb_1h`, `datacenter:failureProb_6h`,
     `datacenter:failureProb_24h`, and `datacenter:alertActive` attributes
   - A Kit extension or material graph reads these attributes to color racks red

### USD prim naming convention

The DataHall_Full_01.usd stage uses this structure:
```
/World/
  w_42U_01    ← rack_id=0 in our model
  w_42U_02    ← rack_id=1
  ...
  w_42U_48    ← rack_id=47
```

The `rack_id_offset = 1` in `09_inference_config.toml` handles the zero-vs-one
difference. The template `/World/w_42U_{rack_num:02d}` formats as `w_42U_01`,
`w_42U_48`, etc.

### The importlib shim pattern

Python cannot import a module whose filename starts with a digit. `07_world_model.py`
violates this rule. Three solutions exist:

| Context | Solution |
|---|---|
| Inside Docker | `COPY deploy/07_world_model.py ./world_model.py` renames the file |
| Local Python (outside Docker) | `deploy/world_model.py` shim loads via `importlib.util` |
| Vertex AI worker | `build_training_package()` copies the file as `trainer/world_model.py` |

The shim (`deploy/world_model.py`) works by registering the loaded module under the
name `world_model` in `sys.modules`, so subsequent `import world_model` calls find it.

---

## Quick Reference Card

### Key environment variables

| Variable | Value | Purpose |
|---|---|---|
| `GCP_PROJECT_ID` | `hmth391` | GCP project for all resources |
| `GCS_BUCKET` | `hmth391-omniverse-assets` | USD assets + trained models |
| `GCS_TELEMETRY_BUCKET` | `hmth391-telemetry-ingest` | Jetson sensor data |
| `AR_REPO_KIT` | `omniverse-kit` | Kit Streaming container images |
| `AR_REPO_MODELS` | `world-model-repo` | Inference + Jetson model images |
| `GCP_REGION` | `us-central1` | All GCP resources in this region |
| `GCP_ZONE` | `us-central1-a` | GPU VM zone |

### Most-used commands during class

```bash
# Start GPU VM
gcloud compute instances start datacenter-kit-vm --zone=us-central1-a

# Stop GPU VM
gcloud compute instances stop datacenter-kit-vm --zone=us-central1-a

# Get VM external IP
gcloud compute instances describe datacenter-kit-vm \
  --zone=us-central1-a --format="get(networkInterfaces[0].accessConfigs[0].natIP)"

# Check Kit logs
gcloud compute ssh datacenter-kit-vm --zone=us-central1-a \
  --command="docker logs --tail=30 datacenter-kit"

# Check Cloud Run health
curl https://YOUR_CLOUD_RUN_URL/health

# Grant a student bucket access
bash deploy/instructor_grant_access.sh student@gmail.com

# Run Phase 9 dry-run demo (no Cloud Run, no Kit needed)
python deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url https://placeholder \
  --dry-run --no-kit
```

### Phase completion checklist

| Phase | Instructor runs once | Students run each |
|---|---|---|
| 0 | Fork repo, set `config.env` | Fork, clone, edit config |
| 1 | Already done | `bash deploy/01_install_gcloud.sh` |
| 2 | `bash deploy/02_gcp_setup.sh` | (optional) own project |
| 3 | `bash deploy/03_upload_assets.sh` | `bash deploy/student_setup.sh` |
| 4 | `bash deploy/04_build_and_push.sh` | Build image locally |
| 4b | `bash deploy/04b_pull_kit_image.sh` | Not required |
| 5 | `bash deploy/05_deploy_vm.sh` | Test with curl |
| 5b/5c | Deploy Kit + viewer on VM | Open browser |
| 6 | — | `python deploy/06_generate_failure_data.py` |
| 7 | — | `python deploy/07_world_model.py` |
| 7b | — | `python deploy/dino_encoder.py` (optional) |
| 8 | — | `python deploy/08_vertex_training.py` |
| 8b/8c | — | `python deploy/export_edge.py` + build_edge_image (optional) |
| 9 | Keep VM + Cloud Run running | `python deploy/09_inference_bridge.py` |
