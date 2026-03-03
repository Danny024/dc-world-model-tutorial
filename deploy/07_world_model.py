"""
Phase 7 — World Model: Temporal Transformer for Data Center Failure Prediction
=============================================================================
Architecture:
  - Input : sliding window of T timesteps × F sensor features per rack
  - Encoder: Temporal Transformer (multi-head self-attention over time)
  - Head   : MLP outputting failure probability at 1h / 6h / 24h horizons

Usage:
    # Train locally (expects sensor_timeseries.csv)
    python deploy/07_world_model.py --csv sensor_timeseries.csv --epochs 20

    # Vertex AI calls this as a module; entry point is train()
"""

from __future__ import annotations

import argparse
import math
import os
import pathlib

import numpy as np
import pandas as pd
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader

# ── Hyperparameters ───────────────────────────────────────────────────────────
WINDOW_SIZE   = 12          # steps in the look-back window (12 × 5 min = 60 min)
FEATURE_COLS  = ["temp_c", "power_kw", "disk_health", "cpu_load"]
NUM_FEATURES  = len(FEATURE_COLS)
HORIZONS      = {"1h": 12, "6h": 72, "24h": 288}   # steps ahead
LABEL_COL     = "label"
BATCH_SIZE    = 256
LR            = 1e-4
D_MODEL       = 64
NHEAD         = 4
NUM_LAYERS    = 3
DIM_FF        = 128
DROPOUT       = 0.1
NUM_CLASSES   = 2           # 0 = normal, 1 = any failure

# ── Dataset ───────────────────────────────────────────────────────────────────

class SensorWindowDataset(Dataset):
    """
    Sliding-window dataset over per-rack sensor timeseries.
    Returns (window, labels_dict) where labels_dict has keys '1h', '6h', '24h'.
    """

    def __init__(self, csv_path: str, window: int = WINDOW_SIZE):
        df = pd.read_csv(csv_path, parse_dates=["timestamp"])
        df = df.sort_values(["rack_id", "timestamp"]).reset_index(drop=True)

        # Binary label: 1 if any failure
        df["failure"] = (df[LABEL_COL] != "normal").astype(int)

        self.samples: list[tuple] = []

        for rack_id, grp in df.groupby("rack_id"):
            grp = grp.reset_index(drop=True)
            feats   = grp[FEATURE_COLS].values.astype(np.float32)
            failure = grp["failure"].values

            n = len(grp)
            max_horizon = max(HORIZONS.values())

            for i in range(window, n - max_horizon):
                x = feats[i - window : i]                          # (W, F)

                # Future failure label for each horizon
                y = {}
                for name, h in HORIZONS.items():
                    y[name] = int(failure[i : i + h].any())

                # Normalise features (z-score computed per-window)
                mean = x.mean(axis=0, keepdims=True)
                std  = x.std(axis=0, keepdims=True) + 1e-8
                x    = (x - mean) / std

                self.samples.append((x, y))

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, idx: int):
        x, y = self.samples[idx]
        return (
            torch.tensor(x),
            {k: torch.tensor(v, dtype=torch.long) for k, v in y.items()},
        )


# ── Positional Encoding ───────────────────────────────────────────────────────

class PositionalEncoding(nn.Module):
    def __init__(self, d_model: int, max_len: int = 512, dropout: float = 0.1):
        super().__init__()
        self.dropout = nn.Dropout(dropout)
        pe = torch.zeros(max_len, d_model)
        pos = torch.arange(max_len).unsqueeze(1).float()
        div = torch.exp(
            torch.arange(0, d_model, 2).float() * (-math.log(10000.0) / d_model)
        )
        pe[:, 0::2] = torch.sin(pos * div)
        pe[:, 1::2] = torch.cos(pos * div)
        self.register_buffer("pe", pe.unsqueeze(0))  # (1, max_len, d_model)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = x + self.pe[:, : x.size(1)]
        return self.dropout(x)


# ── Model ─────────────────────────────────────────────────────────────────────

class DataCenterWorldModel(nn.Module):
    """
    Temporal Transformer Encoder → per-horizon MLP heads.

    Input shape : (B, W, F)   — batch × window × features
    Output      : dict of (B, 2) logits per horizon
    """

    def __init__(
        self,
        num_features:   int   = NUM_FEATURES,
        window_size:    int   = WINDOW_SIZE,
        d_model:        int   = D_MODEL,
        nhead:          int   = NHEAD,
        num_layers:     int   = NUM_LAYERS,
        dim_feedforward: int  = DIM_FF,
        dropout:        float = DROPOUT,
        horizons:       dict  = None,
    ):
        super().__init__()
        self.horizons = horizons or HORIZONS

        # Input projection
        self.input_proj = nn.Linear(num_features, d_model)
        self.pos_enc    = PositionalEncoding(d_model, max_len=window_size + 1, dropout=dropout)

        # Transformer encoder
        enc_layer = nn.TransformerEncoderLayer(
            d_model=d_model,
            nhead=nhead,
            dim_feedforward=dim_feedforward,
            dropout=dropout,
            batch_first=True,
        )
        self.transformer = nn.TransformerEncoder(enc_layer, num_layers=num_layers)

        # Per-horizon classification heads
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
        h = self.input_proj(x)           # (B, W, d_model)
        h = self.pos_enc(h)
        h = self.transformer(h)          # (B, W, d_model)
        pooled = h.mean(dim=1)           # (B, d_model)  — mean pooling over time
        return {name: head(pooled) for name, head in self.heads.items()}


