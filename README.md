# TCH Prediction Harvest Season

Pipeline to predict TCH by lot/harvest season and support harvest-season production estimates from SQL-aggregated datasets.

## Current Workflow

The main workflow uses a pre-aggregated feature table:

```text
queries/aggregated/tch_aggregated_features_v1.sql
```

This SQL creates one row per `cod_cg_zafra` from `tch_raw_longitudinal`, preserving the cycle logic already computed in the raw longitudinal view.

Minimum dataset contract:

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

`tch` is the plain target. `area` and `tc` are retained for metadata, reporting, and downstream production estimates; they are not used to transform the target.

## Dataset In S3

Expected dataset location:

```text
s3://<bucket>/datasets/tch_aggregated_features_v1.parquet
```

Expected validation checks after dataset creation:

```text
one row per cod_cg_zafra
no duplicate cod_cg_zafra rows
no nulls in tch/zafra_norm/area
```

## Training Image

The custom SageMaker image is stored in ECR:

```text
<account-id>.dkr.ecr.<region>.amazonaws.com/tch-sagemaker-training:latest
```

Get the exact image digest from ECR when a run needs to be audited:

```powershell
aws ecr describe-images `
  --repository-name tch-sagemaker-training `
  --image-ids imageTag=latest `
  --query "imageDetails[0].imageDigest" `
  --output text
```

If anything changes under `sagemaker/training/`, rebuild and push the image:

```powershell
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$REGION = "<region>"
$REPO = "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/tch-sagemaker-training"

docker build -t "$REPO:latest" -f sagemaker/docker/Dockerfile sagemaker
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
docker push "$REPO:latest"
```

## Upload A Dataset

`upload_dataset.py` looks for SQL files in:

```text
queries/datasets/
queries/aggregated/
queries/
```

Regenerate and upload the aggregated dataset:

```powershell
python sagemaker/jobs/upload_dataset.py tch_aggregated_features_v1
```

## Launch Training

Aggregated feature-table datasets must be launched with:

```text
--dataset-type feature_table
```

Full LightGBM example with Optuna, SHAP, and feature diagnostics:

```powershell
python sagemaker/jobs/launch_job.py tch_aggregated_features_v1 `
  --dataset-type feature_table `
  --model-type lightgbm `
  --n-trials 10 `
  --image-uri <account-id>.dkr.ecr.<region>.amazonaws.com/tch-sagemaker-training:latest
```

Fast run without SHAP:

```powershell
python sagemaker/jobs/launch_job.py tch_aggregated_features_v1 `
  --dataset-type feature_table `
  --model-type lightgbm `
  --n-trials 10 `
  --no-shap `
  --image-uri <account-id>.dkr.ecr.<region>.amazonaws.com/tch-sagemaker-training:latest
```

## Artifacts

Training outputs are written to:

```text
s3://<bucket>/experiments/{dataset}/{model_type}/{job_name}/
```

Main SageMaker outputs:

```text
output/model.tar.gz
output/output.tar.gz
```

Expected files inside `output.tar.gz`:

```text
metrics.json
metrics_by_zafra.csv
split_metadata.json
feature_list.json
feature_importance_shap.csv
shap_values.parquet
feature_missing_rate.csv
feature_stability_by_split.csv
feature_correlation_pairs.csv
feature_pruning_recommendations.csv
best_params.json
```

## Modeling Notes

The end-to-end workflow is designed to generate the evidence needed for feature pruning:

```text
SHAP importance
feature correlation
missing rate
train vs validation/test stability
```

Use those diagnostics to decide whether to create a compact `v2` feature table or to exclude feature families in the training workflow.
