"""
Phase 7a — DINO Encoder Pre-training for Sensor Time-Series
============================================================
Self-supervised feature learning using DINO (Self-DIstillation with NO labels).

The DINO encoder learns rich representations from *unlabeled* sensor windows.
It is pre-trained on the raw telemetry, then its frozen patch tokens are fed
into the Temporal Transformer (Phase 7) instead of raw 4-feature inputs.

This mirrors how DINO is used in vision: pre-train on images without labels,
then fine-tune on a small labelled set.  Here the "images" are sensor windows.

Architecture
------------
  Input  : (B, T, F)     — batch × 12 timesteps × 4 sensor features
  Encoder: ViT-Tiny style (2 layers, 4 heads, d_model=64) + CLS token
  Head   : 2-layer MLP projection to prototype space (dim=256)
  Output : (B, 64) CLS embedding   OR   (B, T, 64) patch token sequence

DINO Training Objective
-----------------------
  Teacher (momentum): EMA copy of the student, sees only *global* views.
  Student           : sees both global and local (sub-window) views.
  Loss              : H(teacher_softmax, student_softmax) with centering.
  The centering prevents collapse without needing contrastive negatives.

Augmentations (adapted for sensor time-series)
----------------------------------------------
  Global views (×2): full 12-step window + light Gaussian noise  (σ=0.01)
  Local  views (×4): random 6–9 step sub-window + heavier noise  (σ=0.05)
  Feature masking  : randomly zero one feature column per sample (p=0.15)

Usage
-----
    # Step 1 — pre-train the encoder (no labels needed):
    python deploy/dino_encoder.py \\
        --csv sensor_timeseries.csv \\
        --epochs 50 \\
        --output-dir model_output/

    # Step 2 — use the encoder in Phase 7 world-model training:
    python deploy/07_world_model.py \\
        --csv sensor_timeseries.csv \\
        --dino-ckpt model_output/dino_encoder.pt \\
        --epochs 20
"""

from __future__ import annotations

import argparse
import copy
import math
import os
import pathlib
import random as _random

import numpy as np
import pandas as pd
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader

# ── Hyperparameters ───────────────────────────────────────────────────────────
WINDOW_SIZE     = 12          # timesteps in a full window
NUM_FEATURES    = 4           # temp_c, power_kw, disk_health, cpu_load
FEATURE_COLS    = ["temp_c", "power_kw", "disk_health", "cpu_load"]
D_MODEL         = 64          # embedding dimension
NHEAD           = 4
NUM_LAYERS      = 2           # keep small for Jetson deployment
DIM_FF          = 256
PROJ_DIM        = 256         # DINO projection head output dim
DROPOUT         = 0.1

# DINO training
N_GLOBAL_CROPS  = 2
N_LOCAL_CROPS   = 4
LOCAL_MIN_STEPS = 6           # minimum timesteps in a local crop
LOCAL_MAX_STEPS = 9           # maximum timesteps in a local crop
NOISE_GLOBAL    = 0.01        # Gaussian noise σ for global views
NOISE_LOCAL     = 0.05        # Gaussian noise σ for local views
MASK_PROB       = 0.15        # probability of zeroing one feature column
EMA_MOMENTUM    = 0.996       # teacher EMA decay (increases toward 1 over training)
STUDENT_TEMP    = 0.1         # student softmax temperature
TEACHER_TEMP    = 0.04        # teacher softmax temperature (sharper)
CENTER_MOMENTUM = 0.9         # centering EMA decay


# ── Augmentations ─────────────────────────────────────────────────────────────

