# EC2 Instance Runbook

This branch currently uses one reusable EC2 virtual computer for all training
stages.

## Instance Identity

```text
AWS account:     920572019712
Region:          us-east-1
Instance name:   data-processing
Instance ID:     i-011601455ec0ed137
Instance type:   m5.xlarge
CPU:             4 vCPU
RAM:             16 GiB
Root disk:       50 GiB gp3
Operating system: Ubuntu 24.04 x86_64
IAM profile:     EC2-S3-Access
Security group:  launch-wizard-1 (sg-01595344ed0e9644b)
Repository path: /home/ubuntu/sugarcane-harvest-forecast
Work root:       /home/ubuntu/tch-training
```

The instance is stopped between stages to avoid compute charges. Its EBS disk,
installed tools, repository, cached dataset, Docker image, and run artifacts
remain available while stopped.

## Installed Tools

The host has:

- Docker Engine;
- AWS CLI v2;
- Git;
- Python 3;
- standard Linux utilities required by `ec2/run_training.sh`.

The `ubuntu` user belongs to the `docker` group and can run Docker without
`sudo`.

## IAM Access

The instance profile currently provides:

- S3 access through `AmazonS3FullAccess`;
- ECR image pull access through `AmazonEC2ContainerRegistryReadOnly`;
- the existing inline SNS permission attached to `EC2-S3-Access`.

No permanent AWS access keys should be stored on the instance. AWS CLI and
Docker ECR authentication use temporary credentials from the instance profile.

## Start The Instance

Run locally with the default AWS profile:

```powershell
aws ec2 start-instances `
  --instance-ids i-011601455ec0ed137 `
  --region us-east-1

aws ec2 wait instance-status-ok `
  --instance-ids i-011601455ec0ed137 `
  --region us-east-1

aws ec2 describe-instances `
  --instance-ids i-011601455ec0ed137 `
  --region us-east-1 `
  --query "Reservations[0].Instances[0].PublicIpAddress" `
  --output text
```

The public IP may change each time the instance starts. Do not record it as
permanent configuration.

## SSH Access

The instance was configured using EC2 Instance Connect with a temporary SSH
key. The local IAM user needs:

```text
ec2-instance-connect:SendSSHPublicKey
```

scoped to this instance and the `ubuntu` OS user.

Generate a temporary key locally:

```powershell
$KEY = "$env:TEMP\tch-ec2-instance-connect"
ssh-keygen -t ed25519 -N '""' -f $KEY -C "tch-ec2-session"

$PUBLIC_IP = aws ec2 describe-instances `
  --instance-ids i-011601455ec0ed137 `
  --region us-east-1 `
  --query "Reservations[0].Instances[0].PublicIpAddress" `
  --output text

aws ec2-instance-connect send-ssh-public-key `
  --instance-id i-011601455ec0ed137 `
  --availability-zone us-east-1b `
  --instance-os-user ubuntu `
  --ssh-public-key "file://$KEY.pub" `
  --region us-east-1

ssh -i $KEY "ubuntu@$PUBLIC_IP"
```

EC2 Instance Connect keys expire quickly. Send the public key immediately
before opening SSH. Remove the temporary private and public key files after the
session.

## Repository And Runner

On the instance:

```bash
cd /home/ubuntu/sugarcane-harvest-forecast
git branch --show-current
bash ec2/run_training.sh diagnostics --dry-run
```

The expected branch is:

```text
ec2-training-runner
```

This working tree currently contains uncommitted pipeline changes deployed from
the local workspace. Do not run `git reset`, `git clean`, or a blind `git pull`
because that could remove the EC2 runner or current training changes.

## Run One Stage

Only after explicit authorization:

```bash
cd /home/ubuntu/sugarcane-harvest-forecast
bash ec2/run_training.sh diagnostics
```

Later stages remain separate commands:

```bash
bash ec2/run_training.sh baseline --exclude-features approved_feature_list
bash ec2/run_training.sh optuna --exclude-features approved_feature_list
```

The runner never starts another stage automatically.

## Monitor A Running Stage

From a second SSH session:

```bash
cd /home/ubuntu/sugarcane-harvest-forecast
bash ec2/monitor_training.sh
```

Run files are stored under:

```text
/home/ubuntu/tch-training/runs/<run-id>/
```

Artifacts are uploaded under:

```text
s3://ndvi-extraction/experiments-ec2/
```

## Stop The Instance

After the stage and artifact review:

```powershell
aws ec2 stop-instances `
  --instance-ids i-011601455ec0ed137 `
  --region us-east-1

aws ec2 wait instance-stopped `
  --instance-ids i-011601455ec0ed137 `
  --region us-east-1
```

Stopping preserves the disk but ends EC2 compute charges.

## Configurable Training Defaults

The defaults in `ec2/run_training.sh` are starting values, not permanent
constraints. They can be changed per invocation:

```bash
bash ec2/run_training.sh diagnostics \
  --dataset another_dataset \
  --image account.dkr.ecr.us-east-1.amazonaws.com/image:tag \
  --bucket another-bucket \
  --cpus 3 \
  --memory 12g \
  --shm-size 2g
```

They can also be changed through environment variables:

```bash
export TCH_DATASET="another_dataset"
export TCH_CPUS="3"
export TCH_MEMORY="12g"
export TCH_EXCLUDE_FEATURES="feature_a,feature_b"
bash ec2/run_training.sh baseline
```

The example variables are documented in `ec2/config.env.example`.

The stage definitions currently fix the approved experiment design:

- diagnostics-only for `diagnostics`;
- CatBoost baseline with walk-forward and no Optuna for `baseline`;
- CatBoost walk-forward with 20 Optuna trials for `optuna`;
- train/evaluation/scoring zafras from the agreed v9 configuration.

Change those experiment defaults in code only after explicit approval.
