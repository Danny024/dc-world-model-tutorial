# Data Center Digital Twin → AI World Model on Google Cloud

> **David Mykel Taylor Scholars Program — Atlanta Robotics**
> Build a production-grade AI system from scratch: digital twin → synthetic data → failure prediction → live 3D visualization.

---

## What You Will Build

By the end of this tutorial you will have:

1. A **live 3D digital twin** of an NVIDIA data center, streaming in real time from a Google Cloud GPU VM
2. A **synthetic sensor dataset** generated from failure simulations inside the digital twin
3. A **Temporal Transformer** world model that predicts hardware failures 1 hour, 6 hours, and 24 hours before they happen
4. A **Cloud Run inference service** scoring all 48 racks in real time
5. A **live feedback loop** writing failure probabilities back onto the 3D twin — racks glow red as they approach failure

This is the exact workflow used by AI and robotics teams at NVIDIA, Google, and Amazon. Every step mirrors real production practice.

---

## What is the Data Center Digital Twin?

The digital twin — `DataHall_Full_01.usd` — is a precise 3D replica of a real NVIDIA data center: 48 server racks, DGX A100 units, NVIDIA network switches, and liquid cooling systems, all modeled to physical dimensions. It is the backbone of the entire pipeline and plays **three distinct roles**:

### Role 1 — The Mirror (Visualization)

The USD stage runs on a cloud GPU VM, renders in real time using NVIDIA's Kit engine, and streams the 3D scene to any browser via WebRTC. Students see an exact digital replica of the physical data center — the same view a data center engineer sees on their monitoring dashboard.

```
GPU VM (L4 GPU) renders the 3D scene
        │  WebRTC video stream
        ▼
Your browser tab  ←  no GPU needed on your laptop
```

### Role 2 — The Simulator (Training Data Factory)

Real server failure data is extremely rare (less than 0.1% of operating time), confidential, and prohibitively expensive to label. We instead use the digital twin's rack structure to **simulate** four failure types across all 48 racks over 30 days. This produces the labeled sensor dataset that trains the AI model.

```
48 racks × 30 days × 4 failure types
        │  simulate sensor signatures
        ▼
sensor_timeseries.csv  →  train the Transformer
```

| Failure Type | Sensor Signature |
|---|---|
| Overheating | `temp_c` spikes +25–45°C over 8 timesteps |
| Disk Degradation | `disk_health` drops 40–70% gradually |
| Power Fluctuation | `power_kw` spikes +2–5 kW suddenly |
| Cooling Failure | `temp_c` rises while `disk_health` also degrades |

### Role 3 — The Output Screen (Live Risk Dashboard)

Once the model is trained and deployed, the inference bridge closes the loop. It polls sensor readings, scores every rack against the model, and writes failure probabilities as custom attributes on each rack's USD prim. The 3D twin transforms from a static model into a **live risk map**.

```
Sensor readings → Cloud Run → failure probabilities
                                        │  WebSocket → USD prim attributes
                                        ▼
/World/w_42U_12  datacenter:failureProb_1h  = 0.87  ← rack turns red
/World/w_42U_12  datacenter:alertActive     = True
```

### The Full Loop

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│   Digital Twin (3D layout of 48 racks)                 │
│           │                                             │
│           ▼                                             │
│   Simulate failures on its racks  ←── Phase 6          │
│           │                                             │
│           ▼                                             │
│   Train AI to recognize failure patterns  ←── Phase 7/8│
│           │                                             │
│           ▼                                             │
│   Deploy AI to score real sensor readings  ←── Phase 5 │
│           │                                             │
│           ▼                                             │
│   Write scores back onto the twin  ←── Phase 9         │
│           │                                             │
│           ▼                                             │
│   Digital Twin (live AI-powered risk dashboard)        │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

The digital twin starts as a static 3D model and ends as a live, AI-driven early warning system. That transformation is the core lesson of this tutorial.

---

