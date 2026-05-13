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
from sagemaker.estimator import Estimator
from sagemaker.sklearn import SKLearn

from config import BUCKET, FRAMEWORK_VERSION, INSTANCE_TYPE, PYTHON_VERSION, REGION, ROLE_ARN

TRAINING_DIR = Path(__file__).resolve().parents[1] / "training"


def launch(
    dataset: str,
    model_type: str = "xgboost",
    dataset_type: str = "aggregated",
    target: str = "tch",
    n_trials: int = 50,
    partitioned: bool = False,
    walk_forward: bool = False,
    light_features: bool = True,
    shap: bool = True,
    diagnostics: bool = True,
    image_uri: str = None,
) -> str:
    session = sagemaker.Session(boto_session=boto3.Session(region_name=REGION))

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    job_name = f"tch-{dataset}-{model_type}-{timestamp}".replace("_", "-")

    hyperparameters = {
        "model-type": model_type,
        "dataset-type": dataset_type,
        "target": target,
        "n-trials": n_trials,
        "walk-forward": str(walk_forward).lower(),
        "light-features": str(light_features).lower(),
        "shap": str(shap).lower(),
        "diagnostics": str(diagnostics).lower(),
    }
    metric_definitions = [
        {"Name": "rmse", "Regex": "'rmse': ([0-9\\.]+)"},
        {"Name": "mae", "Regex": "'mae': ([0-9\\.]+)"},
        {"Name": "r2", "Regex": "'r2': ([0-9\\.]+)"},
    ]
    output_path = f"s3://{BUCKET}/experiments/{dataset}/{model_type}/"

    if image_uri:
        estimator = Estimator(
            image_uri=image_uri,
            role=ROLE_ARN,
            instance_type=INSTANCE_TYPE,
            instance_count=1,
            sagemaker_session=session,
            use_spot_instances=True,
            max_wait=7200,
            max_run=3600,
            hyperparameters=hyperparameters,
            metric_definitions=metric_definitions,
            output_path=output_path,
        )
    else:
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
            hyperparameters=hyperparameters,
            metric_definitions=metric_definitions,
            output_path=output_path,
        )

    dataset_s3_uri = f"s3://{BUCKET}/datasets/{dataset}/" if partitioned else f"s3://{BUCKET}/datasets/{dataset}.parquet"

    train_input = TrainingInput(
        s3_data=dataset_s3_uri,
        content_type="application/x-parquet",
    )

    estimator.fit({"train": train_input}, job_name=job_name, wait=False)
    print(f"Job submitted: {job_name}")
    print(f"Artifacts will be saved to: s3://{BUCKET}/experiments/{dataset}/{model_type}/{job_name}/")
    return job_name


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", help="Dataset name matching a parquet in the configured S3 datasets prefix")
    parser.add_argument("--model-type", default="xgboost", choices=["xgboost", "lightgbm", "catboost", "random_forest", "ridge"])
    parser.add_argument("--dataset-type", default="aggregated", choices=["aggregated", "feature_table", "preaggregated", "sequential"])
    parser.add_argument("--target", default="tch")
    parser.add_argument("--n-trials", type=int, default=50)
    parser.add_argument("--partitioned", action="store_true", help="Read dataset from s3://bucket/datasets/{dataset}/ parquet parts")
    parser.add_argument("--walk-forward", action="store_true")
    parser.add_argument("--no-light-features", action="store_true", help="Disable light pandas-derived features for feature-table datasets")
    parser.add_argument("--no-shap", action="store_true", help="Skip SHAP generation for faster baseline runs")
    parser.add_argument("--no-diagnostics", action="store_true", help="Skip feature diagnostics artifacts")
    parser.add_argument("--image-uri", default=None, help="Custom SageMaker training image URI")
    args = parser.parse_args()
    launch(
        args.dataset,
        args.model_type,
        args.dataset_type,
        args.target,
        args.n_trials,
        args.partitioned,
        args.walk_forward,
        not args.no_light_features,
        not args.no_shap,
        not args.no_diagnostics,
        args.image_uri,
    )
