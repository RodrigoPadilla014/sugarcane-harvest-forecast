# EC2 Instance Runbook Template

This file documents the expected EC2 setup without storing account-specific or
security-sensitive values in Git.

Keep concrete instance IDs, public IPs, security group IDs, and temporary SSH
material in a private note or local ignored file, not in the repository.

## Expected instance

```text
Region:          <aws-region>
Instance name:   <training-instance-name>
Instance ID:     <instance-id>
Instance type:   m5.xlarge or larger
Root disk:       50 GiB gp3 or larger
OS:              Ubuntu 24.04 x86_64 or compatible
IAM profile:     role with S3 dataset/artifact access and ECR pull access
Repository path: /home/ubuntu/sugarcane-harvest-forecast
Work root:       /home/ubuntu/tch-training
```

The instance should be stopped between runs to avoid unnecessary compute cost.
Stopping preserves the EBS disk, cached datasets, Docker images, and prior run
artifacts.

## Start and connect

Start the instance with AWS CLI or the AWS console, then wait until instance
status checks pass.

If using EC2 Instance Connect, send a temporary SSH public key immediately
before connecting. Remove temporary key files after the session.

```bash
ssh ubuntu@<public-ip-or-private-dns>
```

## Repository and runner

On the instance:

```bash
cd /home/ubuntu/sugarcane-harvest-forecast
git branch --show-current
bash ec2/run_training.sh baseline --dry-run
```

Do not run destructive commands such as `git reset --hard` or `git clean`
unless you intentionally want to discard local run state.

## Run final V10 baseline

```bash
bash ec2/run_training.sh baseline \
  --dataset tch_features_v10_productivity_history_snapshots \
  --target-mode residual_last_hist_tch \
  --model-type catboost \
  --weight-mode snapshot_historical_tch \
  --weight-max-multiplier 1.25 \
  --partitioned
```

## Stop the instance

After artifacts are uploaded and reviewed, stop the instance with AWS CLI or
the AWS console.
