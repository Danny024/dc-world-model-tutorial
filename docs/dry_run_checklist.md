# Dry Run Checklist — April 23, 2026
## Codespaces → Jetson Nano Handshake (One Week Before April 30 Workshop)

---

## Goal

Confirm that the Codespaces-to-Nano link works cleanly **before** the day-of workshop,
so there is time to fix any firewall, driver, or model-load issues without
impacting the scholars.

Run the automated check after completing the manual checklist:

```bash
JETSON_IP=<nano-ip> bash deploy/dry_run_handshake.sh
```

---

## Prerequisites (Complete Before April 23)

- [ ] `master_v1.onnx` is in GCS at public URL (see Item 1 below)
- [ ] Pre-compiled `master_v1.trt` is uploaded to GCS (run `compile_trt_engine.sh` on a Nano first)
- [ ] At least one Jetson Nano is powered on and has the inference container running
- [ ] `sensor_timeseries.csv` is available in Codespaces (Phase 6 output)

---

## Jetson Nano Side (Run ON the Nano)

### 1. Verify the inference container is running

```bash
docker ps | grep datacenter-inference
```

Expected: one running container with port `0.0.0.0:8080->8080/tcp`.

If not running, start it:

```bash
docker run -d \
  --runtime nvidia \
  -p 8080:8080 \
  -e MODEL_ONNX_PATH=/opt/models/public/master_v1.onnx \
  -v /opt/models:/opt/models \
  --restart unless-stopped \
  us-central1-docker.pkg.dev/hmth391/world-model-repo/datacenter-inference:jetson-latest
```

### 2. Verify the server is healthy from the Nano itself

```bash
curl -s http://localhost:8080/health
# Expected: {"status": "ok", "model_loaded": true}
```

If `model_loaded` is `false`, the ONNX file path is wrong. Check `MODEL_ONNX_PATH`.

### 3. Get the Nano's IP address

```bash
hostname -I | awk '{print $1}'
```

Share this IP with the Codespaces instructor/student.

### 4. Open port 8080 in the firewall

```bash
sudo ufw allow 8080/tcp
sudo ufw status
```

If `ufw` is inactive, the port is already open. If the Jetson is on a
university or corporate network, contact IT to confirm :8080 is not blocked
at the router level.

### 5. Verify the TRT engine is compiled (optional but recommended)

```bash
ls -lh /opt/models/public/master_v1.trt
```

If missing, compile it now (takes 5–15 min):

```bash
ONNX_PATH=/opt/models/public/master_v1.onnx bash deploy/compile_trt_engine.sh
```

Or pull the pre-compiled engine from GCS:

```bash
gcloud storage cp gs://hmth391-omniverse-assets/models/public/master_v1.trt \
    /opt/models/public/master_v1.trt
```

---

## Codespaces Side (Run IN GitHub Codespaces)

### 1. Clone the repo and install dependencies

```bash
git clone https://github.com/Danny024/dc-world-model-tutorial.git
cd dc-world-model-tutorial
bash deploy/student_setup.sh
```

### 2. Generate sensor data (if not already done)

```bash
python3 deploy/06_generate_failure_data.py
# Output: sensor_timeseries.csv (~25 MB)
```

### 3. Run the automated handshake test

```bash
JETSON_IP=<nano-ip> bash deploy/dry_run_handshake.sh
```

All 5 steps must pass (green `[OK]`) before April 30.

### 4. (If all steps pass) Run the full bridge once to confirm live output

```bash
python3 deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url http://<nano-ip>:8080
```

You should see failure probability alerts printed in the terminal every 60 seconds.

---

## Failure Modes and Fixes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `curl: Connection refused` | Container not running or wrong port | `docker ps`; check port mapping `-p 8080:8080` |
| `curl: Connection timed out` | Campus firewall blocking :8080 outbound | Use SSH tunnel: `ssh -L 8080:localhost:8080 user@<nano-ip>` then use `JETSON_IP=127.0.0.1` |
| `{"status": "ok", "model_loaded": false}` | ONNX file not found at MODEL_ONNX_PATH | Verify path: `docker exec <cid> ls $MODEL_ONNX_PATH` |
| `/predict` returns 500 | Model failed to run inference | Check Docker logs: `docker logs <container-id>` |
| Bridge: `ImportError: No module named ...` | Python deps not installed | `bash deploy/student_setup.sh` |
| Bridge: `ERROR ... service-url` | Trailing slash in URL or HTTP vs HTTPS | Remove trailing slash; Jetson uses `http://` not `https://` |
| `trtexec: Model parse error, opset 17 not supported` | JP4.6 student using JP5 model | Download `master_v1_jp46.onnx` (opset 13) from public GCS |
| `trtexec hangs > 15 min` | Maxwell GPU slow compile | Pull pre-compiled from GCS: `gcloud storage cp gs://.../master_v1.trt ...` |
| Pre-compiled `.trt` fails to load | Engine compiled on different Nano variant | Fall back to ONNX Runtime: set `MODEL_ONNX_PATH` to the `.onnx` file |
| `blob.make_public()` raises BadRequest | Bucket uses uniform IAM access (not fine-grained) | Run: `gsutil acl ch -u AllUsers:R gs://hmth391-omniverse-assets/models/public/master_v1.onnx` |

---

## April 30 Workshop — Final Run Commands

Once the dry run passes on April 23, use these exact commands on April 30:

**Jetson Nano** (instructor starts this before scholars arrive):
```bash
docker run -d \
  --runtime nvidia \
  -p 8080:8080 \
  -e MODEL_ONNX_PATH=/opt/models/public/master_v1.onnx \
  -v /opt/models:/opt/models \
  --restart unless-stopped \
  us-central1-docker.pkg.dev/hmth391/world-model-repo/datacenter-inference:jetson-latest
```

**Each student in Codespaces**:
```bash
python3 deploy/09_inference_bridge.py \
  --config deploy/09_inference_config.toml \
  --csv sensor_timeseries.csv \
  --service-url http://<NANO_IP>:8080
```

The instructor provides `<NANO_IP>` at the start of the session.
