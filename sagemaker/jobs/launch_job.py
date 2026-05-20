"""
Submit a SageMaker training job.

Usage:
    python launch_job.py ml_dataset --image-uri <account>.dkr.ecr.<region>.amazonaws.com/tch-sagemaker-training:latest
    python launch_job.py ml_dataset --model-type random_forest --n-trials 30 --image-uri <image>
"""
import argparse
from datetime import datetime

import boto3
import sagemaker
from sagemaker.inputs import TrainingInput
from sagemaker.estimator import Estimator

from config import BUCKET, INSTANCE_TYPE, REGION, ROLE_ARN


def launch(
    dataset: str,
    model_type: str = "xgboost",
    dataset_type: str = "aggregated",
    target: str = "tch",
    n_trials: int = 50,
    partitioned: bool = False,
    walk_forward: bool = False,
    walk_forward_stability_penalty: float = 0.25,
    objective_mode: str = "auto",
    aggregate_penalty: float = 1.0,
    light_features: bool = True,
    one_hot_features: bool = True,
    categorical_mode: str = "controlled",
    quantiles: bool = True,
    shap: bool = True,
    diagnostics: bool = True,
    diagnostics_only: bool = False,
    skip_optuna: bool = False,
    max_run: int = 14400,
    max_wait: int = 14400,
    image_uri: str = None,
) -> str:
    if not image_uri:
        raise ValueError("image_uri is required. Build and push the custom training image, then pass --image-uri.")

    session = sagemaker.Session(boto_session=boto3.Session(region_name=REGION))

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    job_mode = "diagnostics" if diagnostics_only else model_type
    job_suffix = f"{job_mode}-{timestamp}".replace("_", "-")
    job_prefix_max = 63 - len("tch--") - len(job_suffix)
    dataset_slug = dataset.replace("_", "-")[:job_prefix_max]
    job_name = f"tch-{dataset_slug}-{job_suffix}"
    diagnostics = True if diagnostics_only else diagnostics

    hyperparameters = {
        "model-type": model_type,
        "dataset-type": dataset_type,
        "target": target,
        "n-trials": n_trials,
        "walk-forward": str(walk_forward).lower(),
        "walk-forward-stability-penalty": walk_forward_stability_penalty,
        "objective-mode": objective_mode,
        "aggregate-penalty": aggregate_penalty,
        "light-features": str(light_features).lower(),
        "one-hot-features": str(one_hot_features).lower(),
        "categorical-mode": categorical_mode,
        "quantiles": str(quantiles).lower(),
        "shap": str(shap).lower(),
        "diagnostics": str(diagnostics).lower(),
        "diagnostics-only": str(diagnostics_only).lower(),
        "skip-optuna": str(skip_optuna).lower(),
    }
    metric_definitions = [
        {"Name": "rmse", "Regex": "'rmse': ([0-9\\.]+)"},
        {"Name": "mae", "Regex": "'mae': ([0-9\\.]+)"},
        {"Name": "r2", "Regex": "'r2': ([0-9\\.]+)"},
    ]
    output_family = "diagnostics" if diagnostics_only else model_type
    output_path = f"s3://{BUCKET}/experiments/{dataset}/{output_family}/"

    estimator = Estimator(
        image_uri=image_uri,
        role=ROLE_ARN,
        instance_type=INSTANCE_TYPE,
        instance_count=1,
        sagemaker_session=session,
        use_spot_instances=True,
        max_wait=max_wait,
        max_run=max_run,
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
    print(f"Artifacts will be saved to: s3://{BUCKET}/experiments/{dataset}/{output_family}/{job_name}/")
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
    parser.add_argument("--walk-forward-stability-penalty", type=float, default=0.25)
    parser.add_argument("--objective-mode", default="auto", choices=["auto", "lot_rmse", "walk_forward_r2", "aggregate_tch_sum"])
    parser.add_argument("--aggregate-penalty", type=float, default=1.0, help="RMSE-equivalent penalty per raw zafra TCH-sum percentage-point error")
    parser.add_argument("--no-light-features", action="store_true", help="Disable light pandas-derived features for feature-table datasets")
    parser.add_argument("--categorical-mode", default="controlled", choices=["controlled", "native", "none"])
    parser.add_argument("--no-dummies", action="store_true", help="Keep categorical columns raw for CatBoost native categorical handling")
    parser.add_argument("--no-quantiles", action="store_true", help="Skip quantile/uncertainty models for faster baseline runs")
    parser.add_argument("--no-shap", action="store_true", help="Skip SHAP generation for faster baseline runs")
    parser.add_argument("--no-diagnostics", action="store_true", help="Skip feature diagnostics artifacts")
    parser.add_argument("--diagnostics-only", action="store_true", help="Run feature diagnostics and exit before tuning/training")
    parser.add_argument("--skip-optuna", action="store_true", help="Train with model defaults instead of running Optuna")
    parser.add_argument("--max-run", type=int, default=14400, help="Maximum training runtime in seconds")
    parser.add_argument("--max-wait", type=int, default=14400, help="Maximum total spot wait/runtime window in seconds")
    parser.add_argument("--image-uri", required=True, help="Custom SageMaker training image URI")
    args = parser.parse_args()
    launch(
        args.dataset,
        args.model_type,
        args.dataset_type,
        args.target,
        args.n_trials,
        args.partitioned,
        args.walk_forward,
        args.walk_forward_stability_penalty,
        args.objective_mode,
        args.aggregate_penalty,
        not args.no_light_features,
        not args.no_dummies,
        "native" if args.no_dummies else args.categorical_mode,
        not args.no_quantiles,
        not args.no_shap,
        not args.no_diagnostics,
        args.diagnostics_only,
        args.skip_optuna,
        args.max_run,
        args.max_wait,
        args.image_uri,
    )
