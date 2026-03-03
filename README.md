# Data Center Digital Twin → AI World Model on Google Cloud

> **Atlanta Robotics — College Student Tutorial Series**
> Build a production-grade AI system from scratch: digital twin → synthetic data → failure prediction.

---

## What You Will Build

By the end of this tutorial you will have:

1. A **live 3D digital twin** of an NVIDIA data center, streaming in real time from a Google Cloud GPU VM
2. A **synthetic sensor dataset** generated from failure simulations inside the digital twin
3. A **Temporal Transformer** world model that predicts hardware failures 1 hour, 6 hours, and 24 hours before they happen
4. A **Vertex AI endpoint** serving live failure-probability predictions

This is the exact workflow used by robotics and AI teams at companies like NVIDIA, Google, and Amazon. Every step mirrors real production practice.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                      LOCAL MACHINE (you)                            │
│                                                                     │
│  kit-app-template ──► repo.sh build ──► Docker image               │
│  DataHall_Full_01.usd ──────────────────► GCS bucket               │
└───────────────────────────────┬─────────────────────────────────────┘
                                │  Docker push / gsutil cp
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   GOOGLE CLOUD PLATFORM                             │
│                                                                     │
│  ┌──────────────────────┐     ┌──────────────────────────────────┐  │
│  │   GPU VM (L4)        │     │   GCS Bucket                     │  │
│  │                      │     │   ├── Datacenter_NVD@10012/ (9GB)│  │
│  │  NVIDIA Kit App  ◄───┼─────┤   ├── training-data/            │  │
│  │  (USD Explorer)      │     │   │   └── sensor_timeseries.csv  │  │
│  │  Port 8011 ─► Web   │     │   └── models/                    │  │
│  └──────────────────────┘     │       └── best_model.pt          │  │
│                               └──────────────────────────────────┘  │
│                                           │                         │
│                               ┌───────────▼──────────────────────┐  │
│                               │   Vertex AI                       │  │
│                               │   ├── Training Job (A100)         │  │
│                               │   └── Endpoint (live inference)   │  │
│                               └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │  Failure probability JSON
                                ▼
                     ┌──────────────────┐
                     │ Omniverse Viewer │  Racks glow red when
                     │ (your browser)   │  failure predicted
                     └──────────────────┘
```

---

## Getting the USD Assets (Students — Read This First)

The 9.6 GB NVIDIA Data Center digital twin is provided by your instructor
via a shared Google Cloud Storage bucket. You do **not** need to find or
download it yourself — one script handles everything.

### If you are a student

Your instructor will give you a **bucket name** (looks like `my-project-omniverse-assets`).
Run this single command after cloning the repo:

```bash
GCS_BUCKET=<bucket-name-from-instructor> bash deploy/student_setup.sh
```

That script will:
1. Install `gcloud` CLI if you don't have it
2. Open a browser to authenticate your Google account
3. Download the full 9.6 GB asset tree to `~/datacenter_assets/`
4. Install all Python dependencies
5. Print a checklist confirming you're ready

> **No Google account?** A free Gmail account works. Your instructor just needs
> your email address to grant you read-only access to the bucket.

### If you are the instructor

Upload the assets once, then grant each student read access:

```bash
# Step 1 — Upload your local copy to GCS (run once)
source deploy/config.env
bash deploy/03_upload_assets.sh

# Step 2 — Grant a single student access
bash deploy/instructor_grant_access.sh student@gmail.com

# Step 2 (whole class at once) — put emails in a text file, one per line
bash deploy/instructor_grant_access.sh --file class_roster.txt

