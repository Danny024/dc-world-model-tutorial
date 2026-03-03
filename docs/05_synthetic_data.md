# Synthetic Data Generation

> **Reading time:** 15 minutes
> **Goal:** Understand why synthetic data works and how we generate it.

---

## The Data Problem in Industrial AI

To train a machine learning model to detect failures, you need:
- Examples of normal operation
- Examples of each type of failure
- Enough of both to generalize

In a real data center:
- Normal operation: thousands of examples per day ✓
- Failures: maybe 10–50 per year across thousands of servers ✗

Even if you had 5 years of data, you'd have severe **class imbalance** —
99.9% normal, 0.1% failure. Most models trained on this just predict "normal" always
and still get 99.9% accuracy (but are completely useless).

**Synthetic data solves this by letting us generate as many failure examples as we want.**

---

## Our Four Failure Scenarios

We model four common data center failure modes:

### 1. Overheating
**Real-world cause:** CRAC unit failure, hot aisle containment breach, high ambient temperature

**Sensor signature:**
```
temp_c:       +25 to +45°C above baseline    (severe spike)
power_kw:     +0.5 to +1.5 kW               (cooling overhead)
disk_health:  unchanged
cpu_load:     +10 to +30%                    (thermal throttling)
```

**Timeline:** Rapid onset (minutes to hours). Very dangerous — can destroy hardware.

### 2. Disk Degradation
**Real-world cause:** HDD mechanical wear, SSD write exhaustion, controller failure

**Sensor signature:**
```
temp_c:       +2 to +8°C                    (slight increase from retries)
power_kw:     +0.1 to +0.3 kW              (I/O activity overhead)
disk_health:  -40 to -70% (SMART score)    (the primary signal)
cpu_load:     +5 to +15%                   (I/O wait time)
```

**Timeline:** Slow onset (weeks to months). Most predictable failure type.

### 3. Power Fluctuation
**Real-world cause:** PDU failure, UPS switchover, grid power quality issues

**Sensor signature:**
```
temp_c:       +3 to +10°C                  (brief thermal event)
power_kw:     +2 to +5 kW spike            (the primary signal — sudden spike)
disk_health:  unchanged
cpu_load:     +0 to +5%                    (minimal change)
```

**Timeline:** Fast onset (seconds to minutes). Can cause data corruption.

### 4. Cooling Failure
**Real-world cause:** Chiller failure, coolant leak, fan array failure

**Sensor signature:**
```
temp_c:       +15 to +35°C                 (severe, room-wide increase)
power_kw:     +1 to +2.5 kW               (fans at max speed)
disk_health:  -10 to -30%                  (heat stress on drives)
cpu_load:     +20 to +50%                  (thermal throttling + retries)
```

**Timeline:** Medium onset (hours). Affects entire rack rows, not just one rack.

---

## How the Simulation Works

### Step 1: Assign Baseline Readings Per Rack

Each rack has stable "normal" readings seeded by its rack ID:
```python
def baseline(rack_id: int) -> dict:
    rng = random.Random(rack_id * 31337)  # deterministic seed
    return {
        "temp_c":      rng.uniform(18.0, 28.0),   # normal operating temp
        "power_kw":    rng.uniform(4.0,  8.0),    # depends on workload
        "disk_health": rng.uniform(0.85, 1.0),    # new-ish drives
        "cpu_load":    rng.uniform(0.2,  0.6),    # typical server load
    }
```

Different racks get different baselines because real racks run different workloads.

### Step 2: Pre-Assign Failure Windows

Before simulation starts, we randomly assign failure events to racks and days:
```
Rack 3, Day 12, cooling_failure, 6 hours
Rack 17, Day 4, disk_degradation, 8 hours
...
```

4% of rack-days get a failure (configurable via `FAILURE_RATE`).

### Step 3: Apply Failure Effects with Bell-Curve Ramping

A failure doesn't appear instantaneously — it builds and fades.
We use a sine curve to create a natural ramp:
```python
progress = (step - onset) / (end - onset)  # 0.0 → 1.0
ramp = math.sin(progress * math.pi)        # 0 → 1 → 0 (bell curve)

temp += ramp * random.uniform(td_lo, td_hi)
```

This creates realistic-looking anomalies:
```
Normal:  23.1  23.4  22.9  23.2  23.5
Onset:   23.8  25.1  28.4  34.7  41.2  (rising)
Peak:    48.3  47.9  49.1  48.6        (sustained)
Decay:   42.1  36.4  29.8  25.3  23.6  (cooling)
Normal:  23.1  22.8  23.3             (back to baseline)
```

### Step 4: Add Measurement Noise

Real sensors have noise — they don't read exactly 23.4°C every time.
We add small random perturbations (±3% Gaussian noise):
```python
def add_noise(value: float, pct: float = 0.03) -> float:
    return value + random.gauss(0, abs(value) * pct)
```

---

## The Resulting Dataset

After 30 days × 48 racks × 288 samples/day (5-min intervals):
- **Total rows:** ~414,720
- **Normal rows:** ~397,000 (95.8%)
- **Failure rows:** ~17,720 (4.2%)
- **File size:** ~25 MB CSV

The sliding-window training dataset then creates ~400,000 labeled examples
where each example is a 12-timestep window with a binary label per horizon.

---

## Discussion Questions

1. We set `FAILURE_RATE = 0.04` (4% of rack-days experience a failure).
   If a real data center has 0.01% failure rate, what problem does this cause for training?
   How would you address it?

2. Our noise model adds 3% Gaussian noise. What happens if the real sensors have 15% noise?

3. We model cooling failure as affecting one rack. In reality, a chiller failure affects
   an entire row of racks. How would you modify `06_generate_failure_data.py` to model
   correlated failures across multiple racks?

---

**Next:** [Transformers for Timeseries →](06_transformers_for_timeseries.md)
