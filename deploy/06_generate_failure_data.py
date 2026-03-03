#!/usr/bin/env python3
"""
Phase 6 — Synthetic Failure Data Generation via Omniverse Replicator
=====================================================================
Loads DataHall_Full_01.usd, simulates four failure scenarios across
all server racks, and exports a sensor timeseries CSV to GCS.

Run inside Isaac Sim / Omniverse Replicator Python environment:
    ./python.sh deploy/06_generate_failure_data.py

Outputs:
    gs://<bucket>/training-data/sensor_timeseries.csv
"""

import os
import csv
import math
import random
import datetime
import tempfile
import pathlib

# ── Configuration ─────────────────────────────────────────────────────────────
GCS_BUCKET      = os.environ.get("GCS_BUCKET", "YOUR_PROJECT_ID-omniverse-assets")
GCS_OUTPUT_PATH = f"gs://{GCS_BUCKET}/training-data/sensor_timeseries.csv"
USD_STAGE_PATH  = (
    "/mnt/assets/Datacenter_NVD@10012/Assets/DigitalTwin/Assets/Datacenter"
    "/Facilities/Stages/Data_Hall/DataHall_Full_01.usd"
)

# Simulation parameters
NUM_RACKS        = 48          # Number of server racks in the DataHall
SIM_DAYS         = 30          # Days of synthetic history to generate
SAMPLE_INTERVAL  = 300         # Seconds between readings (5 min)
FAILURE_RATE     = 0.04        # Probability any given rack enters a failure window/day

# ── Failure scenario definitions ──────────────────────────────────────────────
FAILURE_SCENARIOS = {
    "overheating": {
        "label": "overheating",
        "temp_delta": (+25, +45),      # °C above baseline
        "power_delta": (+0.5, +1.5),   # kW above baseline
        "disk_delta":  (0.0,  0.0),
        "cpu_delta":   (+0.1, +0.3),
    },
    "disk_degradation": {
        "label": "disk_degradation",
        "temp_delta": (+2,  +8),
        "power_delta": (+0.1, +0.3),
        "disk_delta":  (-0.4, -0.7),   # SMART health fraction drop
        "cpu_delta":   (+0.05, +0.15),
    },
    "power_fluctuation": {
        "label": "power_fluctuation",
        "temp_delta": (+3,  +10),
        "power_delta": (+2.0, +5.0),   # spike
        "disk_delta":  (0.0,  0.0),
        "cpu_delta":   (+0.0, +0.05),
    },
    "cooling_failure": {
        "label": "cooling_failure",
        "temp_delta": (+15, +35),
        "power_delta": (+1.0, +2.5),
        "disk_delta":  (-0.1, -0.3),
        "cpu_delta":   (+0.2, +0.5),
    },
}

# ── Baseline per-rack sensor profiles ─────────────────────────────────────────
def baseline(rack_id: int) -> dict:
    """Return nominal sensor readings for a rack (seeded by rack_id)."""
    rng = random.Random(rack_id * 31337)
    return {
        "temp_c":       rng.uniform(18.0, 28.0),
        "power_kw":     rng.uniform(4.0,  8.0),
        "disk_health":  rng.uniform(0.85, 1.0),
        "cpu_load":     rng.uniform(0.2,  0.6),
    }


def add_noise(value: float, pct: float = 0.03) -> float:
    return value + random.gauss(0, abs(value) * pct)


# ── Omniverse stage loading (runs only inside Isaac Sim) ──────────────────────
def load_stage_if_available():
    try:
        import omni.usd
        import omni.replicator.core as rep

        print(f"Loading USD stage: {USD_STAGE_PATH}")
        omni.usd.get_context().open_stage(USD_STAGE_PATH)
        print("Stage loaded successfully.")
        return True
    except ImportError:
        print("[WARN] omni.usd not available — running in standalone CSV-only mode.")
        return False


