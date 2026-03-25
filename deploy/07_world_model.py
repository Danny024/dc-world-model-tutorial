"""
Phase 7 — World Model: Temporal Transformer for Data Center Failure Prediction
=============================================================================
Architecture:
  - Input : sliding window of T timesteps × F features per rack
             F = 4  (raw sensor)  OR  F = D_DINO = 64  (DINO patch tokens)
  - Encoder: Temporal Transformer (multi-head self-attention over time)
  - Head   : MLP outputting failure probability at 1h / 6h / 24h horizons

Multi-horizon labels (future look-ahead)
-----------------------------------------
  i = index of the LAST OBSERVED timestep (end of the look-back window).
  y["1h"]  = 1 if ANY of the next 12  steps (60 min)  contain a failure.
  y["6h"]  = 1 if ANY of the next 72  steps (6 h)     contain a failure.
  y["24h"] = 1 if ANY of the next 288 steps (24 h)    contain a failure.
  At 5-min intervals: 12=1h, 72=6h, 288=24h.  Strictly future — not current state.

Rack-aware train/val split
---------------------------
  5 of 48 racks are held out for validation.  No sliding-window leakage:
  all windows from a val rack are invisible to the training set.

Usage
-----
    # Train on raw sensor features:
    python deploy/07_world_model.py --csv sensor_timeseries.csv --epochs 20

    # Train with DINO patch-token features (pre-train Phase 7a first):
    python deploy/07_world_model.py --csv sensor_timeseries.csv \\
        --dino-ckpt model_output/dino_encoder.pt --epochs 20
"""

from __future__ import annotations

import argparse
import math
import os
import pathlib
import random as _random
import sys

import numpy as np
import pandas as pd
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader

# Allow running as `python deploy/07_world_model.py` from repo root
sys.path.insert(0, str(pathlib.Path(__file__).parent))

# ── Hyperparameters ───────────────────────────────────────────────────────────
WINDOW_SIZE   = 12          # steps in the look-back window (12 × 5 min = 60 min)
FEATURE_COLS  = ["temp_c", "power_kw", "disk_health", "cpu_load"]
NUM_FEATURES  = len(FEATURE_COLS)    # 4 for raw; 64 when DINO is used
HORIZONS      = {"1h": 12, "6h": 72, "24h": 288}   # future steps per horizon
LABEL_COL     = "label"
BATCH_SIZE    = 256
LR            = 1e-4
D_MODEL       = 64
NHEAD         = 4
NUM_LAYERS    = 3
DIM_FF        = 128
DROPOUT       = 0.1
NUM_CLASSES   = 2           # 0 = normal, 1 = any failure
NUM_RACKS     = 48
VAL_RACKS     = 5           # racks held out for validation

assert HORIZONS == {"1h": 12, "6h": 72, "24h": 288}, \
    "Horizon steps must match 5-min sample interval (12=1h, 72=6h, 288=24h)"


# ── Dataset ───────────────────────────────────────────────────────────────────

