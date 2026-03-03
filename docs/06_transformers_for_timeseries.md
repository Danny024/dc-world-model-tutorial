# Transformers for Timeseries Prediction

> **Reading time:** 20 minutes
> **Goal:** Understand how the Transformer architecture is adapted for sensor data.

---

## From Language to Time

You've probably heard of ChatGPT, which uses a Transformer to predict the next word.
Timeseries prediction is the same idea — but instead of words, we predict what happens
to sensor readings over time.

The key insight: **any sequence of ordered data can be modeled as a "language."**

| NLP | Timeseries |
|---|---|
| Word tokens | Sensor readings at each timestep |
| Sentence | 60-minute window of rack data |
| Predict next word | Predict failure in next 1h/6h/24h |
| Vocabulary size | Number of sensor features |

---

## Why Not Just Use an LSTM?

LSTMs (Long Short-Term Memory networks) were the standard for timeseries before
Transformers. They process sequences step by step, like reading a book one word at a time.

**Problems with LSTMs:**
- Struggle to remember events from far back in the sequence (vanishing gradients)
- Can't parallelize — each step depends on the previous step (slow to train)
- Hard to interpret — where did the model "pay attention"?

**Transformers fix all three:**
- Attention lets every timestep directly attend to every other timestep — no forgetting
- All timesteps are processed in parallel (fast)
- Attention weights show you exactly which timesteps were important for prediction

---

## The Attention Mechanism (Intuition)

Imagine you're a doctor looking at 12 hours of a patient's vital signs and predicting
whether they'll have a cardiac event in the next hour.

You don't give equal weight to every reading. You:
- Focus on the spike in heart rate 3 hours ago
- Notice the gradual blood pressure drop over the last hour
- Ignore the stable oxygen levels (normal, not informative)

Attention does exactly this, but learned from data.

For each timestep, attention computes:
```
How relevant is timestep j to predicting the outcome at timestep i?
```

The answer is a score (0 to 1) for every pair (i, j). High score = "pay attention to this."

---

## Our Model Architecture in Detail

```python
Input: (batch_size=256, window=12, features=4)
# 256 racks, 12 timesteps (last 60 minutes), 4 sensors each

       ↓ Linear(4, 64)
Hidden: (256, 12, 64)   # Project to d_model=64 dimensions

       ↓ PositionalEncoding
Hidden: (256, 12, 64)   # Add time-position information

       ↓ TransformerEncoder (3 layers, 4 heads)
Hidden: (256, 12, 64)   # Contextualised representations

       ↓ mean(dim=1)    # Average over the 12 timesteps
Hidden: (256, 64)       # Single vector per rack

       ↓ MLP head (per horizon)
Output: (256, 2)        # Logits for [normal, failure]
```

We have **3 independent heads** — one each for 1h, 6h, and 24h horizons.
They share the Transformer encoder but have separate MLP heads.
This means the model learns different cues for short-term vs long-term failures.

---

## Positional Encoding — Why It's Needed

A Transformer with pure attention has no sense of order. If you shuffled the 12 timesteps
randomly, it would give the same output. That's wrong — order matters for timeseries!

Positional encoding adds a unique "time signature" to each timestep:

```
PE(t, 2i)   = sin(t / 10000^(2i/d_model))
PE(t, 2i+1) = cos(t / 10000^(2i/d_model))
```

Each timestep gets a different sine/cosine pattern added to it.
The model learns to use these patterns to understand time order.

---

## Multi-Head Attention

Instead of one attention function, we use 4 "heads" in parallel.
Each head can learn to attend to different aspects of the sequence:

- Head 1 might focus on recent temperature spikes
- Head 2 might focus on slow power-draw trends
- Head 3 might correlate disk health with temperature
- Head 4 might watch for oscillating cooling patterns

---

## The Three Loss Functions

We train with three cross-entropy losses (one per horizon), summed:

```python
loss = CE(logits_1h, label_1h) + CE(logits_6h, label_6h) + CE(logits_24h, label_24h)
```

Because 24h predictions are less certain than 1h predictions, the model learns
to be conservative at longer horizons — which matches real-world intuition.

---

## Reading the Training Output

```
Epoch   1/20  train_loss=1.2341  val_loss=1.1820  acc: 1h=72.3%  6h=68.1%  24h=61.4%
Epoch   5/20  train_loss=0.7821  val_loss=0.7654  acc: 1h=84.2%  6h=79.8%  24h=73.1%
Epoch  20/20  train_loss=0.4123  val_loss=0.4312  acc: 1h=91.5%  6h=87.2%  24h=81.9%
```

- **train_loss** should decrease each epoch
- **val_loss** should also decrease (if it increases, you're overfitting)
- **1h accuracy > 6h > 24h** — this is expected; closer horizons are more predictable

---

## What "Failure Probability" Actually Means

The output of our model after `softmax` is:
```
{'1h': 0.85, '6h': 0.62, '24h': 0.38}
```

This means: given the last 60 minutes of sensor readings,
- There is an **85% chance** this rack fails in the next 1 hour
- There is a **62% chance** it fails in the next 6 hours
- There is a **38% chance** it fails in the next 24 hours

The inference config uses threshold 0.70 for 1h — if probability > 70%, alert fires.

---

## Exercise: Modify the Architecture

Try these changes and observe what happens to validation accuracy:

1. Increase `WINDOW_SIZE` from 12 to 36 (3 hours of history). Does more context help?
2. Increase `NUM_LAYERS` from 3 to 6. Does a deeper model improve accuracy?
3. Replace `mean(dim=1)` pooling with `x[:, -1, :]` (just the last timestep). How does accuracy change, and why?

---

**Next:** [Vertex AI Training →](07_vertex_ai_training.md)