def augment_global(window: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Full-length window with light noise and optional feature masking."""
    w = window.copy()
    # Light Gaussian noise
    w += rng.normal(0, NOISE_GLOBAL, w.shape).astype(np.float32)
    # Random feature masking (zero out one column with probability MASK_PROB)
    if rng.random() < MASK_PROB:
        col = rng.integers(0, NUM_FEATURES)
        w[:, col] = 0.0
    return w


def augment_local(window: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """
    Random sub-window crop (LOCAL_MIN_STEPS to LOCAL_MAX_STEPS steps)
    with heavier noise, zero-padded back to WINDOW_SIZE.
    """
    T = window.shape[0]
    crop_len = int(rng.integers(LOCAL_MIN_STEPS, LOCAL_MAX_STEPS + 1))
    start = int(rng.integers(0, T - crop_len + 1))
    crop = window[start : start + crop_len].copy()
    # Heavier noise
    crop += rng.normal(0, NOISE_LOCAL, crop.shape).astype(np.float32)
    # Feature masking
    if rng.random() < MASK_PROB:
        col = rng.integers(0, NUM_FEATURES)
        crop[:, col] = 0.0
    # Pad back to WINDOW_SIZE (repeat-pad with last value)
    pad_len = WINDOW_SIZE - crop_len
    if pad_len > 0:
        pad = np.repeat(crop[[-1]], pad_len, axis=0)
        crop = np.concatenate([crop, pad], axis=0)
    return crop.astype(np.float32)


# ── Dataset ───────────────────────────────────────────────────────────────────

class DINOSensorDataset(Dataset):
    """
    Yields (global_views, local_views) per sample — no labels.
    Each call to __getitem__ applies fresh random augmentations.
    """

    def __init__(self, csv_path: str, seed: int = 42):
        df = pd.read_csv(csv_path, parse_dates=["timestamp"])
        df = df.sort_values(["rack_id", "timestamp"]).reset_index(drop=True)

        self.windows: list[np.ndarray] = []
        max_horizon = 288  # must leave room at the end (matches 07_world_model.py)

        for _, grp in df.groupby("rack_id"):
            grp = grp.reset_index(drop=True)
            feats = grp[FEATURE_COLS].values.astype(np.float32)
            n = len(feats)
            for i in range(WINDOW_SIZE, n - max_horizon):
                w = feats[i - WINDOW_SIZE : i]
                # Per-window z-score (same as in world_model.py)
                mean = w.mean(axis=0, keepdims=True)
                std  = w.std(axis=0,  keepdims=True) + 1e-8
                self.windows.append((w - mean) / std)

        self.seed = seed
        print(f"DINOSensorDataset: {len(self.windows):,} windows loaded.")

    def __len__(self) -> int:
        return len(self.windows)

    def __getitem__(self, idx: int):
        rng = np.random.default_rng(seed=None)  # fresh RNG per call = true randomness
        w = self.windows[idx]

        global_views = [
            torch.tensor(augment_global(w, rng)) for _ in range(N_GLOBAL_CROPS)
        ]
        local_views = [
            torch.tensor(augment_local(w, rng)) for _ in range(N_LOCAL_CROPS)
        ]
        return global_views, local_views


def dino_collate(batch):
    """Stack views from a list of (global_views, local_views) tuples."""
    n_global = len(batch[0][0])
    n_local  = len(batch[0][1])
    global_views = [
        torch.stack([b[0][i] for b in batch]) for i in range(n_global)
    ]
    local_views = [
        torch.stack([b[1][i] for b in batch]) for i in range(n_local)
    ]
    return global_views, local_views


# ── Model ─────────────────────────────────────────────────────────────────────

class SensorPatchEmbedding(nn.Module):
    """Projects each timestep (F features) into D_MODEL dimensions."""

    def __init__(self, num_features: int = NUM_FEATURES, d_model: int = D_MODEL):
        super().__init__()
        self.proj = nn.Linear(num_features, d_model)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: (B, T, F) → (B, T, d_model)
        return self.proj(x)


class DINOEncoder(nn.Module):
    """
    Small ViT-style encoder for sensor time-series.

    Architecture:
        patch_embed : F → d_model per timestep
        CLS token   : learnable global summary token
        pos_embed   : learnable positional embedding (T+1 positions)
        transformer : pre-norm TransformerEncoder (num_layers layers, nhead heads)
        norm        : final LayerNorm

    forward(x) returns the CLS token: (B, d_model)
    get_patch_tokens(x) returns all T patch tokens: (B, T, d_model)
    """

    def __init__(
        self,
        num_features: int   = NUM_FEATURES,
        d_model:      int   = D_MODEL,
        nhead:        int   = NHEAD,
        num_layers:   int   = NUM_LAYERS,
        dim_ff:       int   = DIM_FF,
        dropout:      float = DROPOUT,
    ):
        super().__init__()
        self.d_model = d_model

        self.patch_embed = SensorPatchEmbedding(num_features, d_model)
        self.cls_token   = nn.Parameter(torch.zeros(1, 1, d_model))
        # +1 for CLS token
        self.pos_embed   = nn.Parameter(torch.zeros(1, WINDOW_SIZE + 1, d_model))

        enc_layer = nn.TransformerEncoderLayer(
            d_model=d_model,
            nhead=nhead,
            dim_feedforward=dim_ff,
            dropout=dropout,
            batch_first=True,
            norm_first=True,   # pre-norm is more stable for small models
        )
        self.transformer = nn.TransformerEncoder(enc_layer, num_layers=num_layers)
        self.norm = nn.LayerNorm(d_model)

        self._init_weights()

    def _init_weights(self):
        nn.init.trunc_normal_(self.cls_token,  std=0.02)
        nn.init.trunc_normal_(self.pos_embed,  std=0.02)
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.trunc_normal_(m.weight, std=0.02)
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    def _embed(self, x: torch.Tensor) -> torch.Tensor:
        B, T, _ = x.shape
        x = self.patch_embed(x)                             # (B, T, d_model)
        cls = self.cls_token.expand(B, -1, -1)              # (B, 1, d_model)
        x   = torch.cat([cls, x], dim=1)                    # (B, T+1, d_model)
        x   = x + self.pos_embed[:, : T + 1]
        x   = self.transformer(x)
        return self.norm(x)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """Returns CLS token representation: (B, d_model)."""
        return self._embed(x)[:, 0]

    def get_patch_tokens(self, x: torch.Tensor) -> torch.Tensor:
        """
        Returns per-timestep patch tokens: (B, T, d_model).
        Used by the Temporal Transformer in Phase 7 instead of raw features.
        """
        return self._embed(x)[:, 1:]


class DINOHead(nn.Module):
    """
    2-layer MLP projection head used only during DINO pre-training.
    Weight-normalised last layer (prevents representation collapse).
    Discarded after pre-training — only the DINOEncoder weights are saved.
    """

    def __init__(
        self,
        in_dim:     int = D_MODEL,
        hidden_dim: int = 512,
        out_dim:    int = PROJ_DIM,
    ):
        super().__init__()
        self.mlp = nn.Sequential(
            nn.Linear(in_dim, hidden_dim),
            nn.GELU(),
            nn.Linear(hidden_dim, hidden_dim),
            nn.GELU(),
        )
        self.last = nn.utils.weight_norm(
            nn.Linear(hidden_dim, out_dim, bias=False)
        )
        self.last.weight_g.data.fill_(1)
        self.last.weight_g.requires_grad = False

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.mlp(x)
        x = F.normalize(x, dim=-1, p=2)
        return self.last(x)


# ── DINO Loss ─────────────────────────────────────────────────────────────────

class DINOLoss(nn.Module):
    """
    Cross-entropy between teacher (centered) and student (sharpened) softmax.

    Centering prevents one prototype from dominating (mode collapse).
    Sharpening (low temperature) produces peaked distributions.
    Together these two opposing forces stabilise training without negatives.
    """

    def __init__(
        self,
        out_dim:    int   = PROJ_DIM,
        n_crops:    int   = N_GLOBAL_CROPS + N_LOCAL_CROPS,
        s_temp:     float = STUDENT_TEMP,
        t_temp:     float = TEACHER_TEMP,
        c_momentum: float = CENTER_MOMENTUM,
    ):
        super().__init__()
        self.s_temp     = s_temp
        self.t_temp     = t_temp
        self.c_momentum = c_momentum
        self.n_crops    = n_crops
        self.register_buffer("center", torch.zeros(1, out_dim))

    def forward(
        self,
        student_out: list[torch.Tensor],   # n_crops projections
        teacher_out: list[torch.Tensor],   # n_global projections (centered + sharpened)
    ) -> torch.Tensor:
        teacher_probs = [
            F.softmax((t - self.center) / self.t_temp, dim=-1).detach()
            for t in teacher_out
        ]
        student_log_probs = [
            F.log_softmax(s / self.s_temp, dim=-1) for s in student_out
        ]

        loss = 0.0
        n_terms = 0
        for t_idx, tp in enumerate(teacher_probs):
            for s_idx, slp in enumerate(student_log_probs):
                if s_idx == t_idx:
                    continue   # skip self-distillation between same-index views
                loss += torch.sum(-tp * slp, dim=-1).mean()
                n_terms += 1

        loss = loss / n_terms
        self._update_center(torch.cat(teacher_out))
        return loss

    @torch.no_grad()
    def _update_center(self, teacher_out: torch.Tensor):
        batch_center = teacher_out.mean(dim=0, keepdim=True)
        self.center  = self.center * self.c_momentum + batch_center * (1 - self.c_momentum)


# ── EMA Teacher ───────────────────────────────────────────────────────────────

@torch.no_grad()
def update_teacher(student: nn.Module, teacher: nn.Module, momentum: float):
    """Exponential moving average update of teacher parameters."""
    for s_param, t_param in zip(student.parameters(), teacher.parameters()):
        t_param.data.mul_(momentum).add_(s_param.data * (1.0 - momentum))


# ── Training ──────────────────────────────────────────────────────────────────

def pretrain(
    csv_path:   str,
    output_dir: str   = "./model_output",
    epochs:     int   = 50,
    batch_size: int   = 128,
    lr:         float = 1e-3,
    seed:       int   = 42,
    device:     str | None = None,
):
    """
    Self-supervised DINO pre-training on sensor windows.
    No labels required — uses the raw CSV feature columns only.
    """
    if device is None:
        device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"DINO pre-training on device: {device}")

    # Reproducibility
    _random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)

    output_dir = pathlib.Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # ── Data ──────────────────────────────────────────────────────────────────
    dataset = DINOSensorDataset(csv_path, seed=seed)
    loader  = DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=True,
        collate_fn=dino_collate,
        num_workers=min(4, os.cpu_count() or 1),
        drop_last=True,
    )

    # ── Student + Teacher ─────────────────────────────────────────────────────
    student_enc  = DINOEncoder().to(device)
    student_head = DINOHead().to(device)
    teacher_enc  = copy.deepcopy(student_enc).to(device)
    teacher_head = copy.deepcopy(student_head).to(device)

    for p in teacher_enc.parameters():
        p.requires_grad = False
    for p in teacher_head.parameters():
        p.requires_grad = False

    student_params = list(student_enc.parameters()) + list(student_head.parameters())
    optimizer = torch.optim.AdamW(student_params, lr=lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs)
    criterion = DINOLoss().to(device)

    # EMA momentum schedule: linearly anneal from EMA_MOMENTUM to 1.0
    def get_momentum(epoch: int) -> float:
        return EMA_MOMENTUM + (1.0 - EMA_MOMENTUM) * epoch / epochs

    best_loss = float("inf")

    print(f"Starting DINO pre-training for {epochs} epochs...")
    for epoch in range(1, epochs + 1):
        student_enc.train()
        student_head.train()
        epoch_loss = 0.0

        for global_views, local_views in loader:
            all_views = global_views + local_views
            all_views = [v.to(device) for v in all_views]

            # Student processes all views
            student_out = [student_head(student_enc(v)) for v in all_views]

            # Teacher processes only global views (detached, no grad)
            with torch.no_grad():
                teacher_out = [teacher_head(teacher_enc(v)) for v in global_views]

            loss = criterion(student_out, teacher_out)

            optimizer.zero_grad()
            loss.backward()
            # Clip gradients (important for small ViTs)
            nn.utils.clip_grad_norm_(student_params, 3.0)
            optimizer.step()

            # EMA teacher update
            mom = get_momentum(epoch)
            update_teacher(student_enc,  teacher_enc,  mom)
            update_teacher(student_head, teacher_head, mom)

            epoch_loss += loss.item()

        epoch_loss /= len(loader)
        scheduler.step()

        print(f"Epoch {epoch:3d}/{epochs}  loss={epoch_loss:.4f}  "
              f"ema_mom={get_momentum(epoch):.4f}")

        if epoch_loss < best_loss:
            best_loss = epoch_loss
            ckpt_path = output_dir / "dino_encoder.pt"
            torch.save({
                "epoch":      epoch,
                "state_dict": student_enc.state_dict(),
                "loss":       epoch_loss,
                "config": {
                    "num_features": NUM_FEATURES,
                    "d_model":      D_MODEL,
                    "nhead":        NHEAD,
                    "num_layers":   NUM_LAYERS,
                    "window_size":  WINDOW_SIZE,
                    "feature_cols": FEATURE_COLS,
                },
            }, ckpt_path)
            print(f"  -> Saved best encoder to {ckpt_path}")

    print(f"\nDINO pre-training complete. Best loss: {best_loss:.4f}")
    return str(output_dir / "dino_encoder.pt")


# ── Inference helpers ─────────────────────────────────────────────────────────

def load_encoder(ckpt_path: str, device: str = "cpu") -> DINOEncoder:
    """Load a pre-trained DINOEncoder from checkpoint."""
    ckpt = torch.load(ckpt_path, map_location=device)
    cfg  = ckpt.get("config", {})
    encoder = DINOEncoder(
        num_features = cfg.get("num_features", NUM_FEATURES),
        d_model      = cfg.get("d_model",      D_MODEL),
        nhead        = cfg.get("nhead",         NHEAD),
        num_layers   = cfg.get("num_layers",    NUM_LAYERS),
    )
    encoder.load_state_dict(ckpt["state_dict"])
    encoder.eval()
    return encoder.to(device)


def encode_window(
    encoder: DINOEncoder,
    window:  np.ndarray,
    device:  str = "cpu",
) -> np.ndarray:
    """
    Encode a single sensor window.

    Args:
        window: (WINDOW_SIZE, NUM_FEATURES) float32 array, already z-score normalised
    Returns:
        patch_tokens: (WINDOW_SIZE, D_MODEL) float32 array
                      Drop-in replacement for raw features in the world model.
    """
    x = torch.tensor(window, dtype=torch.float32).unsqueeze(0).to(device)  # (1, T, F)
    with torch.no_grad():
        tokens = encoder.get_patch_tokens(x)   # (1, T, d_model)
    return tokens.squeeze(0).cpu().numpy()     # (T, d_model)


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Phase 7a — DINO encoder pre-training on sensor time-series"
    )
    parser.add_argument("--csv",        required=True,       help="sensor_timeseries.csv")
    parser.add_argument("--output-dir", default="./model_output")
    parser.add_argument("--epochs",     type=int,   default=50)
    parser.add_argument("--batch-size", type=int,   default=128)
    parser.add_argument("--lr",         type=float, default=1e-3)
    parser.add_argument("--seed",       type=int,   default=42)
    args = parser.parse_args()

    pretrain(
        csv_path   = args.csv,
        output_dir = args.output_dir,
        epochs     = args.epochs,
        batch_size = args.batch_size,
        lr         = args.lr,
        seed       = args.seed,
    )
