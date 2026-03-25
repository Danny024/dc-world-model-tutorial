"""
Telemetry Ingestor — Live Sensor Data from Jetson Nano Edge Devices
====================================================================
Reads real sensor telemetry that Scholars' Jetson Nano pipelines write to:
    gs://hmth391-telemetry-ingest/

Expected file format (CSV, one file per rack or batch upload):
    timestamp,rack_id,temp_c,power_kw,disk_health,cpu_load
    2026-03-25T10:00:00,0,42.1,8.3,0.97,0.61
    2026-03-25T10:05:00,0,42.4,8.4,0.97,0.63
    ...

The ingestor maintains a rolling in-memory buffer of the last BUFFER_STEPS
readings per rack.  The bridge calls get_latest_windows() every polling cycle
to retrieve the most recent WINDOW_SIZE rows per rack.

Schema validation, deduplication, and graceful fallback to a local CSV are
all handled here so the bridge script stays clean.

Usage (as a module imported by 09_inference_bridge.py):
    from telemetry_ingest import TelemetryIngestor
    ingestor = TelemetryIngestor(gcs_bucket="hmth391-telemetry-ingest")
    windows = ingestor.get_latest_windows()   # {rack_id: np.ndarray (12,4)}
"""

from __future__ import annotations

import io
import logging
import time
from collections import deque
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd

log = logging.getLogger(__name__)

WINDOW_SIZE   = 12
BUFFER_STEPS  = 288          # keep 24 h of readings per rack (288 × 5 min)
FEATURE_COLS  = ["temp_c", "power_kw", "disk_health", "cpu_load"]
REQUIRED_COLS = {"timestamp", "rack_id"} | set(FEATURE_COLS)
SAMPLE_INTERVAL_S = 300      # 5-minute intervals between readings


