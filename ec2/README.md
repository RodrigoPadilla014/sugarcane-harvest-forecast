# EC2 Training Runner

This folder contains the host-side runner used to train and score the final V10
TCH model in a reusable EC2 instance.

The runner executes exactly one stage per command:

```text
diagnostics
baseline
optuna
```

For the production V10 path, use `baseline` with:

```text
dataset:      tch_features_v10_productivity_history_snapshots
target mode:  residual_last_hist_tch
model type:   catboost
weight mode:  snapshot_historical_tch
weight cap:   1.25
```

## Host requirements

Recommended host:

```text
CPU:   4 vCPU or more
RAM:   16 GiB or more
Disk:  50 GiB gp3 or larger
OS:    Ubuntu 24.04 x86_64 or compatible
```

Required host tools:

```text
aws
docker
flock
python3
timeout
```

Use an EC2 instance profile/IAM role for AWS access. Do not put permanent AWS
keys on the instance.

## Storage layout

The default root is `$HOME/tch-training`:

```text
tch-training/
|-- datasets/                         Cached parquet datasets
|-- runs/
|   `-- <run-id>/
|       |-- input/
|       |-- output/
|       |-- model/
|       |-- logs/
|       |-- run_manifest.json
|       `-- run_status.json
`-- training.lock
```

Datasets and outputs survive container removal. Each execution receives a
unique run directory.

## Configuration

Optional local defaults:

```bash
cp ec2/config.env.example ec2/config.env
source ec2/config.env
```

`ec2/config.env` is ignored by Git. Keep host-specific values there, not in the
repository.

The runner can build the default ECR image URI from the active AWS account. You
can also set `TCH_IMAGE` explicitly.

Dry run:

```bash
bash ec2/run_training.sh baseline --dry-run
```

Production baseline:

```bash
bash ec2/run_training.sh baseline \
  --dataset tch_features_v10_productivity_history_snapshots \
  --target-mode residual_last_hist_tch \
  --model-type catboost \
  --weight-mode snapshot_historical_tch \
  --weight-max-multiplier 1.25 \
  --partitioned
```

## Monitoring

From a second SSH session:

```bash
bash ec2/monitor_training.sh
```

The runner samples container CPU/RAM and host memory/load into the run's
`logs/` directory.

## Failure behavior

If training fails:

- the runner records the exit code;
- logs and partial artifacts remain in the run directory;
- available artifacts are uploaded unless `--skip-upload` is set;
- no retry or next stage is started automatically.

## Security notes

- Restrict SSH access to trusted users or use Session Manager / Instance
  Connect.
- Do not commit cloud account IDs, SSH keys, passwords, `.env` files, or
  database connection strings.
- Stop the EC2 instance when it is not needed.
- Keep only one active training container; the runner enforces this with
  `flock`.
