# Google Cloud Platform — Core Concepts

> **Reading time:** 15 minutes
> **Goal:** Understand the GCP services we use and why we chose each one.

---

## The Four Services We Use

| Service | What It Does | Why We Use It |
|---|---|---|
| **Cloud Storage (GCS)** | Object storage (like S3) | Store the 9.6 GB USD stage + training data |
| **Artifact Registry** | Private Docker image registry | Store our built Kit container image |
| **Compute Engine** | Virtual machines | Run the GPU VM with NVIDIA L4 |
| **Vertex AI** | Managed ML training + serving | Train the world model on A100, serve predictions |

---

## GCS — Google Cloud Storage

Think of GCS as a hard drive in the cloud that any machine can access.

Key concepts:
- A **bucket** is like a top-level folder: `gs://my-project-omniverse-assets/`
- **Objects** are files inside the bucket: `gs://my-project-omniverse-assets/Datacenter_NVD@10012/...`
- Data is globally replicated and 99.999999999% durable

We use **GCS Fuse** to mount the bucket as a folder on the VM:
```bash
gcsfuse my-project-omniverse-assets /mnt/assets
# Now /mnt/assets/Datacenter_NVD@10012/... is accessible like a local file
```

This means the Kit app reads the USD from GCS transparently — it doesn't know it's
reading from the cloud.

---

## Artifact Registry — Private Docker Hub

Docker images can be very large (10–50 GB for GPU apps). We can't pull from Docker Hub
on a VM efficiently. Artifact Registry is Google's private registry — images are stored
in the same region as your VM, so pulls are fast (low latency, no egress cost).

```
Registry URL format:
  REGION-docker.pkg.dev/PROJECT_ID/REPO_NAME/IMAGE:TAG
  us-central1-docker.pkg.dev/my-project/omniverse-kit/datacenter-kit:latest
```

---

## Compute Engine — GPU VM

We use `g2-standard-8` which gives us:
- 8 vCPU, 32 GB RAM
- **1× NVIDIA L4 GPU** (24 GB VRAM)
- Perfect for GPU-accelerated rendering (RTX) + WebRTC streaming

The L4 is optimized for inference and professional graphics — cheaper than an A100
but powerful enough for real-time 3D rendering.

**VM startup flow:**
```
1. VM boots Ubuntu 22.04
2. startup-script installs NVIDIA drivers (550 series)
3. startup-script installs NVIDIA Container Toolkit (lets Docker use the GPU)
4. startup-script installs GCS Fuse
5. 05_deploy_vm.sh pulls our container and starts it
6. Kit renders the USD stage, WebRTC stream starts on port 8011
```

### Firewall Rules

A GCP firewall rule controls which network traffic can reach your VM.
We open:
- TCP 8011 — Kit's HTTP server (hosts the WebRTC signaling page)
- TCP 8012 — Kit's WebSocket API
- UDP 49100–49200 — WebRTC media stream (the actual video frames)

---

## Vertex AI — Managed ML Platform

Vertex AI removes the pain of managing training infrastructure.
Instead of renting a GPU VM, installing CUDA, installing PyTorch, configuring storage...
you just say "train this script on an A100" and Vertex AI handles everything.

**Training job lifecycle:**
```
You → Submit job spec → Vertex AI provisions A100 machine
                      → Pulls your training container
                      → Downloads training data from GCS
                      → Runs your training script
                      → Saves model to GCS
                      → Shuts down machine (you stop paying)
```

**Endpoint lifecycle:**
```
You → Deploy model to endpoint
Vertex AI → Provisions serving machine (T4 GPU)
          → Loads your model
          → Exposes HTTPS prediction API
You → Send sensor window → Get failure probability back
```

---

## Cost Management — Important!

### Stop your VM when not using it:
```bash
gcloud compute instances stop datacenter-kit-vm --zone us-central1-a
# Restart when needed:
gcloud compute instances start datacenter-kit-vm --zone us-central1-a
```

### Check your billing:
```bash
gcloud billing accounts list
# Or: console.cloud.google.com/billing
```

### Set a budget alert:
Go to Billing → Budgets & alerts → Create budget → set $20 threshold.
You'll get an email before you overspend.

---

## Discussion Questions

1. Why do we use GCS Fuse instead of downloading the USD file to the VM's local disk?
   (Think: 9.6 GB download time vs. streaming reads as needed)
2. Why is Artifact Registry in the same region as the VM important?
3. What's the difference between a training job and an endpoint in Vertex AI?
   Why do we need both?

---

**Next:** [USD and Omniverse →](03_usd_and_omniverse.md)