# ── Main simulation loop ──────────────────────────────────────────────────────
def simulate() -> list[dict]:
    rows = []
    start_time = datetime.datetime(2026, 1, 1, 0, 0, 0)
    total_steps = int(SIM_DAYS * 86400 / SAMPLE_INTERVAL)

    baselines = {r: baseline(r) for r in range(NUM_RACKS)}

    # Pre-assign failure windows per rack
    failure_windows: dict[int, list[tuple]] = {r: [] for r in range(NUM_RACKS)}
    rng = random.Random(42)
    for rack_id in range(NUM_RACKS):
        for day in range(SIM_DAYS):
            if rng.random() < FAILURE_RATE:
                scenario_name = rng.choice(list(FAILURE_SCENARIOS.keys()))
                scenario      = FAILURE_SCENARIOS[scenario_name]
                # Failure window: 2–8 hours
                duration_steps = rng.randint(
                    int(2 * 3600 / SAMPLE_INTERVAL),
                    int(8 * 3600 / SAMPLE_INTERVAL),
                )
                day_start_step = int(day * 86400 / SAMPLE_INTERVAL)
                onset_step     = day_start_step + rng.randint(0, int(86400 / SAMPLE_INTERVAL) - 1)
                failure_windows[rack_id].append(
                    (onset_step, onset_step + duration_steps, scenario)
                )

    print(f"Simulating {NUM_RACKS} racks × {total_steps} steps "
          f"({SIM_DAYS} days at {SAMPLE_INTERVAL}s interval)...")

    for step in range(total_steps):
        ts = start_time + datetime.timedelta(seconds=step * SAMPLE_INTERVAL)
        ts_str = ts.isoformat()

        for rack_id in range(NUM_RACKS):
            b = baselines[rack_id]
            temp     = b["temp_c"]
            power    = b["power_kw"]
            disk     = b["disk_health"]
            cpu      = b["cpu_load"]
            label    = "normal"

            # Check if inside a failure window
            for (onset, end, scenario) in failure_windows[rack_id]:
                if onset <= step < end:
                    progress = (step - onset) / max(end - onset, 1)  # 0→1
                    ramp     = math.sin(progress * math.pi)           # bell ramp

                    td_lo, td_hi = scenario["temp_delta"]
                    pd_lo, pd_hi = scenario["power_delta"]
                    dd_lo, dd_hi = scenario["disk_delta"]
                    cd_lo, cd_hi = scenario["cpu_delta"]

                    temp  += ramp * rng.uniform(td_lo, td_hi)
                    power += ramp * rng.uniform(pd_lo, pd_hi)
                    disk  += ramp * rng.uniform(dd_lo, dd_hi)
                    cpu   += ramp * rng.uniform(cd_lo, cd_hi)
                    label  = scenario["label"]
                    break

            # Add measurement noise
            temp  = max(0.0,  add_noise(temp))
            power = max(0.0,  add_noise(power))
            disk  = max(0.0,  min(1.0, add_noise(disk)))
            cpu   = max(0.0,  min(1.0, add_noise(cpu)))

            rows.append({
                "timestamp":   ts_str,
                "rack_id":     rack_id,
                "temp_c":      round(temp,  2),
                "power_kw":    round(power, 3),
                "disk_health": round(disk,  4),
                "cpu_load":    round(cpu,   4),
                "label":       label,
            })

    print(f"Generated {len(rows):,} rows.")
    return rows


# ── CSV export ────────────────────────────────────────────────────────────────
def save_csv(rows: list[dict], path: str):
    fieldnames = ["timestamp", "rack_id", "temp_c", "power_kw",
                  "disk_health", "cpu_load", "label"]
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"CSV saved: {path}")


def upload_to_gcs(local_path: str, gcs_path: str):
    import subprocess
    print(f"Uploading to {gcs_path}...")
    subprocess.run(["gsutil", "cp", local_path, gcs_path], check=True)
    print("Upload complete.")


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    load_stage_if_available()

    rows = simulate()

    # Save locally first, then upload
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".csv", delete=False, prefix="sensor_timeseries_"
    ) as tmp:
        local_csv = tmp.name

    save_csv(rows, local_csv)

    try:
        upload_to_gcs(local_csv, GCS_OUTPUT_PATH)
    except Exception as e:
        print(f"[WARN] GCS upload failed: {e}")
        fallback = pathlib.Path.home() / "sensor_timeseries.csv"
        import shutil
        shutil.copy(local_csv, fallback)
        print(f"Data saved locally to: {fallback}")
    finally:
        os.unlink(local_csv)

    print("\nDone. Label distribution:")
    from collections import Counter
    counts = Counter(r["label"] for r in rows)
    for label, count in sorted(counts.items()):
        print(f"  {label:20s}: {count:>8,}  ({100*count/len(rows):.1f}%)")
