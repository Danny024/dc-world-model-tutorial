# Student Instructions — Data Center Digital Twin & AI World Model
## Atlanta Robotics — David Mykel Taylor Scholars Program

---

## What You Are Building

You will build a real AI pipeline that:
1. Simulates sensor data from 48 server racks in a data center
2. Trains a neural network to predict hardware failures 1, 6, and 24 hours in advance
3. Deploys the model to Google Cloud
4. Feeds predictions back into a live 3D digital twin — racks glow red as failure risk rises

No GPU on your machine is needed. Everything runs on Google Cloud.

---

## Before You Start

You need **two things** from your instructor before running anything:

1. Your Gmail address must be added to the class roster (your instructor runs one command to do this)
2. The **GPU VM IP address** (written on the board on class day) — you need this for the 3D viewer

If you try to run setup before your instructor adds your email, you will see this error:
```
[ERROR] Cannot access gs://hmth391-omniverse-assets/DigitalTwin
```
Just ask your instructor to run: `bash deploy/instructor_grant_access.sh your@gmail.com`

---

## Tools You Need

Nothing to install. Use **Google Cloud Shell** — a free browser-based terminal with gcloud, Python 3, and Docker pre-installed.

Open it now: **https://shell.cloud.google.com**

Sign in with the same Gmail address you gave your instructor.

---

## Step 0 — Free Up Disk Space (Do This First)

Cloud Shell gives you 5 GB of home storage. Check if you have enough room:

```bash
df -h ~
```

If it shows 90%+ used, clear the cache before doing anything else:

```bash
rm -rf ~/.cache ~/.local/lib
df -h ~
```

You need at least 500 MB free to proceed.

---

## Step 1 — Clone the Repository

```bash
git clone https://github.com/Danny024/dc-world-model-tutorial.git
cd dc-world-model-tutorial
```

---

## Step 2 — Run Student Setup

```bash
bash deploy/student_setup.sh
```

This script will:
- Confirm you are authenticated with Google Cloud
- Verify you have access to the class GCS bucket
- Skip the 9.6 GB USD asset download (it lives on the GPU VM — not your machine)
- Install all Python packages

**Expected output at the end:**
```
╔══════════════════════════════════════════════════════════╗
║              Setup complete! You are ready.              ║
╚══════════════════════════════════════════════════════════╝
```

If you get a bucket access error, tell your instructor — they need to add your email.

---

## Phase 6 — Generate Synthetic Training Data

```bash
python3 deploy/06_generate_failure_data.py
```

This simulates 48 server racks over 30 days at 5-minute intervals.
It creates a file called `sensor_timeseries.csv` (~100,000 rows).

You will see output like:
```
Generating 30 days of sensor data for 48 racks...
Injecting failure scenarios...
Saved: sensor_timeseries.csv  (103,680 rows)
```

Then upload the data to cloud storage:
```bash
source deploy/config.env
gcloud storage cp sensor_timeseries.csv \
  gs://hmth391-omniverse-assets/training-data/sensor_timeseries.csv
```

---

## Phase 7 — Train the Model Locally (Quick Demo)

This runs 5 epochs on CPU so you can see the training loop before sending it to a real GPU.

```bash
python3 deploy/07_world_model.py \
  --csv sensor_timeseries.csv \
  --output-dir ./model_output \
  --epochs 5
```

You will see per-epoch loss and validation accuracy. Takes 3–5 minutes.

Upload the checkpoint to cloud storage:
```bash
source deploy/config.env
gcloud storage cp model_output/best_model.pt \
  gs://hmth391-omniverse-assets/models/best_model.pt
```

---

## Phase 8 — Full Training on Vertex AI A100 GPU

This submits a real training job to an NVIDIA A100 40 GB GPU in Google Cloud.

```bash
source deploy/config.env
python3 deploy/08_vertex_training.py
```

The script:
1. Packages your training code and uploads it to GCS
2. Submits the job to Vertex AI
3. Prints status every 30 seconds while you wait

**This takes 15–20 minutes.** Leave the terminal open. You will see:
```
Submitting Vertex AI custom training job...
Job submitted: projects/.../customJobs/12345
Waiting for training to complete (~15-20 min on A100)...
  JOB_STATE_RUNNING
  JOB_STATE_RUNNING
  ...
  JOB_STATE_SUCCEEDED
Training complete. Model saved to: gs://hmth391-omniverse-assets/models/
```

