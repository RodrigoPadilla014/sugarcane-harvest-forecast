# TCH Prediction Harvest Season

Production-oriented pipeline for estimating sugarcane TCH and aggregate cane
volume for a future productive zafra.

The current model version is V10. It uses a residual target anchored on the
latest historical lot productivity:

```text
delta_tch = actual_tch - last_hist_tch
pred_tch  = last_hist_tch + predicted_delta_tch
```

This design keeps the model tied to each lot's known productivity history while
allowing agronomic, climate, optical, radar, ENSO, variety, cut, soil, and
snapshot-age features to explain expected movement from history.

## Repository layout

```text
ec2/         EC2 runner for reproducible training and artifact upload
queries/    Active production SQL dataset definition
sagemaker/  Dataset upload, Docker image, model training, metrics, diagnostics
```

Local-only folders such as `credentials/`, `.tmp/`, dashboards, archived
experiments, and generated artifacts are ignored by Git.

## Active dataset

Dataset key:

```text
tch_features_v10_productivity_history_snapshots
```

Committed SQL:

```text
queries/active/v10/dataset/tch_v10_productivity_snapshot_spine.sql
queries/active/v10/dataset/tch_features_v10_productivity_history_snapshots.sql
```

Upload the dataset as partitioned parquet:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v10_productivity_history_snapshots `
  --chunked `
  --chunksize 50000 `
  --replace
```

The SQL is snapshot-aware. Historical lot-cycles are scored at fixed ages
(`180`, `210`, `240`, `270`, `300`, `340` days), while future scoring only
includes lots that are old enough to have a valid snapshot. Pending lots remain
outside the scored population until they become eligible.

## Model design

Final production candidate:

```text
Model:        CatBoost
Target:       residual_last_hist_tch
Weighting:    snapshot_historical_tch
Weight cap:   1.25
Horizon:      day 180 as the principal selection horizon
```

The residual formulation was selected to address systematic bias that appeared
when modeling absolute TCH directly. Instead of asking the model to relearn
each lot's productivity level from scratch, the pipeline predicts the movement
relative to the latest historical TCH. Moderate historical-TCH weighting is
used to improve behavior in the upper productivity range without introducing a
hard high-yield rule.

The pipeline evaluates:

- row-level RMSE and MAE;
- aggregate metric-ton error;
- bias by zafra, TCH band, estrato, area group, variety, and cut number;
- walk-forward temporal stability;
- high-productivity behavior;
- uncertainty calibration and practical prediction ranges.

## Training and scoring

The EC2 runner executes one explicit stage per command:

```text
diagnostics
baseline
optuna
```

The final V10 model is run through the baseline stage with the residual target
and selected weighting configuration. Optuna and additional challengers were
used during model development, but the production path should stay on the V10
CatBoost residual configuration unless a future validation cycle promotes a new
model.

Dry run:

```bash
bash ec2/run_training.sh baseline --dry-run
```

Production-style baseline:

```bash
bash ec2/run_training.sh baseline \
  --dataset tch_features_v10_productivity_history_snapshots \
  --target-mode residual_last_hist_tch \
  --model-type catboost \
  --weight-mode snapshot_historical_tch \
  --weight-max-multiplier 1.25 \
  --partitioned
```

Important outputs:

```text
metrics.json
evaluation_metrics_by_zafra.csv
evaluation_predictions.csv
future_scoring_predictions.csv
future_scoring_by_zafra.csv
walk_forward_metrics.csv
metrics_by_snapshot_day.csv
metrics_by_estrato.csv
metrics_by_tch_range.csv
training_weight_diagnostics.csv
split_metadata.json
run_manifest.json
run_status.json
```

## Results summary

V10 improved the production workflow in three ways:

1. It made the forecast updateable as more lots become old enough to score.
2. It reduced dependence on a purely absolute TCH forecast by anchoring on lot
   history.
3. It added diagnostics for aggregate error, high-productivity behavior,
   temporal stability, and uncertainty.

The retained model showed competitive row-level accuracy and better aggregate
behavior than the earlier absolute-TCH design. Calibration experiments did not
justify replacing the uncalibrated central forecast, so the central forecast is
kept as the model output and uncertainty is communicated separately.

For uncertainty:

- native P10/P90 intervals are retained as model diagnostics;
- a practical lot-level range is communicated as an approximate plus/minus TCH
  band around the central prediction;
- aggregate uncertainty is reported separately from lot-level uncertainty;
- extreme low/high productivity lots should be treated with extra caution.

## Docker image

Build and push the training image from the repository root:

```bash
docker build -f sagemaker/docker/Dockerfile \
  -t tch-sagemaker-training:latest sagemaker

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="us-east-1"
REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
IMAGE="$REGISTRY/tch-sagemaker-training:latest"

aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"
docker tag tch-sagemaker-training:latest "$IMAGE"
docker push "$IMAGE"
```

The EC2 runner can infer the default ECR image from the current AWS account, or
you can set `TCH_IMAGE` explicitly.

## Security

- Do not commit credentials, SSH keys, `.env` files, database passwords, or
  cloud account-specific secrets.
- Keep local credentials under `credentials/`.
- Use IAM roles/instance profiles for AWS access where possible.
- Keep generated artifacts, downloaded datasets, and dashboards outside the
  committed model repository unless intentionally publishing them elsewhere.