## System Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  YOUR LAPTOP / CLOUD SHELL  (no GPU required)                        │
│                                                                      │
│  git clone → deploy scripts → Python training scripts                │
│  Browser ◄────────────────── http://VM_IP:8080  (3D viewer)         │
└─────────────────────────────────┬────────────────────────────────────┘
                                  │  gcloud / docker push
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                        GOOGLE CLOUD PLATFORM                         │
│                                                                      │
│  ┌─────────────────────┐    ┌──────────────────────────────────────┐ │
│  │  Cloud Run          │    │  GCS Bucket                          │ │
│  │  (inference API)    │◄───│  ├── DigitalTwin/  (9.6 GB USD)     │ │
│  │  POST /predict/batch│    │  ├── training-data/                  │ │
│  │  → {1h, 6h, 24h}   │    │  │   └── sensor_timeseries.csv       │ │
│  └──────────┬──────────┘    │  └── models/                         │ │
│             │ failure probs │      └── best_model.pt               │ │
│             ▼               └──────────────┬─────────────────────── ┘ │
│  ┌─────────────────────┐                   │                        │
│  │  Inference Bridge   │                   │  gcloud storage cp     │
│  │  (Phase 9)          │                   ▼                        │
│  │  polls CSV / GCS    │    ┌──────────────────────────────────────┐ │
│  │  → Kit WebSocket    │    │  GPU VM  (NVIDIA L4)                 │ │
│  └─────────────────────┘    │  NVIDIA USD Viewer (Kit)             │ │
│                             │  WebRTC :49100  ←→  browser :8080   │ │
│  ┌─────────────────────┐    └──────────────────────────────────────┘ │
│  │  Vertex AI          │                                            │
│  │  Training Job (A100)│                                            │
│  │  → best_model.pt    │                                            │
│  └─────────────────────┘                                            │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Getting Started (Students — Read This First)

### Option A — Google Cloud Shell (recommended, zero install)

Everything you need is pre-installed in Google Cloud Shell. Works on any laptop, Chromebook, or tablet with a browser.