---

## Phase 9 — Run the Inference Bridge

The inference bridge reads sensor windows, calls the deployed model, and either:
- Prints alerts to the console (safe mode, no 3D viewer needed)
- Writes failure probabilities to the live 3D digital twin (full mode)

### Option A — Console only (no 3D viewer)

```bash
source deploy/config.env

SERVICE_URL=$(gcloud run services describe datacenter-inference \
  --region=us-central1 --project=hmth391 \
  --format="get(status.url)")

python3 deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url "$SERVICE_URL" \
  --no-kit
```

### Option B — Full mode with live 3D viewer

Replace `VM_EXTERNAL_IP` with the IP address your instructor wrote on the board.

```bash
source deploy/config.env

SERVICE_URL=$(gcloud run services describe datacenter-inference \
  --region=us-central1 --project=hmth391 \
  --format="get(status.url)")

# Update kit_host in the config to point to the GPU VM
sed -i 's/kit_host = "localhost"/kit_host = "VM_EXTERNAL_IP"/' \
  deploy/09_inference_config.toml

python3 deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url "$SERVICE_URL"
```

The bridge loops every 60 seconds. You will see alerts like:
```
[ALERT] Rack 07 — 1h failure probability: 0.84  (threshold: 0.70)
[ALERT] Rack 22 — 6h failure probability: 0.61  (threshold: 0.55)
```

---

## Step — Open the 3D Viewer in Your Browser

Open a new browser tab and go to:
```
http://VM_EXTERNAL_IP:8080
```

(Your instructor will write the IP on the board.)

You will see a 3D data center with 48 server racks. As the inference bridge runs, racks approaching failure will glow red.

---

## Full Command Reference (Copy-Paste Cheatsheet)

```bash
# ── Setup ─────────────────────────────────────────────────────────────
git clone https://github.com/Danny024/dc-world-model-tutorial.git
cd dc-world-model-tutorial
bash deploy/student_setup.sh

# ── Phase 6 — Generate data ──────────────────────────────────────────
python3 deploy/06_generate_failure_data.py
source deploy/config.env
gcloud storage cp sensor_timeseries.csv \
  gs://hmth391-omniverse-assets/training-data/sensor_timeseries.csv

# ── Phase 7 — Quick local train ──────────────────────────────────────
python3 deploy/07_world_model.py \
  --csv sensor_timeseries.csv \
  --output-dir ./model_output \
  --epochs 5
source deploy/config.env
gcloud storage cp model_output/best_model.pt \
  gs://hmth391-omniverse-assets/models/best_model.pt

# ── Phase 8 — Vertex AI full train (15-20 min) ───────────────────────
source deploy/config.env
python3 deploy/08_vertex_training.py

# ── Phase 9 — Inference bridge ───────────────────────────────────────
source deploy/config.env
SERVICE_URL=$(gcloud run services describe datacenter-inference \
  --region=us-central1 --project=hmth391 \
  --format="get(status.url)")
python3 deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url "$SERVICE_URL" \
  --no-kit
```

---

## Troubleshooting

| Error | Fix |
|---|---|
| `Cannot access gs://hmth391-omniverse-assets` | Tell your instructor — they need to add your Gmail to the bucket |
| `home disk usage is at 100%` | Run `rm -rf ~/.cache ~/.local/lib && df -h ~` |
| `ModuleNotFoundError: No module named torch` | Run `pip3 install --user torch` |
| Phase 7 runs out of memory | Normal on Cloud Shell (1 GB RAM) — use `--epochs 1` for a smoke test, then go to Phase 8 |
| Phase 8 fails with `quota` error | Tell your instructor — the A100 quota may be shared across students |
| Phase 9 `Connection refused` on Kit port | The 3D viewer is not running yet — use `--no-kit` flag |
| `gcloud: command not found` | You are not in Cloud Shell. Go to https://shell.cloud.google.com |

---

## What Each Phase Teaches You

| Phase | Concept |
|---|---|
| Phase 6 | How to generate labeled synthetic data when real failures are rare |
| Phase 7 | How a Temporal Transformer learns patterns across a 60-minute sensor window |
| Phase 8 | How to submit and monitor cloud GPU training jobs |
| Phase 9 | How to close the loop: predictions feeding back into a live system |

---

## Cost

You pay nothing. All cloud costs are covered by the instructor's GCP project (`hmth391`).
