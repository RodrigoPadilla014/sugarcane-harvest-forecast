# TCH Prediction Harvest Season

Machine learning workflow for estimating aggregate sugarcane TCH by productive
zafra. The current branch focuses on an updateable forecast: as new climate,
radar, optical, ENSO, and productividad rows arrive, the feature table can be
regenerated and scored again for the next zafra.

## Current Objective

The model still predicts `tch` at row level, but the decision objective is the
raw aggregate TCH sum by zafra:

```text
actual_zafra_tch_sum = sum(actual_tch)
pred_zafra_tch_sum   = sum(pred_tch)
tch_sum_diff         = pred_zafra_tch_sum - actual_zafra_tch_sum
tch_sum_pct_diff     = tch_sum_diff / actual_zafra_tch_sum
```

Lot-level metrics are diagnostics only. The production-style question is:

```text
Given the information available for currently growing lots, what is the
predicted aggregate TCH sum for the next productive zafra?
```

## Active Dataset

Active dataset:

```text
tch_features_v9_productivity_snapshots
```

S3 location:

```text
s3://ndvi-extraction/datasets/tch_features_v9_productivity_snapshots/
```

V9 is stored as a partitioned parquet dataset. Upload with:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v9_productivity_snapshots `
  --chunksize 50000 `
  --replace
```

Main SQL:

```text
queries/active/v9/dataset/tch_v9_productivity_snapshot_spine.sql
queries/active/v9/dataset/tch_features_v9_productivity_snapshots.sql
```

The uploader supports SQL includes such as:

```text
{{ include:tch_v9_productivity_snapshot_spine }}
```

so the feature query can compose the temporal spine directly.

## V9 Dataset Logic

V9 treats `productividad` as the historical truth for whether a lot-cycle
belongs in training. Climate, optical, radar, and ENSO tables provide
characteristics; they no longer decide whether a historical productive lot-cycle
exists.

Historical training rows:

- include productive zafras `2020_2021` through `2025_2026`;
- keep valid productividad rows with `20 <= tch <= 150`;
- create fixed snapshots at days `180`, `210`, `240`, `270`, `300`, and `340`;
- use `snapshot_weight` so each historical cycle contributes roughly one unit
  of weight across its snapshots;
- include `cycle_id`, `snapshot_day`, `snapshot_date`, and temporal-quality
  features.

Future scoring rows:

- use productive lots observed in `2025_2026` as candidates for `2026_2027`;
- infer the next cycle start from the latest known closure date;
- score only rows with at least 180 observable days and at most 340 days;
- keep pending rows separate instead of silently treating them as scored.

This design is intentionally updateable: when source tables receive newer
observations, regenerate and re-upload V9, then rerun scoring.

## Training Pipeline

The pipeline now uses explicit zafra roles instead of fixed train,
validation, test, and external defaults.

Required launcher/training flags:

```text
--train-zafras
--evaluation-zafras
--scoring-zafras
```

Current configuration:

| Role | Zafras |
|---|---|
| Train | `2020_2021`, `2021_2022`, `2022_2023`, `2023_2024` |
| Evaluation | `2024_2025`, `2025_2026` |
| Future scoring | `2026_2027` |

Scoring rows do not need a target TCH. They produce predictions and aggregate
forecast artifacts, not error metrics.

Useful output files:

```text
metrics.json
metrics_by_zafra.csv
metrics_by_zafra_aggregate.csv
metrics_by_snapshot_day.csv
evaluation_predictions.csv
evaluation_metrics_by_zafra.csv
future_scoring_predictions.csv
future_scoring_by_zafra.csv
future_scoring_excluded.csv
feature_importance_shap.csv
feature_pruning_recommendations.csv
walk_forward_metrics.csv
split_metadata.json
excluded_features.json
```

## EC2 Execution

This branch runs the training container directly on a reusable EC2 instance.
The runner executes one stage per command and never advances automatically.

Runbook:

```text
ec2/README.md
ec2/INSTANCE.md
ec2/run_training.sh
ec2/monitor_training.sh
```

Current instance:

```text
Instance ID:   i-011601455ec0ed137
Instance type: m5.xlarge
Region:        us-east-1
```

Start with diagnostics:

```bash
bash ec2/run_training.sh diagnostics \
  --dataset tch_features_v9_productivity_snapshots \
  --partitioned
```

Baseline:

```bash
bash ec2/run_training.sh baseline \
  --dataset tch_features_v9_productivity_snapshots \
  --partitioned \
  --exclude-features optical_ndwi11_mean_0_snapshot,radar_rvi_mean_0_snapshot \
  --aggregate-penalty 1.5
```

Optuna:

```bash
bash ec2/run_training.sh optuna \
  --dataset tch_features_v9_productivity_snapshots \
  --partitioned \
  --exclude-features optical_ndwi11_mean_0_snapshot,radar_rvi_mean_0_snapshot \
  --aggregate-penalty 0.5
```

Artifacts are uploaded under:

```text
s3://ndvi-extraction/experiments-ec2/{dataset}/{stage}/{run-id}/
```

## Current V9 Candidate

Best current run:

```text
tch-tch-features-v9-productivity-snapshots-optuna-20260615T162727Z
```

Configuration:

```text
Model:              CatBoost
Aggregate penalty:  0.5
Excluded features:  optical_ndwi11_mean_0_snapshot, radar_rvi_mean_0_snapshot
Train zafras:       2020_2021, 2021_2022, 2022_2023, 2023_2024
Evaluation zafras:  2024_2025, 2025_2026
Scoring zafra:      2026_2027
```

Future scoring result for `2026_2027`:

```text
Eligible lots:                  909
Pending lots:                   7,755
Total candidate lots:           8,664
Predicted aggregate TCH sum:    95,932.96
P10 aggregate TCH sum:          79,005.99
P90 aggregate TCH sum:          111,394.24
```

Evaluation aggregate errors by snapshot on `2025_2026`:

| Snapshot day | Aggregate error |
|---:|---:|
| 180 | `-0.53%` |
| 210 | `-0.14%` |
| 240 | `+0.10%` |
| 270 | `+0.27%` |
| 300 | `+0.47%` |
| 340 | `+0.24%` |

Walk-forward aggregate errors:

| Validation zafra | Aggregate error |
|---|---:|
| `2021_2022` | `1.36%` |
| `2022_2023` | `1.01%` |
| `2023_2024` | `5.61%` |
| `2024_2025` | `1.21%` |

Top SHAP drivers in the current candidate:

```text
prod_codigo_zae
prod_ingenio
prod_no_corte
optical_ndvi_peak_0_snapshot
radar_rvi_mean_91_180
prod_variedad
prod_familia_de_suelo
optical_ndre_mean_0_snapshot
```

## Training Image

Build and push from the repository root:

```powershell
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$REGION = "us-east-1"
$REPO = "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/tch-sagemaker-training"

docker build -f sagemaker/docker/Dockerfile -t tch-sagemaker-training:latest sagemaker
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
docker tag tch-sagemaker-training:latest "${REPO}:latest"
docker push "${REPO}:latest"
```

Current image URI:

```text
920572019712.dkr.ecr.us-east-1.amazonaws.com/tch-sagemaker-training:latest
```

Rebuild when code under `sagemaker/training/` or Docker dependencies change.
Launcher-only changes do not require a rebuild.

## Security Notes

- Do not commit credentials, SSH keys, `.env` files, or database connection
  strings.
- Use the local `credentials/` folder for DB access and SSH material.
- Use the EC2 instance profile for AWS access on the training host.
- `forecast_dashboard/` is local-only on this branch and is ignored by Git.
