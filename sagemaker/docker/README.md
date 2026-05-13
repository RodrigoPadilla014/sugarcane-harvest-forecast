# TCH SageMaker Training Image

Custom training image for the TCH pipeline.

The managed SageMaker scikit-learn image installs dependencies at job startup.
That caused version conflicts around NumPy, CatBoost, SHAP, and Numba. This
image pins the full training environment so jobs are reproducible and start
faster.

## Build

From the repository root:

```powershell
docker build -f sagemaker/docker/Dockerfile -t tch-sagemaker-training:latest sagemaker
```

## Push To ECR

After Terraform creates the ECR repository:

```powershell
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$REGION = "us-east-1"
$REPO = "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/tch-sagemaker-training"

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
docker tag tch-sagemaker-training:latest "$REPO:latest"
docker push "$REPO:latest"
```

The launcher can then use the pushed image URI instead of the managed
SageMaker scikit-learn container.