**Step 1** — Open Cloud Shell:
- Go to [shell.cloud.google.com](https://shell.cloud.google.com), **or**
- Click the `>_` icon in the top-right corner of [console.cloud.google.com](https://console.cloud.google.com)

**Step 2** — Clone and run setup:
```bash
git clone https://github.com/Danny024/dc-world-model-tutorial.git
cd dc-world-model-tutorial
bash deploy/student_setup.sh
```

The script detects Cloud Shell automatically: skips gcloud install (already there), skips authentication (already signed in as your Google account), skips the 9.6 GB USD download (lives on the GPU VM — you access it through your browser), and installs Python packages directly.

**Step 3** — Start from Phase 6. Your instructor will give you the GPU VM IP for the 3D viewer.

---

### Option B — Your own laptop (Windows / Mac / Linux)

```bash
git clone https://github.com/Danny024/dc-world-model-tutorial.git
cd dc-world-model-tutorial
bash deploy/student_setup.sh
```

The script will:
1. Install `gcloud` CLI if missing
2. Open a browser to authenticate your Google account
3. Install Python dependencies
4. Confirm you are ready

> **Windows users:** Run in Git Bash (not PowerShell) or use Google Cloud Shell.

---

### If you are the instructor

Upload the assets once, then grant each student read access:

```bash
# Step 1 — Upload your local copy to GCS (run once)
source deploy/config.env
bash deploy/03_upload_assets.sh

# Step 2 — Grant a single student access
bash deploy/instructor_grant_access.sh student@gmail.com

# Step 2 (whole class) — one email per line in a text file
bash deploy/instructor_grant_access.sh --file class_roster.txt

# Step 2 (Google Group) — easiest for 10+ students
bash deploy/instructor_grant_access.sh --group your-class@googlegroups.com
```

> See `INSTRUCTOR_GUIDE.md` for the full pre-class setup checklist and teaching notes.

---

## Prerequisites

### Knowledge You Should Have
- Basic Python (functions, classes, loops)
- Basic Linux command line (`cd`, `ls`, `mkdir`, bash scripts)
- What Docker is (you don't need to be an expert — and you can skip it entirely using Cloud Shell)
- What a neural network is (at the concept level)

### Do You Need a GPU Laptop?

**No.** Every GPU-intensive step runs entirely in the cloud:

| What needs a GPU | Where it runs | You do |
|---|---|---|
| 3D scene rendering + WebRTC | GCP VM with NVIDIA L4 | Open a browser tab |
| World model training | Vertex AI with NVIDIA A100 | Submit a job and wait |
| Live inference | Cloud Run (serverless, CPU) | Send HTTP requests |

Any device with a browser is enough.

### Accounts You Need
| Requirement | Why | Where to Get |
|---|---|---|
| Google account (Gmail OK) | Cloud Shell + GCS bucket access | [gmail.com](https://gmail.com) — free |
| GitHub account | Fork this repo | [github.com](https://github.com) |
| Python 3.10+ | Run training scripts locally (not needed in Cloud Shell) | [python.org](https://python.org) |
| Docker | Build inference container (Phase 4 — not needed in Cloud Shell) | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |

### Estimated Cloud Costs
| Resource | Cost |
|---|---|
| GPU VM (g2-standard-8, L4) — 8 hrs | ~$3.20 |
| GCS storage — 10 GB/month | ~$0.20 |
| Vertex AI A100 training — 2 hrs | ~$6.00 |
| **Total for full tutorial** | **~$10** |

> Stop your VM when not in class: `gcloud compute instances stop datacenter-kit-vm --zone us-central1-a`

---

## Repository Structure

```
dc-world-model-tutorial/
│
├── README.md                    ← You are here
├── INSTRUCTOR_GUIDE.md          ← Full pre-class setup and teaching notes
├── Dockerfile                   ← Cloud Run inference container (Phase 4)
├── Dockerfile.jetson            ← Jetson Nano edge container (Phase 8c)
├── requirements.txt             ← Python dependencies
├── requirements_jetson.txt      ← Jetson-specific dependencies
│
├── deploy/                      ← All scripts — run in phase order
│   │
│   ├── config.env               ← ★ Edit this first (GCP project ID etc.)
│   ├── config.ps1               ← Windows PowerShell equivalent
│   ├── student_setup.sh         ← ★ STUDENTS START HERE
│   ├── instructor_grant_access.sh
│   │
│   ├── 01_install_gcloud.sh     ← Phase 1:  Install gcloud CLI
│   ├── 02_gcp_setup.sh          ← Phase 2:  Create GCP infrastructure
│   ├── 03_upload_assets.sh      ← Phase 3:  Upload USD to GCS (instructor only)
│   ├── 03_upload_assets.ps1     ← Phase 3:  Windows PowerShell version
│   ├── 04_build_and_push.sh     ← Phase 4:  Build & push inference container
│   ├── 04b_pull_kit_image.sh    ← Phase 4b: Pull Kit Streaming image (NGC)
│   ├── 05_deploy_vm.sh          ← Phase 5:  Deploy Cloud Run inference service
│   ├── 05b_deploy_kit_vm.sh     ← Phase 5b: Start Kit on GPU VM (3D viewer)
│   ├── 05c_deploy_web_viewer.sh ← Phase 5c: Serve browser WebRTC client
│   │
│   ├── 06_generate_failure_data.py  ← Phase 6:  Synthetic sensor dataset
│   ├── 07_world_model.py            ← Phase 7:  Temporal Transformer (PyTorch)
│   ├── world_model.py               ←   (importlib shim — do not rename)
│   ├── dino_encoder.py              ← Phase 7b: DINO self-supervised encoder
│   ├── 08_vertex_training.py        ← Phase 8:  Vertex AI training job
│   ├── export_edge.py               ← Phase 8b: Export model to ONNX
│   ├── build_edge_image.sh          ← Phase 8c: Build Jetson ARM64 image
│   ├── build_edge_image.ps1         ← Phase 8c: Windows PowerShell version
│   │
│   ├── inference_server.py          ← Flask REST API for Cloud Run
│   ├── telemetry_ingest.py          ← Live GCS telemetry reader
│   ├── 09_inference_bridge.py       ← Phase 9:  Bridge predictions → USD twin
│   └── 09_inference_config.toml     ← Phase 9:  Thresholds, Kit host, rack mapping
│
└── docs/                        ← Deep-dive reading for each phase
    ├── 01_what_is_a_digital_twin.md
    ├── 02_gcp_concepts.md
    ├── 03_usd_and_omniverse.md
    ├── 04_docker_for_ai.md
    ├── 05_synthetic_data.md
    ├── 06_transformers_for_timeseries.md
    ├── 07_vertex_ai_training.md
    └── 08_inference_pipeline.md
```

---

## Step-by-Step Tutorial

Work through each phase in order. Each phase has:
- A **concept explanation** — understand *why* before you run
- The **exact commands to run**
- A **checkpoint** to verify success before moving on

> **Cloud Shell students:** You already completed Phase 1 — skip straight to Phase 2.

---

### Phase 0 — Fork and Clone

```bash
# 1. Click "Fork" on GitHub (top-right of this page)
# 2. Clone YOUR fork:
git clone https://github.com/YOUR_USERNAME/dc-world-model-tutorial.git
cd dc-world-model-tutorial

# Cloud Shell: the config is already set for this class — no edits needed.
# Own GCP project: open deploy/config.env and set GCP_PROJECT_ID.
```

---

### Phase 1 — Install gcloud CLI

> **Cloud Shell: skip this phase.** gcloud is pre-installed and you are already authenticated.

**Concept:** `gcloud` is Google's command-line tool. Every click in the GCP Console has an equivalent `gcloud` command — this is "infrastructure as code."

```bash
bash deploy/01_install_gcloud.sh

# After install:
gcloud auth login                       # opens browser
gcloud config set project hmth391
gcloud auth application-default login  # for Python SDKs
```

**Checkpoint:** `gcloud --version` prints a version number. ✓

---

### Phase 2 — Create Google Cloud Infrastructure

**Concept:** We provision the building blocks: a storage bucket for assets, a container registry for Docker images, and a GPU VM for 3D rendering.

```bash
source deploy/config.env
bash deploy/02_gcp_setup.sh
```

This script:
1. Enables billing APIs (Compute Engine, Artifact Registry, Vertex AI, Cloud Storage)
2. Creates `gs://hmth391-omniverse-assets/` and `gs://hmth391-telemetry-ingest/`
3. Creates Artifact Registry repos `omniverse-kit` and `world-model-repo`
4. Creates a `g2-standard-8` VM with 1× NVIDIA L4 GPU
5. Opens firewall ports 8011, 8012 (Kit) and 49100–49200 UDP (WebRTC media)

**Checkpoint:** `gcloud compute instances list` shows your VM. ✓

---

### Phase 3 — Upload USD Assets to GCS

**Concept:** The 9.6 GB DataHall USD stage lives on your OneDrive. We upload it once to GCS so the GPU VM can download it at deploy time. **Students do not run this — your instructor already did it.**

```bash
source deploy/config.env
bash deploy/03_upload_assets.sh        # bash / Git Bash / Cloud Shell
# .\deploy\03_upload_assets.ps1        # Windows PowerShell
```

**Checkpoint:**
```bash
gcloud storage ls "gs://hmth391-omniverse-assets/DigitalTwin/" | head -5
```
Shows USD files. ✓

---

### Phase 4 — Build and Push the Inference Container

**Concept:** We package the inference server into a Docker container that Cloud Run will run. The container accepts sensor windows and returns failure probabilities.

```bash
source deploy/config.env
bash deploy/04_build_and_push.sh
```

**Test locally after build:**
```bash
docker run -d -p 8080:8080 --name test-inf datacenter-inference:latest
curl http://localhost:8080/health
# → {"model_loaded": true, "status": "ok"}

curl -X POST http://localhost:8080/predict \
  -H "Content-Type: application/json" \
  -d '{"window": [[23.4,5.82,0.97,0.42],[24.1,5.9,0.96,0.44],[25.0,6.1,0.95,0.51],
       [26.2,6.3,0.94,0.55],[27.8,6.6,0.93,0.60],[29.5,6.9,0.91,0.65],
       [31.2,7.1,0.89,0.70],[33.0,7.4,0.87,0.74],[35.1,7.7,0.84,0.78],
       [37.4,8.0,0.81,0.82],[40.0,8.4,0.77,0.86],[43.2,8.9,0.72,0.90]]}'
# → {"1h": 0.83, "6h": 0.91, "24h": 0.95}

docker stop test-inf && docker rm test-inf
```

**Checkpoint:** `docker images | grep datacenter-inference` shows the image. ✓

---

### Phase 4b — Pull Kit Streaming Image (3D Visualization, optional)

**Concept:** NVIDIA's Kit USD Viewer is on NGC (NVIDIA GPU Cloud). We pull it once and store it in our own Artifact Registry so the GPU VM doesn't need NGC credentials.

**Requires:** Free NGC account → [ngc.nvidia.com](https://ngc.nvidia.com) → Setup → Generate API Key.

```bash
export NGC_API_KEY="your-key-here"
source deploy/config.env
bash deploy/04b_pull_kit_image.sh
```

**Checkpoint:** `docker images | grep usd-viewer` shows the image. ✓

---

### Phase 5 — Deploy Inference Service to Cloud Run

**Concept:** Cloud Run is serverless — you give it a container and it runs at a public HTTPS URL. It scales to zero when idle so you pay nothing between requests.

```bash
source deploy/config.env
bash deploy/05_deploy_vm.sh
```

The script prints your service URL:
```
  Health : https://datacenter-inference-xxxx-uc.a.run.app/health
  Predict: POST https://datacenter-inference-xxxx-uc.a.run.app/predict
```

**Test it:**
```bash
SERVICE_URL=$(gcloud run services describe datacenter-inference \
  --region=us-central1 --format="get(status.url)")
curl "${SERVICE_URL}/health"
# → {"status": "ok", "model_loaded": true}
```

**Checkpoint:** `curl .../health` returns `{"status": "ok"}`. ✓

---

### Phase 5b — Deploy 3D Viewer on GPU VM (optional)

**Concept:** The GPU VM runs the NVIDIA USD Viewer container. It renders the DataHall scene on an L4 GPU and streams it to your browser via WebRTC — no GPU needed on your end.

```bash
bash deploy/05b_deploy_kit_vm.sh    # downloads USD assets to VM, starts Kit
bash deploy/05c_deploy_web_viewer.sh  # builds browser client, serves on :8080
```

Then open in Chrome or Firefox:
```
http://<VM_EXTERNAL_IP>:8080
```

Allow up to 60 seconds for the scene to fully load on first launch.

**Checkpoint:** Browser shows the 3D data center. You can orbit and zoom. ✓

> **Stop the VM when done** (saves ~$0.40/hr):
> ```bash
> gcloud compute instances stop datacenter-kit-vm --zone=us-central1-a
> ```

---

### Phase 6 — Generate Synthetic Failure Data

**Concept:** Real failure events are rare. We use the digital twin's rack structure to simulate 4 failure types across 48 racks over 30 days, producing a labeled dataset.

```bash
python3 deploy/06_generate_failure_data.py
```

Output: `sensor_timeseries.csv` in the current directory (also uploaded to GCS).

Preview:
```
timestamp,rack_id,temp_c,power_kw,disk_health,cpu_load,label
2026-01-01T00:00:00,0,23.4,5.82,0.97,0.42,normal
2026-01-15T08:20:00,12,48.7,7.31,0.91,0.73,overheating
```

**Checkpoint:** `python3 -c "import pandas as pd; df=pd.read_csv('sensor_timeseries.csv'); print(df.shape, df['label'].value_counts())"` shows rows and label distribution. ✓

---

### Phase 7 — Train the World Model (PyTorch)

**Concept:** A **world model** learns to predict how a system evolves over time. Our model takes 12 sensor readings (the last 60 minutes) and outputs the probability of failure in the next 1h, 6h, and 24h.

**Architecture:**
```
Input  (batch, 12 timesteps, 4 features)
  ↓  Linear projection → d_model = 64
  ↓  Positional encoding
  ↓  Transformer Encoder (3 layers, 4 attention heads)
  ↓  Mean pooling across time
  ├─► MLP head → 1h failure probability
  ├─► MLP head → 6h failure probability
  └─► MLP head → 24h failure probability
```

```bash
# Quick demo — 5 epochs on CPU (~2 minutes):
python3 deploy/07_world_model.py --csv sensor_timeseries.csv --epochs 5

# Full training — jump to Phase 8 for a cloud A100 run
```

**Checkpoint:** `model_output/best_model.pt` exists and val_loss decreases across epochs. ✓

---

### Phase 7b — DINO Self-Supervised Encoder (optional, advanced)

**Concept:** DINO is a self-supervised method that learns sensor representations *without labels*. The trained encoder replaces raw 4-feature inputs with richer 64-dimensional embeddings, improving prediction accuracy.

```bash
python3 deploy/dino_encoder.py \
  --csv sensor_timeseries.csv \
  --output-dir model_output/ \
  --epochs 30
```

Then plug the encoder into world model training:
```bash
python3 deploy/07_world_model.py \
  --csv sensor_timeseries.csv \
  --dino-ckpt model_output/dino_encoder.pt \
  --epochs 20
```

---

### Phase 8 — Train on Vertex AI (Cloud A100 GPU)

**Concept:** Instead of waiting hours on your laptop, Vertex AI spins up an A100, trains, saves the model to GCS, and shuts down automatically.

```bash
source deploy/config.env
python3 deploy/08_vertex_training.py
```

This:
1. Packages `07_world_model.py` into a Vertex AI training job
2. Submits the job to an A100 (starts in 2–5 min)
3. After training, deploys the model to a Vertex AI Endpoint
4. Runs a test prediction and prints the endpoint resource name

**Checkpoint:** Script prints `Endpoint resource name: projects/hmth391/endpoints/…` ✓

Copy that endpoint ID into `deploy/09_inference_config.toml`.

---

### Phase 8b — Export to ONNX for Edge Deployment (optional)

```bash
python3 deploy/export_edge.py \
  --model-ckpt model_output/best_model.pt \
  --output-dir model_output/edge/ \
  --gcs-upload
```

Produces `world_model.onnx` optimized for Jetson Nano's TensorRT engine (3–5× faster inference than PyTorch on device).

---

### Phase 9 — Connect Inference to the Digital Twin

**Concept:** This closes the loop. The inference bridge polls sensor data every 60 seconds, scores every rack against Cloud Run, and writes failure probabilities back onto each rack's USD prim via Kit's WebSocket. The 3D twin becomes a live risk dashboard.

```bash
# Dry-run (mock predictions, no Cloud Run needed — great for testing):
python3 deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url https://placeholder \
  --dry-run --no-kit

# Console alerts only (real Cloud Run, no GPU VM needed):
python3 deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url https://YOUR_CLOUD_RUN_URL \
  --no-kit

# Full demo (real predictions + live 3D twin update):
python3 deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url https://YOUR_CLOUD_RUN_URL
```

Watch the 3D viewer — racks that exceed the alert threshold have `datacenter:alertActive = True` set on their USD prim and will glow red in the scene.

**Checkpoint:** Console prints `Rack 12 [1h] 87.3% failure probability` style alerts. ✓

---

## Exercises for Students

### Beginner
1. Change `FAILURE_RATE` in `06_generate_failure_data.py` to `0.10` and retrain. Does the model improve? Why?
2. Add a 5th sensor column (e.g., `fan_rpm`) to the CSV generator and the model input.
3. Lower `alert_1h` in `09_inference_config.toml` to `0.5` and observe which racks trigger alerts.

### Intermediate
4. Replace mean pooling in the Transformer with a `[CLS]` token (like BERT). Does accuracy improve?
5. Add early stopping to the training loop in `07_world_model.py`.
6. Write a script that reads the bridge output and sends a Slack message when `alertActive = True`.

### Advanced
7. Add a Transformer decoder that *generates* predicted future sensor trajectories (a true generative world model).
8. Implement **federated learning**: train separate models per rack, then aggregate weights without sharing raw data.
9. Replace the simulated sensor data with real IPMI readings from a physical server.

---

## Common Errors and Fixes

| Error | Likely Cause | Fix |
|---|---|---|
| `gcloud: command not found` | Phase 1 not done | Use Cloud Shell, or run `bash deploy/01_install_gcloud.sh` |
| `403 Forbidden` on GCS | Not authenticated | `gcloud auth application-default login` |
| `403` on GCS bucket | Not in student access list | Ask instructor: `bash deploy/instructor_grant_access.sh your@email.com` |
| `CUDA out of memory` | Batch size too large | Reduce `BATCH_SIZE` in `07_world_model.py` |
| `docker push denied` | Not authenticated to AR | `gcloud auth configure-docker us-central1-docker.pkg.dev` |
| `docker build` fails on COPY | Running from inside `deploy/` | Run from repo root: `docker build -t datacenter-inference .` |
| `No module named 'world_model'` | Running outside Docker without shim | Run scripts as `python deploy/script.py` from the repo root |
| `Model checkpoint not found` | `best_model.pt` not mounted | Complete Phase 7 first, then mount: `-v $(pwd)/model_output:/app/model_output` |
| `Port 8080 refused` | Web viewer not started | Run `bash deploy/05c_deploy_web_viewer.sh` on the VM |
| `Black screen on port 8080` | Kit still loading | Wait 60 s and refresh; check `docker logs -f datacenter-kit` on the VM |
| `Kit WebSocket refused` | VM not running or Kit not loaded | `gcloud compute instances start datacenter-kit-vm --zone=us-central1-a` |
| `KeyError: AIP_TRAINING_DATA_URI` | Running Vertex script locally | This script is designed for Vertex AI — run `08_vertex_training.py` which submits it |
| `Failed to get crate info` on USD | Assets uploaded with gzip encoding | Re-upload without `-z`, or let `05b_deploy_kit_vm.sh` download to local disk |

---

## Key Concepts Glossary

| Term | What It Means |
|---|---|
| **USD (Universal Scene Description)** | Pixar/NVIDIA's 3D file format — like a Photoshop PSD for 3D scenes, with layers, references, and overrides. |
| **Digital Twin** | A live 3D replica of a physical system, synchronized with real sensor data and updated in real time. |
| **World Model** | A neural network that predicts how a system will evolve — "given the last hour of readings, what happens next?" |
| **Omniverse Kit** | NVIDIA's platform for building apps that render and interact with USD scenes. |
| **WebRTC** | Browser protocol for real-time video streaming (same tech used by Zoom/Google Meet). Used here to stream the 3D viewport. |
| **Transformer Encoder** | Neural network layer using attention — it learns which past timestep matters most for each prediction. |
| **Synthetic Data** | Training data generated by simulation rather than collected from the real world. |
| **Cloud Run** | Google's serverless container platform — runs your Docker image at a public URL, scales to zero when idle. |
| **Vertex AI** | Google's managed ML platform — handles GPU provisioning, distributed training, and model serving. |
| **ONNX** | Open format for neural networks — lets you export a PyTorch model and run it on any hardware (CPU, TensorRT, CoreML). |
| **DINO** | Self-supervised learning method — trains a model to understand data structure without any labels. |
| **Sliding Window** | Taking a fixed-length slice of a time series as model input (e.g., the last 12 sensor readings = 60 minutes). |
| **USD Prim** | A "primitive" — the basic building block of a USD scene. Every rack (`/World/w_42U_01`) is a prim with attributes. |

---

## About This Program

This tutorial was built for the **David Mykel Taylor Scholars Program** at Atlanta Robotics. We build real systems — not toy demos. Every step produces infrastructure that runs at production scale.

For the full instructor setup guide, pre-class checklist, teaching notes, and troubleshooting reference, see [`INSTRUCTOR_GUIDE.md`](INSTRUCTOR_GUIDE.md).

Questions? Open a GitHub Issue on this repository.

---

## License

MIT License — free to use, modify, and share for educational purposes.