class SensorWindowDataset(Dataset):
    """
    Sliding-window dataset over per-rack sensor timeseries.

    Stores windows grouped by rack so the caller can perform a rack-aware
    train/val split without any cross-rack leakage.

    Returns (window_tensor, labels_dict) where labels_dict has keys '1h','6h','24h'.
    """

    def __init__(
        self,
        csv_path:   str,
        window:     int = WINDOW_SIZE,
        dino_enc    = None,   # optional pre-trained DINOEncoder
        dino_device: str = "cpu",
    ):
        df = pd.read_csv(csv_path, parse_dates=["timestamp"])
        df = df.sort_values(["rack_id", "timestamp"]).reset_index(drop=True)
        df["failure"] = (df[LABEL_COL] != "normal").astype(int)

        # samples_by_rack[rack_id] = list of (x_tensor, y_dict)
        self.samples_by_rack: dict[int, list] = {}
        self.samples: list[tuple] = []  # flat list (built after rack loop)

        max_horizon = max(HORIZONS.values())

        for rack_id, grp in df.groupby("rack_id"):
            grp    = grp.reset_index(drop=True)
            feats   = grp[FEATURE_COLS].values.astype(np.float32)
            failure = grp["failure"].values
            n       = len(grp)
            rack_samples = []

            for i in range(window, n - max_horizon):
                raw_win = feats[i - window : i]                   # (W, F)

                # Per-window z-score normalization
                mean = raw_win.mean(axis=0, keepdims=True)
                std  = raw_win.std(axis=0,  keepdims=True) + 1e-8
                norm_win = (raw_win - mean) / std                 # (W, F)

                # Optionally encode with frozen DINO encoder
                if dino_enc is not None:
                    from dino_encoder import encode_window         # noqa: PLC0415
                    x_np = encode_window(dino_enc, norm_win, device=dino_device)
                    # x_np: (W, D_DINO=64)
                else:
                    x_np = norm_win                               # (W, 4)

                # Future failure labels (strictly look-ahead, NOT current state)
                y = {
                    name: int(failure[i : i + h].any())
                    for name, h in HORIZONS.items()
                }

                x_tensor = torch.tensor(x_np, dtype=torch.float32)
                rack_samples.append((x_tensor, y))

            self.samples_by_rack[rack_id] = rack_samples

        # Flat list (used when caller does not need per-rack access)
        for rack_samples in self.samples_by_rack.values():
            self.samples.extend(rack_samples)

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, idx: int):
        x, y = self.samples[idx]
        return x, {k: torch.tensor(v, dtype=torch.long) for k, v in y.items()}


class _ListDataset(Dataset):
    """Wraps a plain list of (x_tensor, y_dict) tuples as a PyTorch Dataset."""

    def __init__(self, samples: list):
        self.samples = samples

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, idx: int):
        x, y = self.samples[idx]
        return x, {k: torch.tensor(v, dtype=torch.long) for k, v in y.items()}


# ── Positional Encoding ───────────────────────────────────────────────────────

class PositionalEncoding(nn.Module):
    def __init__(self, d_model: int, max_len: int = 512, dropout: float = 0.1):
        super().__init__()
        self.dropout = nn.Dropout(dropout)
        pe  = torch.zeros(max_len, d_model)
        pos = torch.arange(max_len).unsqueeze(1).float()
        div = torch.exp(
            torch.arange(0, d_model, 2).float() * (-math.log(10000.0) / d_model)
        )
        pe[:, 0::2] = torch.sin(pos * div)
        pe[:, 1::2] = torch.cos(pos * div)
        self.register_buffer("pe", pe.unsqueeze(0))   # (1, max_len, d_model)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.dropout(x + self.pe[:, : x.size(1)])


# ── Model ─────────────────────────────────────────────────────────────────────