# Step 2 (Google Group) — easiest for 10+ students
bash deploy/instructor_grant_access.sh --group your-class@googlegroups.com
```

Students only get **read-only** access — they can download assets but cannot
modify or delete anything in the bucket.

---

## Prerequisites — Read Before You Start

### Knowledge You Should Have
- Basic Python (functions, classes, loops)
- Basic Linux command line (`cd`, `ls`, `mkdir`, bash scripts)
- What Docker is (you don't need to be an expert)
- What a neural network is (at the concept level)

### Hardware / Accounts You Need
| Requirement | Why | Where to Get |
|---|---|---|
| Linux PC with NVIDIA GPU | Training the model fast | Your lab machine |
| Google account (Gmail OK) | Download USD assets from instructor | [gmail.com](https://gmail.com) — it's free |
| Google Cloud account | Deploy + train in the cloud (Phases 4–9) | [console.cloud.google.com](https://console.cloud.google.com) |
| GitHub account | Fork this repo | [github.com](https://github.com) |
| Python 3.10+ | Run training scripts | Usually pre-installed |

### Estimated Cloud Costs
| Resource | Cost |
|---|---|
| GPU VM (g2-standard-8, L4) — 8 hrs | ~$3.20 |
| GCS storage — 10 GB/month | ~$0.20 |
| Vertex AI A100 training — 2 hrs | ~$6.00 |
| **Total for full tutorial** | **~$10** |

> Stop your VM when not using it: `gcloud compute instances stop datacenter-kit-vm --zone us-central1-a`

---

## Repository Structure

```
dc-world-model-tutorial/
│
├── README.md                    ← You are here
│
├── deploy/                      ← All automation scripts (run in order)
│   ├── config.env                    ← Instructor: edit this first
│   ├── student_setup.sh              ← STUDENTS START HERE ← ← ←
│   ├── instructor_grant_access.sh    ← Instructor: grant students bucket access
│   ├── 01_install_gcloud.sh          ← Phase 1: Install Google Cloud CLI
│   ├── 02_gcp_setup.sh               ← Phase 2: Create cloud infrastructure
│   ├── 03_upload_assets.sh           ← Phase 3: Upload USD to GCS (instructor)
│   ├── 04_build_and_push.sh          ← Phase 4: Build Docker image
│   ├── 05_deploy_vm.sh               ← Phase 5: Launch streaming on GPU VM
│   ├── 06_generate_failure_data.py   ← Phase 6: Synthetic dataset
│   ├── 07_world_model.py             ← Phase 7: Transformer model (PyTorch)
│   ├── 08_vertex_training.py         ← Phase 8: Vertex AI training job
│   └── 09_inference_config.toml      ← Phase 9: Connect inference to viewer
│
├── docs/                        ← Deep-dive guides for each phase
│   ├── 01_what_is_a_digital_twin.md
│   ├── 02_gcp_concepts.md
│   ├── 03_usd_and_omniverse.md
│   ├── 04_docker_for_ai.md
│   ├── 05_synthetic_data.md
│   ├── 06_transformers_for_timeseries.md
│   ├── 07_vertex_ai_training.md
│   └── 08_inference_pipeline.md
│
└── assets/
    └── architecture.png         ← System diagram
```

---

## Step-by-Step Tutorial

Work through each phase in order. Each phase has:
- A **concept explanation** (understand *why* before you run)
- The **exact commands to run**
- A **checkpoint** to verify success before moving on

---

### Phase 0 — Fork and Clone This Repo

```bash
# 1. Click "Fork" on GitHub (top-right of this page)
# 2. Clone YOUR fork:
git clone https://github.com/YOUR_USERNAME/dc-world-model-tutorial.git
cd dc-world-model-tutorial

# 3. Edit the configuration file — this is the ONLY file you must change:
nano deploy/config.env
# Replace YOUR_PROJECT_ID with your GCP project ID
```

---

### Phase 1 — Install gcloud CLI

**Concept:** `gcloud` is Google's command-line tool for controlling all cloud services.
You'll use it like a remote control for your cloud resources.

```bash
bash deploy/01_install_gcloud.sh

# After install, authenticate:
gcloud auth login                        # opens browser
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default login   # for Python SDKs
```

**Checkpoint:** `gcloud --version` prints a version number. ✓

---

### Phase 2 — Create Google Cloud Infrastructure

**Concept:** Before deploying anything, we create the cloud resources:
- **GCS Bucket** — like an S3 bucket, stores our 9 GB USD stage + training data
- **Artifact Registry** — private Docker Hub on GCP, stores our container image
- **GPU VM** — a virtual machine with an NVIDIA L4 GPU that runs Kit

```bash
source deploy/config.env
bash deploy/02_gcp_setup.sh
```

What this script does step by step:
1. Enables billing APIs (Compute Engine, Artifact Registry, Vertex AI, Cloud Storage)
2. Creates `gs://YOUR_PROJECT-omniverse-assets/` bucket
3. Creates Docker repository `omniverse-kit` in Artifact Registry
4. Creates a `g2-standard-8` VM with 1× NVIDIA L4 GPU
5. Opens firewall ports 8011, 8012 (Kit HTTP/WebRTC) and 49100–49200 UDP (media)

**Checkpoint:** `gcloud compute instances list` shows your VM with status RUNNING. ✓

---

### Phase 3 — Upload USD Assets to GCS

