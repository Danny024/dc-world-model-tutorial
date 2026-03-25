"""
Phase 9 — Inference Bridge: Live Predictions → USD Digital Twin
===============================================================
Closes the loop between the trained World Model and the 3D DataHall viewer.

Data flow every polling cycle:
    1. Read latest 12-step sensor windows from Jetson Nano telemetry
       (gs://hmth391-telemetry-ingest)  OR  a local synthetic CSV.
    2. POST all rack windows in one batch to the Cloud Run /predict/batch endpoint.
    3. Parse failure probabilities per horizon (1h / 6h / 24h).
    4. Print alerts to console for any rack above threshold.
    5. Write probabilities as USD custom attributes on rack prims via
       Kit's built-in WebSocket /script endpoint (no custom extension needed).
       e.g. /World/w_42U_03 gets attribute "datacenter:failureProb_1h" = 0.87

USD prim naming convention (from DataHall_Full_01.usd):
    rack_id = 0  →  /World/w_42U_01
    rack_id = 47 →  /World/w_42U_48

Usage
-----
    # Full pipeline (live GCS telemetry + Kit 3D visualization):
    python deploy/09_inference_bridge.py \\
        --config deploy/09_inference_config.toml \\
        --service-url https://YOUR_CLOUD_RUN_URL

    # Local synthetic CSV (no GCS required):
    python deploy/09_inference_bridge.py \\
        --config deploy/09_inference_config.toml \\
        --csv sensor_timeseries.csv \\
        --service-url https://YOUR_CLOUD_RUN_URL

    # Console-only alerts (no Kit GPU VM required):
    python deploy/09_inference_bridge.py \\
        --config deploy/09_inference_config.toml \\
        --csv sensor_timeseries.csv \\
        --service-url https://YOUR_CLOUD_RUN_URL \\
        --no-kit

    # Dry-run (mock predictions, no Cloud Run calls):
    python deploy/09_inference_bridge.py \\
        --config deploy/09_inference_config.toml \\
        --csv sensor_timeseries.csv \\
        --service-url https://YOUR_CLOUD_RUN_URL \\
        --dry-run
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd                        # top-level import — required by LocalCSVPoller
import requests

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("bridge")


# ── Config loader ─────────────────────────────────────────────────────────────

def load_config(path: str) -> dict:
    """Load 09_inference_config.toml using tomllib (Python 3.11+) or tomli."""
    try:
        import tomllib                           # Python 3.11+
        with open(path, "rb") as f:
            return tomllib.load(f)
    except ImportError:
        import tomli                             # pip install tomli
        with open(path, "rb") as f:
            return tomli.load(f)


# ── Rack prim path helper ─────────────────────────────────────────────────────

def rack_prim_path(rack_id: int, cfg: dict) -> str:
    """
    Convert a numeric rack_id to its USD prim path.
    DataHall_Full_01.usd: rack_id=0 → /World/w_42U_01  (offset by rack_id_offset)
    """
    offset   = cfg["rack_mapping"].get("rack_id_offset", 1)
    template = cfg["rack_mapping"]["prim_path_template"]
    return template.format(rack_num=rack_id + offset)


# ── Local CSV Poller (fallback when GCS telemetry not available) ──────────────

class LocalCSVPoller:
    """
    Reads the most recent WINDOW_SIZE rows per rack from a local CSV.
    Used when live GCS telemetry is not yet available.
    """

    def __init__(self, csv_path: str, window_size: int, feature_cols: list[str]):
        log.info("Loading local CSV: %s", csv_path)
        self.df = (
            pd.read_csv(csv_path, parse_dates=["timestamp"])
            .sort_values(["rack_id", "timestamp"])
        )
        self.window_size  = window_size
        self.feature_cols = feature_cols

    def get_latest_windows(self) -> dict[int, np.ndarray]:
        windows: dict[int, np.ndarray] = {}
        for rack_id, grp in self.df.groupby("rack_id"):
            rows = grp.tail(self.window_size)
            if len(rows) == self.window_size:
                windows[int(rack_id)] = rows[self.feature_cols].values.astype(np.float32)
        return windows


# ── Prediction Client ─────────────────────────────────────────────────────────

class PredictionClient:
    """
    Calls the Cloud Run /predict/batch endpoint.
    Optionally attaches a Google IAM identity token (when auth.enabled=true).
    """

    def __init__(self, service_url: str, use_iam_auth: bool = False):
        self.url          = service_url.rstrip("/")
        self.use_iam_auth = use_iam_auth
        self._session     = requests.Session()

    def _iam_token(self) -> str:
        import google.auth.transport.requests   # noqa: PLC0415
        import google.oauth2.id_token           # noqa: PLC0415
        auth_req = google.auth.transport.requests.Request()
        return google.oauth2.id_token.fetch_id_token(auth_req, self.url)

    def health_check(self) -> bool:
        try:
            resp = self._session.get(f"{self.url}/health", timeout=5)
            return resp.status_code == 200
        except Exception:
            return False

    def predict_batch(
        self,
        windows: dict[int, np.ndarray],
        dry_run: bool = False,
    ) -> dict[int, dict[str, float]]:
        """
        POST /predict/batch with all rack windows in one call.
        Returns {rack_id: {"1h": float, "6h": float, "24h": float}}.
        """
        if not windows:
            return {}

        if dry_run:
            return {
                rid: {
                    "1h":  float(np.random.uniform(0, 0.3)),
                    "6h":  float(np.random.uniform(0, 0.5)),
                    "24h": float(np.random.uniform(0, 0.7)),
                }
                for rid in windows
            }

        rack_ids = list(windows.keys())
        payload  = {"windows": [windows[r].tolist() for r in rack_ids]}
        headers  = {"Content-Type": "application/json"}
        if self.use_iam_auth:
            headers["Authorization"] = f"Bearer {self._iam_token()}"

        resp = self._session.post(
            f"{self.url}/predict/batch",
            json=payload,
            headers=headers,
            timeout=30,
        )
        resp.raise_for_status()
        results = resp.json()   # list in same order as rack_ids
        return {rack_ids[i]: results[i] for i in range(len(rack_ids))}


# ── Kit WebSocket Connector ───────────────────────────────────────────────────

class KitConnector:
    """
    Writes failure probabilities to USD rack prims via Kit's built-in
    WebSocket /script endpoint (available in Kit 104+ — no custom extension needed).
    """

    def __init__(
        self,
        host:              str,
        port:              int,
        failure_attr_pfx:  str  = "datacenter:failureProb",
        enable_alert_attr: bool = True,
    ):
        self.uri               = f"ws://{host}:{port}/script"
        self.failure_attr_pfx  = failure_attr_pfx
        self.enable_alert_attr = enable_alert_attr

    async def write_predictions(
        self,
        predictions: dict[int, dict],
        thresholds:  dict[str, float],
        cfg:         dict,
    ):
        try:
            import websockets                    # noqa: PLC0415
        except ImportError:
            log.warning("websockets not installed — skipping Kit update. "
                        "Run: pip install websockets")
            return

        lines = [
            "import omni.usd",
            "from pxr import Sdf",
            "stage = omni.usd.get_context().get_stage()",
            "updated = 0",
        ]

        for rack_id, probs in predictions.items():
            prim_path    = rack_prim_path(rack_id, cfg)
            alert_active = any(
                probs.get(h, 0) > thresholds.get(f"alert_{h}", 1.0)
                for h in ["1h", "6h", "24h"]
            )
            lines.append(f'prim = stage.GetPrimAtPath("{prim_path}")')
            lines.append("if prim and prim.IsValid():")
            for horizon, prob in probs.items():
                attr = f"{self.failure_attr_pfx}_{horizon}"
                lines.append(
                    f'    prim.CreateAttribute("{attr}", '
                    f'Sdf.ValueTypeNames.Float, custom=True).Set({prob:.6f})'
                )
            if self.enable_alert_attr:
                flag = "True" if alert_active else "False"
                lines.append(
                    f'    prim.CreateAttribute("datacenter:alertActive", '
                    f'Sdf.ValueTypeNames.Bool, custom=True).Set({flag})'
                )
            lines.append("    updated += 1")

        lines.append('print(f"Updated {updated} prims.")')
        script = "\n".join(lines)

        try:
            async with websockets.connect(self.uri, open_timeout=5, close_timeout=3) as ws:
                await ws.send(json.dumps({"script": script}))
                resp = await ws.recv()
                log.debug("Kit response: %s", resp)
        except OSError as exc:
            log.warning("Kit WebSocket unreachable (%s) — USD not updated.", exc)
        except Exception:
            log.warning("Kit WebSocket error — USD not updated.", exc_info=True)


# ── Alert printer ─────────────────────────────────────────────────────────────

def print_alerts(
    predictions: dict[int, dict],
    thresholds:  dict[str, float],
    cycle:       int,
):
    alerts = []
    for rack_id, probs in predictions.items():
        for horizon in ["1h", "6h", "24h"]:
            prob   = probs.get(horizon, 0.0)
            thresh = thresholds.get(f"alert_{horizon}", 1.0)
            if prob > thresh:
                alerts.append((rack_id, horizon, prob))

    if alerts:
        log.warning("─── ALERTS  (cycle %d) ─────────────────────", cycle)
        for rack_id, horizon, prob in sorted(alerts, key=lambda a: -a[2]):
            log.warning("  Rack %2d  [%3s]  %.1f%% failure probability",
                        rack_id, horizon, 100 * prob)
        log.warning("────────────────────────────────────────────")
    else:
        log.info("Cycle %d — %d racks scored — no alerts", cycle, len(predictions))


# ── Main polling loop ─────────────────────────────────────────────────────────

async def run_bridge(
    cfg:         dict,
    service_url: str,
    csv_path:    str | None,
    no_kit:      bool,
    dry_run:     bool,
):
    interval   = cfg["polling"]["interval_seconds"]
    thresholds = cfg["thresholds"]
    window_size = cfg["data"]["window_size"]
    # TOML key is "feature_columns" — use .get() with fallback for safety
    feat_cols  = cfg["data"].get("feature_columns",
                                 ["temp_c", "power_kw", "disk_health", "cpu_load"])
    auth_enabled = cfg.get("auth", {}).get("enabled", False)

    # ── Data source ───────────────────────────────────────────────────────────
    if csv_path:
        poller = LocalCSVPoller(csv_path, window_size, feat_cols)
        log.info("Data source: local CSV (%s)", csv_path)
    else:
        from telemetry_ingest import TelemetryIngestor   # noqa: PLC0415
        # Parse bucket name from the live_sensor_gcs URI: gs://BUCKET/...
        gcs_uri    = cfg["data"]["live_sensor_gcs"]
        gcs_bucket = gcs_uri.removeprefix("gs://").split("/")[0]
        poller = TelemetryIngestor(
            gcs_bucket=gcs_bucket,
            poll_interval_s=interval,
        )
        log.info("Data source: GCS telemetry bucket (%s)", gcs_bucket)

    # ── Prediction client ─────────────────────────────────────────────────────
    predictor = PredictionClient(service_url, use_iam_auth=auth_enabled)
    if not dry_run:
        log.info("Checking Cloud Run health: %s", service_url)
        log.info("  %s", "healthy" if predictor.health_check() else "UNHEALTHY — predictions may fail")

    # ── Kit connector ─────────────────────────────────────────────────────────
    connector = None
    if not no_kit:
        connector = KitConnector(
            host              = cfg["omniverse"]["kit_host"],
            port              = cfg["omniverse"]["kit_port"],
            failure_attr_pfx  = cfg["omniverse"]["failure_attr_prefix"],
            enable_alert_attr = cfg["omniverse"].get("enable_alert_attribute", True),
        )
        log.info("Kit WebSocket target: %s:%d",
                 cfg["omniverse"]["kit_host"], cfg["omniverse"]["kit_port"])

    if dry_run:
        log.info("DRY RUN mode — mock predictions, no Cloud Run calls, no Kit writes.")

    log.info("Bridge started. Polling every %ds.  Press Ctrl+C to stop.", interval)

    cycle = 0
    while True:
        cycle += 1
        t0 = time.monotonic()

        try:
            windows = poller.get_latest_windows()
            if not windows:
                log.info("Cycle %d — no rack windows ready yet.", cycle)
            else:
                predictions = predictor.predict_batch(windows, dry_run=dry_run)
                print_alerts(predictions, thresholds, cycle)
                if connector and predictions:
                    await connector.write_predictions(predictions, thresholds, cfg)
        except KeyboardInterrupt:
            log.info("Bridge stopped by user.")
            break
        except Exception:
            log.exception("Cycle %d failed — will retry next interval.", cycle)

        elapsed = time.monotonic() - t0
        await asyncio.sleep(max(0.0, interval - elapsed))


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))

    parser = argparse.ArgumentParser(
        description="Phase 9 — Inference Bridge: sensor telemetry → predictions → USD"
    )
    parser.add_argument("--config",      default="deploy/09_inference_config.toml")
    parser.add_argument("--service-url", required=True,
                        help="Cloud Run URL, e.g. https://datacenter-inference-xxxx-uc.a.run.app")
    parser.add_argument("--csv",         default=None,
                        help="Local sensor_timeseries.csv (Phase 6 output). "
                             "Omit to use live GCS telemetry.")
    parser.add_argument("--no-kit",      action="store_true",
                        help="Skip Kit WebSocket — console alerts only.")
    parser.add_argument("--dry-run",     action="store_true",
                        help="Mock predictions without calling Cloud Run.")
    args = parser.parse_args()

    asyncio.run(run_bridge(
        cfg         = load_config(args.config),
        service_url = args.service_url,
        csv_path    = args.csv,
        no_kit      = args.no_kit,
        dry_run     = args.dry_run,
    ))
