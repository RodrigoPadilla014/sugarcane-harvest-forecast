# TCH Prediction Harvest Season

Machine learning workflow for estimating sugarcane yield (`tch`, tons of cane per hectare) at the lot-season level.

The project keeps the database layer focused on raw longitudinal materialized views and builds model-ready feature tables from SQL. Training runs in SageMaker with a pinned Docker image, temporal validation by harvest season, controlled categorical encoding, and reproducible artifacts for diagnostics and audit.

## Current Data Shape

The raw longitudinal views are the canonical source:

```text
public.tch_raw_longitudinal_v2
public.tch_raw_longitudinal_v3
public.tch_raw_longitudinal_v4
```

Each raw view keeps one row per lot-season-observation and contains cleaned categorical fields, optical features, climate joins, SAR joins, and cycle metadata.

The current clean baseline feature table is:

```text
tch_features_v4_core_optical_climate
```

Its SQL lives in:

```text
queries/v4/aggregated/views/tch_features_v4_core_optical_climate.sql
queries/v4/aggregated/queries/tch_features_v4_core_optical_climate.sql
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

`tch` is the target. `area` and `tc` are retained for metadata and reporting, not as transformed targets.

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

`controlled` is the default. It learns allowed categories from the train split only, then applies the same vocabulary to train, validation, and test. Rare or unseen categories go to `__OTHER__`; nulls go to `__MISSING__`.

Current controlled rules:

```text
prod_familia_de_suelo: min_count >= 30
prod_variedad: top_n = 30 OR min_count >= 30
prod_codigo_zae: min_count >= 30
prod_ingenio: all
prod_grupo_de_suelo: all
prod_grupo_de_humedad: all
prod_no_corte: all
prod_cosecha: all
```

`prod_finca` is excluded from model inputs because it has high cardinality and can act like a location/identity memorization feature.

`native` keeps categorical columns as strings for supported models. Currently that path is implemented for CatBoost. `none` drops categorical columns and uses numeric features only.

Every training run writes:

```text
categorical_encoding.json
feature_list.json
split_metadata.json
```

## S3 Datasets

Datasets are expected under:

```text
s3://ndvi-extraction/datasets/{dataset}.parquet
```

or, for partitioned/chunked datasets:

```text
s3://ndvi-extraction/datasets/{dataset}/
```

The upload script is:

```text
sagemaker/jobs/upload_dataset.py
```

It searches SQL in versioned query folders such as:

```text
queries/v4/aggregated/queries/
queries/v4/sequential/queries/
queries/v3/aggregated/queries/
queries/v2/aggregated/queries/
queries/v1/aggregated/queries/
```

Example upload:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v4_core_optical_climate
```

If the backing SQL view does not exist in the database, create it temporarily in the DB session or materialize it intentionally before upload. Do not commit credentials or local `.tmp` exports.

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

For experimental validation, use a specific tag instead of only `latest`, for example:

```text
920572019712.dkr.ecr.us-east-1.amazonaws.com/tch-sagemaker-training:categorical-smoke
```

## Launch Training

Feature-table datasets should use:

```text
--dataset-type feature_table
```

Fast AWS smoke run:

```powershell
python sagemaker/jobs/launch_job.py tch_features_v4_core_optical_climate `
  --dataset-type feature_table `
  --model-type ridge `
  --n-trials 1 `
  --categorical-mode controlled `
  --no-quantiles `
  --no-shap `
  --no-diagnostics `
  --image-uri 920572019712.dkr.ecr.us-east-1.amazonaws.com/tch-sagemaker-training:categorical-smoke
```

CatBoost native categorical run:

```powershell
python sagemaker/jobs/launch_job.py tch_features_v4_core_optical_climate `
  --dataset-type feature_table `
  --model-type catboost `
  --n-trials 20 `
  --categorical-mode native `
  --image-uri 920572019712.dkr.ecr.us-east-1.amazonaws.com/tch-sagemaker-training:latest
```

LightGBM controlled-dummy run:

```powershell
python sagemaker/jobs/launch_job.py tch_features_v4_core_optical_climate `
  --dataset-type feature_table `
  --model-type lightgbm `
  --n-trials 50 `
  --categorical-mode controlled `
  --image-uri 920572019712.dkr.ecr.us-east-1.amazonaws.com/tch-sagemaker-training:latest
```

## Outputs

Training outputs are written to:

```text
s3://ndvi-extraction/experiments/{dataset}/{model_type}/{job_name}/
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
metrics_by_lot_error.csv
metrics_by_tch_range.csv
predictions_by_lot.csv
split_metadata.json
feature_list.json
categorical_encoding.json
best_params.json
optuna_trials.csv
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

Use smoke jobs to validate pipeline mechanics, not model quality. A useful smoke confirms:

```text
S3 dataset loads
feature table contract is satisfied
categorical_encoding.json is written
feature_list.json has expected controlled dummies
metrics.json and predictions_by_lot.csv are produced
SageMaker job completes
```