class DataCenterWorldModel(nn.Module):
    """
    Temporal Transformer Encoder → per-horizon MLP heads.

    Input shape : (B, W, F)   — batch × window × features
                  F = 4  (raw sensor features)
                  F = 64 (DINO patch-token features, when --dino-ckpt is given)
    Output      : dict of (B, 2) logits per horizon key ("1h", "6h", "24h")
    """

    def __init__(
        self,
        num_features:    int   = NUM_FEATURES,
        window_size:     int   = WINDOW_SIZE,
        d_model:         int   = D_MODEL,
        nhead:           int   = NHEAD,
        num_layers:      int   = NUM_LAYERS,
        dim_feedforward: int   = DIM_FF,
        dropout:         float = DROPOUT,
        horizons:        dict  = None,
    ):
        super().__init__()
        self.horizons = horizons or HORIZONS

        # Input projection  (F → d_model; handles both 4 and 64 input dims)
        self.input_proj = nn.Linear(num_features, d_model)
        self.pos_enc    = PositionalEncoding(
            d_model, max_len=window_size + 1, dropout=dropout
        )

        enc_layer = nn.TransformerEncoderLayer(
            d_model=d_model,
            nhead=nhead,
            dim_feedforward=dim_feedforward,
            dropout=dropout,
            batch_first=True,
        )
        self.transformer = nn.TransformerEncoder(enc_layer, num_layers=num_layers)

        # Per-horizon MLP heads
        self.heads = nn.ModuleDict({
            name: nn.Sequential(
                nn.Linear(d_model, d_model // 2),
                nn.ReLU(),
                nn.Dropout(dropout),
                nn.Linear(d_model // 2, NUM_CLASSES),
            )
            for name in self.horizons
        })

    def forward(self, x: torch.Tensor) -> dict[str, torch.Tensor]:
        # x: (B, W, F)
        h = self.input_proj(x)          # (B, W, d_model)
        h = self.pos_enc(h)
        h = self.transformer(h)         # (B, W, d_model)
        pooled = h.mean(dim=1)          # (B, d_model) — mean pooling over time
        return {name: head(pooled) for name, head in self.heads.items()}


# ── Training ──────────────────────────────────────────────────────────────────

def train(
    csv_path:    str,
    output_dir:  str = "./model_output",
    epochs:      int = 20,
    batch_size:  int = BATCH_SIZE,
    lr:          float = LR,
    seed:        int = 42,
    dino_ckpt:   str | None = None,
    device:      str | None = None,
):
    # ── Reproducibility ───────────────────────────────────────────────────────
    _random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.deterministic = True

    if device is None:
        device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Training on device: {device}  |  seed={seed}")

    output_dir = pathlib.Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # ── Optional DINO encoder ─────────────────────────────────────────────────
    dino_enc = None
    input_dim = NUM_FEATURES     # 4 for raw; 64 for DINO tokens

    if dino_ckpt:
        from dino_encoder import load_encoder, D_MODEL as D_DINO  # noqa: PLC0415
        print(f"Loading DINO encoder from {dino_ckpt} ...")
        dino_enc = load_encoder(dino_ckpt, device=device)
        dino_enc.eval()
        for p in dino_enc.parameters():
            p.requires_grad = False   # frozen during world-model training
        input_dim = D_DINO           # 64
        print(f"  DINO encoder loaded. Input dim: {input_dim}")

    # ── Data ──────────────────────────────────────────────────────────────────
    print("Building dataset ...")
    dataset = SensorWindowDataset(
        csv_path, dino_enc=dino_enc, dino_device=device
    )

    # Rack-aware train/val split — no sliding-window leakage across racks
    all_rack_ids = sorted(dataset.samples_by_rack.keys())
    rng_split = _random.Random(seed)
    rng_split.shuffle(all_rack_ids)
    val_racks   = set(all_rack_ids[:VAL_RACKS])
    train_racks = set(all_rack_ids[VAL_RACKS:])

    train_samples = [s for r in train_racks for s in dataset.samples_by_rack[r]]
    val_samples   = [s for r in val_racks   for s in dataset.samples_by_rack[r]]

    train_ds = _ListDataset(train_samples)
    val_ds   = _ListDataset(val_samples)

    n_workers = min(4, os.cpu_count() or 1)
    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True,  num_workers=n_workers)
    val_loader   = DataLoader(val_ds,   batch_size=batch_size, shuffle=False, num_workers=n_workers)

    print(f"Train: {len(train_samples):,} samples  ({len(train_racks)} racks)  |  "
          f"Val: {len(val_samples):,} samples  ({len(val_racks)} racks: {sorted(val_racks)})")

    # ── Per-horizon class weights ─────────────────────────────────────────────
    dev = device
    criteria: dict[str, nn.CrossEntropyLoss] = {}
    for name in HORIZONS:
        labels = [s[1][name] for s in dataset.samples]
        n_neg  = sum(1 for l in labels if l == 0)
        n_pos  = sum(1 for l in labels if l == 1)
        n_tot  = n_neg + n_pos
        w_neg  = n_tot / (2 * max(n_neg, 1))
        w_pos  = n_tot / (2 * max(n_pos, 1))
        weights = torch.tensor([w_neg, w_pos], dtype=torch.float32).to(dev)
        criteria[name] = nn.CrossEntropyLoss(weight=weights)
        print(f"  {name:>3s}  pos_rate={100*n_pos/n_tot:.1f}%  "
              f"w_normal={w_neg:.3f}  w_failure={w_pos:.3f}")

    # ── Model ─────────────────────────────────────────────────────────────────
    model     = DataCenterWorldModel(num_features=input_dim).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs)

    best_val_loss = float("inf")

    for epoch in range(1, epochs + 1):
        # Train
        model.train()
        train_loss = 0.0
        for x, y_dict in train_loader:
            x = x.to(device)
            logits = model(x)
            loss   = sum(
                criteria[name](logits[name], y_dict[name].to(device))
                for name in HORIZONS
            )
            optimizer.zero_grad()
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            train_loss += loss.item()
        train_loss /= len(train_loader)

        # Validate
        model.eval()
        val_loss = 0.0
        correct  = {name: 0 for name in HORIZONS}
        total    = 0
        with torch.no_grad():
            for x, y_dict in val_loader:
                x = x.to(device)
                logits = model(x)
                for name in HORIZONS:
                    y = y_dict[name].to(device)
                    val_loss += criteria[name](logits[name], y).item()
                    correct[name] += (logits[name].argmax(1) == y).sum().item()
                total += x.size(0)
        val_loss /= len(val_loader) * len(HORIZONS)
        scheduler.step()

        acc_str = "  ".join(
            f"{n}={100*correct[n]/max(total,1):.1f}%" for n in HORIZONS
        )
        print(f"Epoch {epoch:3d}/{epochs}  "
              f"train={train_loss:.4f}  val={val_loss:.4f}  acc: {acc_str}")

        if val_loss < best_val_loss:
            best_val_loss = val_loss
            ckpt_path = output_dir / "best_model.pt"
            torch.save({
                "epoch":        epoch,
                "state_dict":   model.state_dict(),
                "val_loss":     val_loss,
                "seed":         seed,
                "horizons":     list(HORIZONS.keys()),
                "num_features": input_dim,
                "window_size":  WINDOW_SIZE,
                "feature_cols": FEATURE_COLS,
                "dino_ckpt":    dino_ckpt,
            }, ckpt_path)
            print(f"  -> Saved best model  (val_loss={val_loss:.4f})")

    print(f"\nTraining complete. Best val loss: {best_val_loss:.4f}")
    return str(output_dir / "best_model.pt")


