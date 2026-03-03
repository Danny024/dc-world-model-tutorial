# Contributing to dc-world-model-tutorial

Welcome, Atlanta Robotics student! Here's how to contribute improvements to this tutorial.

---

## How to Contribute

### 1. Fork the Repository
Click **Fork** (top-right on GitHub) to create your own copy.

### 2. Create a Branch
```bash
git checkout -b feature/your-improvement-name
# Example: git checkout -b feature/add-fan-rpm-sensor
```

### 3. Make Your Changes
Keep changes focused. Good contributions include:
- Adding a new sensor feature to the data generator
- Improving documentation clarity
- Adding a new exercise or discussion question
- Fixing a bug in the training code
- Adding a new failure scenario

### 4. Test Your Changes
```bash
# For Python changes, run the script end-to-end:
python3 deploy/06_generate_failure_data.py   # standalone mode
python3 deploy/07_world_model.py --csv /tmp/test.csv --epochs 2

# Make sure the script runs without errors before submitting
```

### 5. Submit a Pull Request
- Push your branch: `git push origin feature/your-improvement-name`
- Open a Pull Request on GitHub
- Fill in the PR template describing what you changed and why

---

## Code Style

- Python: follow PEP 8, keep functions under 40 lines
- Comments: explain *why*, not *what* (the code explains what)
- Variable names: descriptive, no single letters except loop indices

---

## Ideas for Contributions

See the **Exercises for Students** section in README.md for open problems.
Each exercise is a potential pull request waiting to happen!

---

## Questions?

Open a GitHub Issue with the tag `question`. Maintainers will respond within 48 hours.
