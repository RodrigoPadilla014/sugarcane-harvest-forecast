"""
Submit a SageMaker training job.

Usage:
    python launch_job.py ml_dataset
    python launch_job.py ml_dataset --model-type random_forest --n-trials 30
"""
import argparse
from datetime import datetime
from pathlib import Path

import boto3
import sagemaker
from sagemaker.inputs import TrainingInput
from sagemaker.sklearn import SKLearn

from config import BUCKET, FRAMEWORK_VERSION, INSTANCE_TYPE, PYTHON_VERSION, REGION, ROLE_ARN

TRAINING_DIR = Path(__file__).resolve().parents[1] / "training"


def launch(dataset: str, model_type: str = "xgboost", target: str = "tch", n_trials: int = 50) -> str:
    session = sagemaker.Session(boto_session=boto3.Session(region_name=REGION))

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    job_name = f"tch-{dataset}-{model_type}-{timestamp}".replace("_", "-")

    estimator = SKLearn(
        entry_point="train.py",
        source_dir=str(TRAINING_DIR),
        role=ROLE_ARN,
        instance_type=INSTANCE_TYPE,
        instance_count=1,
        framework_version=FRAMEWORK_VERSION,
        py_version=PYTHON_VERSION,
        sagemaker_session=session,
        use_spot_instances=True,
        max_wait=7200,
        max_run=3600,
        hyperparameters={
            "model-type": model_type,
            "target": target,
            "n-trials": n_trials,
        },
        metric_definitions=[
            {"Name": "rmse", "Regex": "'rmse': ([0-9\\.]+)"},
            {"Name": "mae", "Regex": "'mae': ([0-9\\.]+)"},
            {"Name": "r2", "Regex": "'r2': ([0-9\\.]+)"},
        ],
        output_path=f"s3://{BUCKET}/experiments/{dataset}/{model_type}/",
    )

    train_input = TrainingInput(
        s3_data=f"s3://{BUCKET}/datasets/{dataset}.parquet",
        content_type="application/x-parquet",
    )

    estimator.fit({"train": train_input}, job_name=job_name, wait=False)
    print(f"Job submitted: {job_name}")
    print(f"Artifacts will be saved to: s3://{BUCKET}/experiments/{dataset}/{model_type}/{job_name}/")
    return job_name


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", help="Dataset name matching a parquet in s3://ndvi-extraction/datasets/")
    parser.add_argument("--model-type", default="xgboost", choices=["xgboost", "random_forest", "ridge"])
    parser.add_argument("--target", default="tch")
    parser.add_argument("--n-trials", type=int, default=50)
    args = parser.parse_args()
    launch(args.dataset, args.model_type, args.target, args.n_trials)