# ── Training ──────────────────────────────────────────────────────────────────

def train(
    csv_path:   str,
    output_dir: str = "./model_output",
    epochs:     int = 20,
    batch_size: int = BATCH_SIZE,
    lr:         float = LR,
    device:     str | None = None,
):
    if device is None:
        device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Training on device: {device}")

    output_dir = pathlib.Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # ── Data ──────────────────────────────────────────────────────────────────
    print("Loading dataset...")
    dataset = SensorWindowDataset(csv_path)
    n_val   = max(1, int(0.1 * len(dataset)))
    n_train = len(dataset) - n_val
    train_ds, val_ds = torch.utils.data.random_split(dataset, [n_train, n_val])

    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True,  num_workers=4)
    val_loader   = DataLoader(val_ds,   batch_size=batch_size, shuffle=False, num_workers=4)
    print(f"Train: {n_train:,} samples  |  Val: {n_val:,} samples")

    # ── Per-horizon class weights to handle imbalance ─────────────────────────
    # Each horizon has a different positive rate:
    #   1h  → few windows are within 1h of a failure  (most imbalanced)
    #   6h  → more windows fall within 6h of a failure
    #   24h → even more windows within 24h (least imbalanced)
    # Computing weights separately prevents the far-horizon heads from degenerating.
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    criteria: dict[str, nn.CrossEntropyLoss] = {}
    for horizon_name in HORIZONS:
        labels = [dataset.samples[i][1][horizon_name] for i in range(len(dataset))]
        n_neg = sum(1 for l in labels if l == 0)
        n_pos = sum(1 for l in labels if l == 1)
        n_tot = n_neg + n_pos
        w_neg = n_tot / (2 * max(n_neg, 1))
        w_pos = n_tot / (2 * max(n_pos, 1))
        weights = torch.tensor([w_neg, w_pos], dtype=torch.float32).to(dev)
        criteria[horizon_name] = nn.CrossEntropyLoss(weight=weights)
        print(f"  {horizon_name:>3s} weights — normal: {w_neg:.3f}  failure: {w_pos:.3f}  "
              f"(pos rate: {100*n_pos/n_tot:.1f}%)")

    # ── Model ─────────────────────────────────────────────────────────────────
    model     = DataCenterWorldModel().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs)

    best_val_loss = float("inf")

    for epoch in range(1, epochs + 1):
        # ── Train ──────────────────────────────────────────────────────────
        model.train()
        train_loss = 0.0
        for x, y_dict in train_loader:
            x = x.to(device)
            logits = model(x)

            loss = sum(
                criteria[name](logits[name], y_dict[name].to(device))
                for name in HORIZONS
            )
            optimizer.zero_grad()
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            train_loss += loss.item()

        train_loss /= len(train_loader)

        # ── Validation ─────────────────────────────────────────────────────
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
            f"{name}={100*correct[name]/total:.1f}%" for name in HORIZONS
        )
        print(f"Epoch {epoch:3d}/{epochs}  "
              f"train_loss={train_loss:.4f}  val_loss={val_loss:.4f}  "
              f"acc: {acc_str}")

        # ── Checkpoint ─────────────────────────────────────────────────────
        if val_loss < best_val_loss:
            best_val_loss = val_loss
            ckpt_path = output_dir / "best_model.pt"
            torch.save({
                "epoch":      epoch,
                "state_dict": model.state_dict(),
                "val_loss":   val_loss,
                "horizons":   list(HORIZONS.keys()),
            }, ckpt_path)
            print(f"  -> Saved best model to {ckpt_path}")

    print(f"\nTraining complete. Best val loss: {best_val_loss:.4f}")
    return str(output_dir / "best_model.pt")


# ── Inference helper ──────────────────────────────────────────────────────────

def load_model(ckpt_path: str, device: str = "cpu") -> DataCenterWorldModel:
    ckpt  = torch.load(ckpt_path, map_location=device)
    model = DataCenterWorldModel()
    model.load_state_dict(ckpt["state_dict"])
    model.eval()
    return model


def predict(model: DataCenterWorldModel, window: np.ndarray, device: str = "cpu") -> dict:
    """
    window: np.ndarray of shape (WINDOW_SIZE, NUM_FEATURES)
    Returns: {'1h': prob, '6h': prob, '24h': prob}

    NOTE: applies the same per-window z-score normalization used during training.
    """
    # Must match SensorWindowDataset normalization exactly
    mean = window.mean(axis=0, keepdims=True)
    std  = window.std(axis=0,  keepdims=True) + 1e-8
    window_norm = (window - mean) / std

    x = torch.tensor(window_norm, dtype=torch.float32).unsqueeze(0).to(device)
    with torch.no_grad():
        logits = model(x)
    return {
        name: torch.softmax(logits[name], dim=-1)[0, 1].item()
        for name in HORIZONS
    }


# ── CLI entry point ───────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train DataCenter World Model")
    parser.add_argument("--csv",        required=True,      help="Path to sensor_timeseries.csv")
    parser.add_argument("--output-dir", default="./model_output")
    parser.add_argument("--epochs",     type=int, default=20)
    parser.add_argument("--batch-size", type=int, default=BATCH_SIZE)
    parser.add_argument("--lr",         type=float, default=LR)
    args = parser.parse_args()

    train(
        csv_path   = args.csv,
        output_dir = args.output_dir,
        epochs     = args.epochs,
        batch_size = args.batch_size,
        lr         = args.lr,
    )