**Concept:** The DataHall USD stage is 9.6 GB on your local disk.
We upload it to GCS so the GPU VM can access it via GCS Fuse (a filesystem mount that
makes a GCS bucket look like a local folder).

```bash
source deploy/config.env
bash deploy/03_upload_assets.sh
```

> This uses `gsutil -m` which uploads files in parallel — much faster than one at a time.

**Checkpoint:** `gsutil ls gs://YOUR_PROJECT-omniverse-assets/Datacenter_NVD@10012/` shows files. ✓

---

### Phase 4 — Build and Push Docker Container

**Concept:** We package the entire NVIDIA Kit application (USD Explorer + our config)
into a Docker container. This container is self-contained — it runs identically on
your laptop or on a cloud VM with a GPU.

```bash
source deploy/config.env
bash deploy/04_build_and_push.sh
```

This runs:
1. `./repo.sh build` — compiles the Kit extensions
2. `./repo.sh package_container` — wraps everything in a Docker image
3. `docker push` — uploads the image to Artifact Registry

**Checkpoint:** `docker images | grep datacenter-kit` shows the image. ✓

---

### Phase 5 — Deploy to GCP and Launch Streaming

**Concept:** We SSH into the GPU VM, pull the container, and start it.
The container exposes port 8011 which serves a WebRTC stream of the 3D scene —
your browser becomes a remote viewer into the data center digital twin.

```bash
source deploy/config.env
bash deploy/05_deploy_vm.sh
```

After it completes, the script prints a URL like:
```
  http://35.202.X.X:8011
```

Open that URL in Chrome or Firefox — you should see the DataHall 3D scene streaming live.

**Checkpoint:** Browser shows the 3D data center. You can orbit and zoom. ✓

---

### Phase 6 — Generate Synthetic Failure Data

**Concept:** Real failure data from data centers is rare, expensive, and confidential.
Instead, we use the digital twin to *simulate* failures — this is called **synthetic data generation**,
and it's a core technique in robotics and industrial AI.

We simulate 4 failure types over 48 racks × 30 days:
| Failure Type | What Happens to Sensors |
|---|---|
| Overheating | temp_c spikes +25 to +45°C |
| Disk Degradation | disk_health drops -40 to -70% |
| Power Fluctuation | power_kw spikes +2 to +5 kW |
| Cooling Failure | temp_c rises +15 to +35°C, disk health degrades |

```bash
# If running inside Isaac Sim:
./python.sh deploy/06_generate_failure_data.py

# If running standalone (without Isaac Sim):
python3 deploy/06_generate_failure_data.py
```

Output: `gs://YOUR_PROJECT-omniverse-assets/training-data/sensor_timeseries.csv`

Each row looks like:
```
timestamp,rack_id,temp_c,power_kw,disk_health,cpu_load,label
2026-01-01T00:00:00,0,23.4,5.82,0.97,0.42,normal
2026-01-15T08:20:00,12,48.7,7.31,0.91,0.73,overheating
```

**Checkpoint:** `gsutil cat gs://…/training-data/sensor_timeseries.csv | head -5` shows rows. ✓

---

### Phase 7 — Train the World Model (PyTorch)

**Concept:** A **world model** learns to predict what happens next in a system.
Here, our world model learns: given the last 60 minutes of sensor readings for a rack,
what is the probability it will fail in the next 1h / 6h / 24h?

**Architecture:**
```
Input (12 timesteps × 4 features)
      ↓
Linear Projection → d_model=64
      ↓
Positional Encoding (tells the model about time order)
      ↓
Transformer Encoder (3 layers, 4 attention heads)
      ↓  mean pooling over time
Per-horizon MLP Heads:
  → 1h failure probability
  → 6h failure probability
  → 24h failure probability
```

Why a Transformer instead of an LSTM?
- Transformers use **attention** — they learn which past timestep matters most for prediction
- They train faster on GPU and scale better to longer time windows

```bash
# Train locally (takes ~20 min on a good GPU):
python3 deploy/07_world_model.py --csv /tmp/sensor_timeseries.csv --epochs 20

# Or jump straight to Phase 8 to train on an A100 in the cloud
```

**Checkpoint:** Training completes with `best_model.pt` saved and val_loss decreasing. ✓

---

### Phase 8 — Train on Vertex AI (Cloud A100 GPU)