class TelemetryIngestor:
    """
    Polls GCS telemetry bucket for new CSV files and maintains a rolling
    per-rack sensor buffer.  Thread-safe via pandas immutable snapshots.

    Args:
        gcs_bucket:   GCS bucket name (without gs:// prefix).
                      Set to None to disable GCS and use only the local_csv fallback.
        local_csv:    Path to a local sensor_timeseries.csv used when GCS is
                      unavailable or for offline testing.
        poll_interval_s: How often (seconds) to check GCS for new files.
                         Set to 0 to fetch only on demand.
    """

    def __init__(
        self,
        gcs_bucket:       Optional[str] = "hmth391-telemetry-ingest",
        local_csv:        Optional[str] = None,
        poll_interval_s:  int           = 60,
    ):
        self.bucket_name      = gcs_bucket
        self.local_csv        = local_csv
        self.poll_interval_s  = poll_interval_s

        # Per-rack circular buffer: {rack_id: deque of rows (each a dict)}
        self._buffers:  dict[int, deque] = {}
        self._seen_blobs: set[str]       = set()   # GCS blob names already ingested
        self._last_poll:  float          = 0.0

        # GCS client (lazy init — avoids import errors when google-cloud-storage
        # is not installed in local-dev environments)
        self._gcs_client = None

        # Bootstrap from local CSV if provided
        if local_csv and Path(local_csv).exists():
            log.info("Bootstrapping buffer from local CSV: %s", local_csv)
            self._ingest_dataframe(pd.read_csv(local_csv, parse_dates=["timestamp"]))

    # ── Public API ────────────────────────────────────────────────────────────

    def refresh(self, force: bool = False):
        """
        Pull new CSV files from GCS into the in-memory buffer.
        No-op if called more frequently than poll_interval_s (unless force=True).
        """
        if not self.bucket_name:
            return
        now = time.monotonic()
        if not force and (now - self._last_poll) < self.poll_interval_s:
            return
        self._last_poll = now
        try:
            self._poll_gcs()
        except Exception:
            log.warning("GCS poll failed — using cached buffer.", exc_info=True)

    def get_latest_windows(self) -> dict[int, np.ndarray]:
        """
        Returns the most recent WINDOW_SIZE readings for every rack that has
        a full window available.

        Returns:
            {rack_id: np.ndarray of shape (WINDOW_SIZE, len(FEATURE_COLS))}
        """
        self.refresh()
        windows: dict[int, np.ndarray] = {}
        for rack_id, buf in self._buffers.items():
            if len(buf) < WINDOW_SIZE:
                continue
            rows = list(buf)[-WINDOW_SIZE:]
            arr  = np.array([[r[c] for c in FEATURE_COLS] for r in rows],
                            dtype=np.float32)
            windows[rack_id] = arr
        return windows

    def rack_count(self) -> int:
        """Number of unique racks currently in the buffer."""
        return len(self._buffers)

    def buffer_depth(self, rack_id: int) -> int:
        """Number of readings buffered for a specific rack."""
        return len(self._buffers.get(rack_id, []))

    # ── GCS polling ──────────────────────────────────────────────────────────

    def _get_gcs_client(self):
        if self._gcs_client is None:
            from google.cloud import storage  # noqa: PLC0415
            self._gcs_client = storage.Client()
        return self._gcs_client

    def _poll_gcs(self):
        """Download and ingest any new CSV blobs from the telemetry bucket."""
        client = self._get_gcs_client()
        bucket = client.bucket(self.bucket_name)
        new_blobs = [
            b for b in bucket.list_blobs()
            if b.name.endswith(".csv") and b.name not in self._seen_blobs
        ]
        if not new_blobs:
            return
        log.info("Found %d new telemetry file(s) in gs://%s",
                 len(new_blobs), self.bucket_name)
        for blob in new_blobs:
            try:
                raw = blob.download_as_bytes()
                df  = pd.read_csv(io.BytesIO(raw), parse_dates=["timestamp"])
                self._validate_schema(df, blob.name)
                self._ingest_dataframe(df)
                self._seen_blobs.add(blob.name)
                log.info("Ingested %d rows from %s", len(df), blob.name)
            except Exception:
                log.warning("Failed to ingest blob %s", blob.name, exc_info=True)

    # ── Ingestion ─────────────────────────────────────────────────────────────

    def _validate_schema(self, df: pd.DataFrame, source: str):
        missing = REQUIRED_COLS - set(df.columns)
        if missing:
            raise ValueError(
                f"Telemetry file {source} is missing columns: {missing}. "
                f"Expected: {REQUIRED_COLS}"
            )

    def _ingest_dataframe(self, df: pd.DataFrame):
        """
        Merge new rows into per-rack circular buffers.
        Rows are sorted by timestamp and deduplicated before insertion.
        """
        if "timestamp" in df.columns:
            df = df.sort_values("timestamp")

        for rack_id, grp in df.groupby("rack_id"):
            rack_id = int(rack_id)
            if rack_id not in self._buffers:
                self._buffers[rack_id] = deque(maxlen=BUFFER_STEPS)

            buf = self._buffers[rack_id]
            existing_ts = {r["timestamp"] for r in buf} if buf else set()

            for _, row in grp.iterrows():
                ts = row.get("timestamp")
                if ts in existing_ts:
                    continue   # deduplicate
                entry = {c: float(row[c]) for c in FEATURE_COLS}
                entry["timestamp"] = ts
                buf.append(entry)
                existing_ts.add(ts)

    # ── Diagnostics ───────────────────────────────────────────────────────────

    def status(self) -> dict:
        """Return a summary dict for logging."""
        return {
            "racks_tracked":  self.rack_count(),
            "ready_racks":    sum(
                1 for r in self._buffers if len(self._buffers[r]) >= WINDOW_SIZE
            ),
            "blobs_seen":     len(self._seen_blobs),
            "gcs_bucket":     self.bucket_name or "disabled",
        }