# ── Inference helpers ─────────────────────────────────────────────────────────

def load_model(ckpt_path: str, device: str = "cpu") -> DataCenterWorldModel:
    ckpt      = torch.load(ckpt_path, map_location=device)
    model     = DataCenterWorldModel(
        num_features = ckpt.get("num_features", NUM_FEATURES)
    )
    model.load_state_dict(ckpt["state_dict"])
    model.eval()
    return model.to(device)


def predict(
    model:  DataCenterWorldModel,
    window: np.ndarray,
    device: str = "cpu",
    dino_enc = None,
) -> dict:
    """
    Args:
        window: (WINDOW_SIZE, NUM_FEATURES) raw sensor values, already z-score normalised
        dino_enc: optional loaded DINOEncoder — if provided, window is encoded first

    Returns: {'1h': prob, '6h': prob, '24h': prob}
    """
    if dino_enc is not None:
        from dino_encoder import encode_window  # noqa: PLC0415
        window = encode_window(dino_enc, window, device=device)

    x = torch.tensor(window, dtype=torch.float32).unsqueeze(0).to(device)
    with torch.no_grad():
        logits = model(x)
    return {
        name: torch.softmax(logits[name], dim=-1)[0, 1].item()
        for name in HORIZONS
    }


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train DataCenter World Model")
    parser.add_argument("--csv",        required=True,       help="sensor_timeseries.csv")
    parser.add_argument("--output-dir", default="./model_output")
    parser.add_argument("--epochs",     type=int,   default=20)
    parser.add_argument("--batch-size", type=int,   default=BATCH_SIZE)
    parser.add_argument("--lr",         type=float, default=LR)
    parser.add_argument("--seed",       type=int,   default=42)
    parser.add_argument(
        "--dino-ckpt",
        default=None,
        help="Path to pre-trained DINO encoder checkpoint (model_output/dino_encoder.pt). "
             "When provided, DINO patch tokens replace raw sensor features as model input.",
    )
    args = parser.parse_args()

    train(
        csv_path   = args.csv,
        output_dir = args.output_dir,
        epochs     = args.epochs,
        batch_size = args.batch_size,
        lr         = args.lr,
        seed       = args.seed,
        dino_ckpt  = args.dino_ckpt,
    )