**Concept:** Vertex AI is Google's managed ML platform. Instead of managing GPU servers,
you submit a training job, Vertex AI spins up an A100, trains, and saves the model to GCS.
Then you deploy the model to a **Vertex AI Endpoint** for real-time inference.

```bash
source deploy/config.env
python3 deploy/08_vertex_training.py
```

This does:
1. Packages `07_world_model.py` into a Vertex AI training job
2. Submits the job to an A100 machine (usually starts in 2–5 min)
3. After training, deploys the model to a Vertex AI Endpoint
4. Runs a test prediction

**Checkpoint:** Script prints `Endpoint resource name: projects/…/endpoints/…` ✓

Copy that endpoint ID into `deploy/09_inference_config.toml`.

---

### Phase 9 — Connect Inference to the Digital Twin

**Concept:** The final piece connects the predictions back to the 3D viewer.
The inference config tells a polling service:
- Which Vertex AI endpoint to query
- How often to poll (every 60 seconds)
- What probability threshold triggers an alert
- Which USD prim path corresponds to each rack (so it can highlight failing racks in 3D)

```bash
# Edit deploy/09_inference_config.toml:
# Set endpoint_id = "projects/…/endpoints/…"
nano deploy/09_inference_config.toml
```

When integrated with a running Kit app, failing racks glow red in the 3D viewport
and an alert panel shows: `Rack 12 — 87% failure probability in next 6h`.

---

## Exercises for Students

These are open-ended challenges to deepen your understanding:

### Beginner
1. Change `FAILURE_RATE` in `06_generate_failure_data.py` to `0.10` and retrain. Does the model get better or worse? Why?
2. Add a 5th sensor feature (e.g., `fan_rpm`) to the CSV generator and the model.

### Intermediate
3. Replace mean pooling in the Transformer with a `[CLS]` token (like BERT). Does accuracy improve?
4. Add early stopping to the training loop in `07_world_model.py`.
5. Write a script that reads the live inference predictions and sends a Slack alert when failure probability > 80%.

### Advanced
6. Add a second Transformer decoder that *generates* future sensor trajectories (a true generative world model).
7. Implement **federated learning** so multiple data centers can train a shared model without sharing raw sensor data.
8. Replace the 4-feature input with raw IPMI sensor data from a real server.

---

## Common Errors and Fixes

| Error | Likely Cause | Fix |
|---|---|---|
| `gcloud: command not found` | Phase 1 not complete | Run `bash deploy/01_install_gcloud.sh` |
| `403 Forbidden` on GCS | Not authenticated | Run `gcloud auth application-default login` |
| `CUDA out of memory` | Batch size too large | Reduce `BATCH_SIZE` in `07_world_model.py` |
| `VM not found` | Wrong zone | Check `GCP_ZONE` in `config.env` |
| `docker push denied` | Not authenticated to AR | Run `gcloud auth configure-docker us-central1-docker.pkg.dev` |
| `Port 8011 refused` | VM firewall or Kit not started | Check `docker logs -f datacenter-kit` on the VM |
| `KeyError: AIP_TRAINING_DATA_URI` | Not running inside Vertex AI | This script is for Vertex AI, not local execution |

---

## Key Concepts Glossary

| Term | What It Means |
|---|---|
| **USD (Universal Scene Description)** | NVIDIA/Pixar's 3D file format. Think of it as Photoshop files but for 3D scenes. |
| **Digital Twin** | A live 3D replica of a physical asset, synchronized with real sensor data. |
| **Omniverse Kit** | NVIDIA's platform for building apps that render and interact with USD scenes. |
| **WebRTC** | Web protocol for streaming video in real time (used by Google Meet, Zoom). We use it to stream the 3D viewport. |
| **GCS Fuse** | Mounts a Google Cloud Storage bucket as a Linux filesystem folder. |
| **Transformer Encoder** | Neural network layer that uses attention to relate all timesteps to each other. |
| **World Model** | A neural network that predicts how a system will evolve over time. |
| **Vertex AI** | Google's managed ML platform — handles GPU provisioning, training, and serving. |
| **Synthetic Data** | Data generated by simulation rather than collected from the real world. |
| **Sliding Window** | Taking a fixed-length slice of a timeseries as model input (e.g., last 12 readings). |

---

## About Atlanta Robotics

This tutorial was developed for the **Atlanta Robotics** college student workshop series.
We build real systems — not toy demos. Every step in this tutorial produces something
that runs in production-grade infrastructure.

Questions? Open a GitHub Issue on this repository.

---

## License

MIT License — free to use, modify, and share for educational purposes.
