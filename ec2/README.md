# EC2 Training Runner

This branch runs the TCH training container directly on one EC2 host. It keeps
the existing training code and Docker image, but replaces the SageMaker job
lifecycle with an explicit host-side runner.

The exact reusable EC2 instance, start/stop commands, SSH procedure, and host
state are documented in:

```text
ec2/INSTANCE.md
```

The runner executes exactly one stage per command:

```text
diagnostics -> review and approval
baseline    -> review and approval
optuna      -> final comparison
```

It never advances to the next stage automatically.

## Host Requirements

Recommended starting host:

```text
EC2 instance: m5.xlarge
CPU:          4 vCPU
RAM:          16 GiB
Disk:         50 GiB gp3 or larger
OS:           Ubuntu 24.04 x86_64
```

The default container limit is 4 CPUs and 14 GiB RAM, leaving memory for the
host OS. Docker swap is disabled by setting the memory+swap limit equal to the
memory limit.

Required host commands:

```text
aws
docker
flock
python3
timeout
```

The EC2 instance profile should have:

- read access to `s3://ndvi-extraction/datasets/*`;
- write access to `s3://ndvi-extraction/experiments-ec2/*`;
- ECR authorization and pull access for `tch-sagemaker-training`.

Use an EC2 IAM role rather than permanent AWS credentials on the host. The AWS
CLI automatically obtains temporary credentials from the instance profile.

## Storage Layout

The default root is `$HOME/tch-training`:

```text
tch-training/
|-- datasets/                         Cached parquet datasets
|-- runs/
|   `-- <run-id>/
|       |-- input/                    Read-only container input
|       |-- output/                   Metrics and diagnostics
|       |-- model/                    Serialized model files
|       |-- logs/                     Training and resource logs
|       |-- run_manifest.json
|       `-- run_status.json
`-- training.lock                    Prevents concurrent training runs
```

Datasets and outputs are outside the Docker image and survive container
removal. Every execution receives a unique run directory.

## Configuration

Optionally load the example configuration:

```bash
cp ec2/config.env.example ec2/config.env
source ec2/config.env
```

Do not put AWS access keys in this file.

Dataset, image, bucket, resource limits, and approved exclusions can be changed
with command-line flags or environment variables. The train/evaluation/scoring
design and stage behavior stay fixed unless the runner code is deliberately
changed.

Before the first real run, validate the resolved command:

```bash
bash ec2/run_training.sh diagnostics --dry-run
```

## Stage 1: Diagnostics

```bash
bash ec2/run_training.sh diagnostics
```

This runs the active v9 partitioned dataset without feature exclusions and
uploads artifacts under:

```text
s3://ndvi-extraction/experiments-ec2/
  tch_features_v9_productivity_snapshots/diagnostics/<run-id>/
```

Analyze the artifacts and obtain explicit pruning approval before continuing.

## Approved Feature Exclusions

Feature exclusions affect only the in-memory model matrix. They do not modify
the v9 parquet parts or SQL.

```bash
bash ec2/run_training.sh baseline \
  --exclude-features feature_a,feature_b
```

An unknown feature name fails the run, preventing silent pruning typos.

## Stage 2: Baseline

Run only after diagnostics and pruning approval:

```bash
bash ec2/run_training.sh baseline \
  --exclude-features approved_feature_a,approved_feature_b
```

The baseline uses CatBoost defaults, walk-forward within train, aggregate TCH
objective, diagnostics, SHAP, uncertainty intervals, evaluation metrics, and
future scoring.

## Stage 3: Optuna

Run only after explicit authorization:

```bash
bash ec2/run_training.sh optuna \
  --exclude-features approved_feature_a,approved_feature_b
```

Optuna runs 20 trials and uses walk-forward only inside the configured train
zafras. Evaluation zafras remain outside fitting and tuning. The `2026_2027`
scoring rows generate predictions without error metrics.

## Monitoring

From a second SSH session:

```bash
bash ec2/monitor_training.sh
```

The main runner also samples container CPU/RAM and host memory/load every 15
seconds into the run's `logs/` directory.

## Failure Behavior

If training fails:

- the runner records the exit code;
- logs and partial artifacts remain in the run directory;
- available artifacts are uploaded to S3;
- no retry or next stage is started automatically.

The stage timeout is four hours for diagnostics/baseline and six hours for
Optuna. A timed-out container is stopped before artifacts are uploaded.

## Image Updates

Build and push from the repository root:

```bash
docker build -f sagemaker/docker/Dockerfile \
  -t tch-sagemaker-training:latest sagemaker

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="us-east-1"
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
IMAGE="$REGISTRY/tch-sagemaker-training:latest"

aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"
docker tag tch-sagemaker-training:latest "$IMAGE"
docker push "$IMAGE"
```

Each run records the local image ID and repository digest in
`run_manifest.json`.

## Security Notes

- Restrict SSH port 22 to trusted IP ranges or use Session Manager.
- Do not store access keys in the repository or on the instance.
- Stop the EC2 instance when it is not needed.
- Keep only one active training container; the runner enforces this with
  `flock` and the fixed container name `tch-training-active`.
