# SageMaker — Project Guide

## Purpose
Iterative ML training pipeline for TCH (toneladas de caña por hectárea) prediction.
The goal is fast experimentation: launch jobs, review SHAP, adjust features, rerun.

---

## Iteration Loop

```
1. upload_dataset.py   — pull from PostgreSQL → S3 (run once per new data snapshot)
2. launch_job.py       — submit a SageMaker training job (Optuna + SHAP inside)
3. Review SHAP output  — s3://ndvi-extraction/experiments/{dataset}/{model}/
4. Edit features.py    — add/drop/transform features based on SHAP findings
5. Commit features.py  — git commit hash is your version history, no features_v2.py
6. Go to step 2
```

`features.py` is the **only file you should edit between iterations**.
Everything else (train.py, launch_job.py) stays the same.

---

## Commands

```bash
# One-time: provision IAM role
cd sagemaker/infra && terraform init && terraform apply

# Upload a dataset snapshot to S3 (in memory, no local file)
python sagemaker/jobs/upload_dataset.py maestra_agregada
python sagemaker/jobs/upload_dataset.py maestra_clima
python sagemaker/jobs/upload_dataset.py maestra_raw

# Launch a training job (non-blocking, runs on AWS)
python sagemaker/jobs/launch_job.py maestra_agregada --model-type xgboost --n-trials 50
python sagemaker/jobs/launch_job.py maestra_agregada --model-type random_forest --n-trials 30
```

---

## S3 Layout

```
s3://ndvi-extraction/
├── datasets/
│   └── {query_name}.parquet        ← uploaded by upload_dataset.py
└── experiments/
    └── {dataset}/{model_type}/
        └── {job_name}/
            ├── output/model.tar.gz         ← trained model
            ├── output/shap_values.parquet  ← SHAP values
            ├── output/metrics.json         ← rmse, mae, r2
            └── output/best_params.json     ← Optuna best hyperparams
```

---

## Design Decisions

**Pre-built SKLearn container** — no custom Docker needed. Extra deps installed via `requirements.txt`.

**Spot instances on by default** — ~70% cost savings. `max_wait=7200` handles interruptions.

**git = version control for features.py** — every job logs the git commit hash implicitly through SageMaker job metadata. No versioned filenames.

**Optuna runs inside every job** — hyperparams are re-tuned each time because the best params change when the feature set changes.

**SHAP after every training** — output is a parquet of per-row SHAP values. Use it to decide which features to keep, drop, or engineer next.

**Data extraction is local** — `upload_dataset.py` runs from your machine via SSH tunnel. The DB is not directly reachable from AWS. Upgrade to a scheduled job later if needed.

**`ml_dataset.sql` is deprecated** — do not use it for uploads. The three valid datasets are `maestra_raw`, `maestra_clima`, and `maestra_agregada`.

**`paramiko<4` is required** — `sshtunnel` 0.4.0 is incompatible with `paramiko` 4.x (`DSSKey` was removed). Always pin `paramiko<4`.

---

## What Is Not Here Yet (Intentional)

- Feature engineering logic — `features.py` is a placeholder. Fill in `FEATURES` list after first run.
- SageMaker Experiments integration — tracking is via job names and S3 artifacts for now.
- Model evaluation on a holdout set — train.py currently reports train metrics only.
- Multiple query support in one job — each job takes one dataset.
