# TCH Prediction Harvest Season

Machine learning workflow for estimating sugarcane TCH at harvest-season level.

The current version focuses on an **as-of-180-days** forecasting question:

```text
Using only information available up to crop age 180 days,
how well can we estimate final aggregate zafra TCH?
```

The model still predicts lot-level `tch`, but the main decision metric is the raw
zafra aggregate:

```text
actual_zafra_tch_sum = sum(actual_tch for all lots in the zafra)
pred_zafra_tch_sum   = sum(pred_tch for all lots in the zafra)
tch_sum_diff         = pred_zafra_tch_sum - actual_zafra_tch_sum
tch_sum_pct_diff     = tch_sum_diff / actual_zafra_tch_sum
```

Lot-level metrics are kept as diagnostics. They help explain error patterns, but
the production-style objective is aggregate zafra behavior.

## Current Dataset

Active dataset:

```text
tch_features_v5_asof_180d_core
```

S3 location:

```text
s3://ndvi-extraction/datasets/tch_features_v5_asof_180d_core.parquet
```

The dataset is built from `public.tch_raw_longitudinal_v4` and then aggregated
to one row per `cod_cg_zafra`. It keeps only cycles with enough information to
reach the 180-day cutoff:

```text
cycle_age_max >= 180
```

Feature values are computed only from data available at crop ages `0-180`.

Main SQL:

```text
queries/v5/asof_180/queries/tch_features_v5_asof_180d_core.sql
```

Feature block SQL:

```text
queries/v5/asof_180/feature_blocks/
```

Feature blocks:

- agronomy/static context from `productividad`
- optical/STAC vegetation summaries through age 180
- climate pentad summaries through age 180
- ENSO summaries available before and during the early cycle

The raw longitudinal template that feeds v5 is:

```text
queries/template/v4/tch_raw_longitudinal_v4.sql
```

Categorical fields from `productividad` are normalized there with trimming,
uppercasing, empty-to-null conversion, and selected soil-family cleanup.

## Split Strategy

The current validation setup is temporal:

| Role | Zafras |
|---|---|
| Train | `2020_2021`, `2021_2022`, `2022_2023` |
| Validation | `2023_2024` |
| Test | `2024_2025` |
| External partial scoring | `2025_2026` |

`2025_2026` is passed with `--external-zafras 2025_2026`. It is scored after
training and is not used for fitting, tuning, validation, test, or walk-forward.

## Dataset Upload

Upload the active feature table:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v5_asof_180d_core
```

Datasets are written as:

```text
s3://ndvi-extraction/datasets/{dataset}.parquet
```

Database credentials must come from environment variables under the local
credentials setup. Do not commit credentials, local exports, or scratch scripts
with connection strings.

## Training Image

The SageMaker training image is built from:

```text
sagemaker/docker/Dockerfile
sagemaker/docker/requirements.txt
```

Build and push:

```powershell
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$REGION = "us-east-1"
$REPO = "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/tch-sagemaker-training"

docker build -f sagemaker/docker/Dockerfile -t tch-sagemaker-training:latest sagemaker
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
docker tag tch-sagemaker-training:latest "${REPO}:latest"
docker push "${REPO}:latest"
```

Launcher-only changes do not require rebuilding the image. Rebuild when code
under `sagemaker/training/` or Docker dependencies change.

## Launch Jobs

Set the image URI:

```powershell
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$REGION = "us-east-1"
$IMAGE_URI = "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/tch-sagemaker-training:latest"
```

Current baseline CatBoost run:

```powershell
python sagemaker/jobs/launch_job.py tch_features_v5_asof_180d_core `
  --dataset-type feature_table `
  --model-type catboost `
  --categorical-mode native `
  --no-dummies `
  --no-light-features `
  --walk-forward `
  --objective-mode aggregate_tch_sum `
  --aggregate-penalty 2.0 `
  --skip-optuna `
  --external-zafras 2025_2026 `
  --no-spot `
  --max-run 14400 `
  --image-uri $IMAGE_URI
```

For Optuna hyperparameter tuning, remove `--skip-optuna` and set trials:

```powershell
  --n-trials 20
```

Useful launcher options:

- `--no-spot`: use on-demand capacity instead of managed spot training.
- `--instance-type`: override the SageMaker training instance type.
- `--external-zafras`: score one or more zafras without fitting or tuning on them.
- `--objective-mode aggregate_tch_sum`: optimize the aggregate zafra objective.
- `--aggregate-penalty`: weight aggregate percent error inside the objective.

The aggregate-aware objective is:

```text
mean_rmse + aggregate_penalty * mean_abs_raw_tch_sum_pct_diff
```

## Diagnostics

Feature diagnostics for as-of-180 are under:

```text
queries/feature_diagnostics/v5_asof_180/
```

The clean diagnostic methodology uses discovery years for feature decisions and
keeps later years for validation/test/external checks.

Anomalous zafra diagnostics are under:

```text
queries/zafra_diagnostics/v5/
```

The current anomalous-zafra report focuses on `2023_2024`, where the baseline
model overpredicted aggregate TCH. It compares target distribution, model error,
top-SHAP feature drift, data coverage, and categorical group residuals.

## Current Baseline Result

Baseline job:

```text
tch-tch-features-v5-asof-180d-core-catboost-20260528-143010
```

Key aggregate results:

| Zafra | Role | Aggregate diff |
|---|---|---:|
| `2023_2024` | validation | `+9.82%` |
| `2024_2025` | closed test | `+2.48%` |
| `2025_2026` | external partial | `-2.17%` |

Interpretation:

- The model is promising for aggregate validation.
- `2024_2025` and partial `2025_2026` are close at aggregate level.
- `2023_2024` is the main robustness warning.
- The likely failure mode is optimistic early vegetation/climate signal plus
  weaker optical coverage, followed by final TCH that did not match the early
  vigor signal.

## Common Outputs

Training outputs are written to:

```text
s3://ndvi-extraction/experiments/{dataset}/{model_type}/{job_name}/
```

Important files inside `output/output.tar.gz`:

- `metrics.json`
- `metrics_by_zafra.csv`
- `metrics_by_zafra_aggregate.csv`
- `metrics_by_zafra_external.csv`
- `predictions_by_lot.csv`
- `predictions_external.csv`
- `feature_importance_shap.csv`
- `feature_pruning_recommendations.csv`
- `tail_error_report.csv`
- `walk_forward_metrics.csv`
