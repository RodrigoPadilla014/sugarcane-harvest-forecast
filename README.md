# TCH Prediction Harvest Season

Machine learning workflow for estimating sugarcane `tch` and evaluating harvest-season aggregate behavior.

The current modeling target is still lot-season `tch`, but the primary decision metric is now the raw zafra aggregate:

```text
actual_zafra_tch_sum = sum(actual_tch for all lots in the zafra)
pred_zafra_tch_sum   = sum(pred_tch for all lots in the zafra)
tch_sum_diff         = pred_zafra_tch_sum - actual_zafra_tch_sum
tch_sum_pct_diff     = tch_sum_diff / actual_zafra_tch_sum
```

Lot-level metrics remain important diagnostics. The training pipeline can optimize either lot-level fit or this aggregate zafra objective through the Optuna objective mode.

## Current Dataset

The active v4 dataset is the pseudo-sequential, no-radar, light-pruned feature table:

```text
tch_features_v4_pseudoseq_core_no_radar_light_pruned
```

Its SQL is built from the pseudo-sequential v4 feature blocks:

```text
queries/v4/pseudo_sequential/feature_blocks/
queries/v4/pseudo_sequential/queries/
```

The feature table contract for training is:

```text
cod_cg_zafra
cod_cg
zafra_norm
area
tch
tc
fecha_inicio_ciclo
fecha_fin_ciclo
```

`tch` is the model target. `area` and `tc` are retained for metadata, diagnostics, and optional production-style reporting. The aggregate objective currently uses raw `tch` sums, not area-weighted sums.

## Upload Datasets

Datasets are expected under:

```text
s3://<bucket>/datasets/{dataset}.parquet
```

or, for partitioned/chunked datasets:

```text
s3://<bucket>/datasets/{dataset}/
```

The upload script is:

```text
sagemaker/jobs/upload_dataset.py
```

It searches versioned query folders, including:

```text
queries/v4/aggregated/queries/
queries/v4/sequential/queries/
queries/v4/pseudo_sequential/queries/
```

Example:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v4_pseudoseq_core_no_radar_light_pruned
```

Database credentials must come from environment variables. Do not commit local exports, scratch scripts, or credentials.

## Training Image

The SageMaker image is built from:

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

Prefer immutable tags for formal comparisons; `latest` is convenient for active iteration.

## Launch Jobs

Feature-table datasets should use:

```text
--dataset-type feature_table
```

The launcher supports objective modes:

```text
--objective-mode auto
--objective-mode lot_rmse
--objective-mode walk_forward_r2
--objective-mode aggregate_tch_sum
```

`auto` preserves the legacy behavior: validation RMSE for standard tuning and walk-forward R2 for walk-forward tuning.

Aggregate-aware CatBoost walk-forward run:

```powershell
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$REGION = "us-east-1"
$IMAGE_URI = "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/tch-sagemaker-training:latest"

python sagemaker/jobs/launch_job.py tch_features_v4_pseudoseq_core_no_radar_light_pruned `
  --dataset-type feature_table `
  --model-type catboost `
  --n-trials 20 `
  --walk-forward `
  --objective-mode aggregate_tch_sum `
  --aggregate-penalty 2.0 `
  --categorical-mode native `
  --no-dummies `
  --no-light-features `
  --max-run 14400 `
  --max-wait 14400 `
  --image-uri $IMAGE_URI
```

The aggregate objective minimizes:

```text
mean_rmse + aggregate_penalty * mean_abs_raw_tch_sum_pct_diff
```

The aggregate percent difference is measured in percentage points. For example, with `--aggregate-penalty 2.0`, a 3 percentage-point zafra-sum error adds 6 RMSE-equivalent points to the Optuna objective.

Diagnostics-only run:

```powershell
python sagemaker/jobs/launch_job.py tch_features_v4_pseudoseq_core_no_radar_light_pruned `
  --dataset-type feature_table `
  --model-type lightgbm `
  --categorical-mode controlled `
  --diagnostics-only `
  --no-light-features `
  --image-uri $IMAGE_URI
```

Diagnostics-only mode runs before categorical encoding so pruning recommendations refer to raw feature-table columns rather than one-hot dummy columns.

## Categorical Encoding

Categorical handling is implemented in:

```text
sagemaker/training/categorical_encoding.py
```

Training supports:

```text
--categorical-mode controlled
--categorical-mode native
--categorical-mode none
```

`controlled` learns allowed categories from the train split only. Rare or unseen categories go to `__OTHER__`; nulls go to `__MISSING__`.

`native` keeps categorical columns as strings for supported models. Currently this path is implemented for CatBoost. Use `--no-dummies` with CatBoost native mode.

`prod_finca` is excluded from model inputs because it has high cardinality and can act like a location or identity memorization feature.

## Outputs

Training outputs are written to:

```text
s3://<bucket>/experiments/{dataset}/{model_type}/{job_name}/
```

Diagnostics-only outputs are written to:

```text
s3://<bucket>/experiments/{dataset}/diagnostics/{job_name}/
```

Main SageMaker objects:

```text
output/model.tar.gz
output/output.tar.gz
```

Common files inside `output.tar.gz`:

```text
metrics.json
metrics_by_zafra.csv
metrics_by_zafra_aggregate.csv
metrics_by_lot_error.csv
metrics_by_tch_range.csv
tail_error_report.csv
predictions_by_lot.csv
split_metadata.json
feature_list.json
categorical_encoding.json
best_params.json
optuna_trials.csv
```

When quantiles are enabled, the pipeline also writes:

```text
predictions_by_lot_quantiles.csv
metrics_by_quantile_interval.csv
```

`metrics_by_zafra.csv` includes aggregate totals and uncertainty-style stress bands:

```text
actual_tch_sum
pred_tch_sum
tch_sum_diff
tch_sum_pct_diff
pred_tch_p10_sum
pred_tch_p50_sum
pred_tch_p90_sum
p10_tch_sum_diff
p50_tch_sum_diff
p90_tch_sum_diff
actual_tch_sum_within_p10_p90
```

Area-weighted aggregate columns may also be present as diagnostics, but they are not the current optimization objective.

`metrics_by_zafra_aggregate.csv` summarizes aggregate performance across all zafras and across splits with enough zafras to support R2:

```text
split
zafras
actual_tch_sum
pred_tch_sum
tch_sum_diff
tch_sum_pct_diff
zafra_tch_sum_mae
zafra_tch_sum_rmse
aggregate_zafra_r2
```

When enabled, diagnostics and SHAP add:

```text
feature_importance_shap.csv
shap_values.parquet
feature_missing_rate.csv
feature_stability_by_split.csv
feature_variance.csv
feature_univariate_target_association.csv
feature_correlation_pairs.csv
feature_spearman_correlation_pairs.csv
feature_correlation_clusters.csv
feature_interaction_candidates.csv
feature_pruning_recommendations.csv
```

## Validation Notes

The temporal split is:

```text
train: 2020_2021, 2021_2022, 2022_2023
validation: 2023_2024
test: 2024_2025
```

Use walk-forward Optuna to compare aggregate behavior across multiple held-out harvest seasons. Use the fixed validation/test split to report final model behavior.

For aggregate-focused experiments, compare at least:

```text
metrics_by_zafra.csv
metrics.json
optuna_trials.csv
walk_forward_metrics.csv
tail_error_report.csv
```

The most important aggregate columns are `tch_sum_diff` and `tch_sum_pct_diff`. Lot-level `r2`, `rmse`, and tail error reports should be read as supporting diagnostics, not the sole selection criteria.
