"""
SageMaker training entry point.

Runs:
parquet load -> feature preparation -> temporal split -> Optuna ->
final train -> metrics -> SHAP -> artifacts.
"""
import argparse
import json
import os

import joblib
import optuna
import pandas as pd
from sklearn.impute import SimpleImputer
from sklearn.pipeline import make_pipeline

from feature_diagnostics import save_feature_diagnostics
from features import build_dataset
from metrics import regression_metrics, zafra_metrics
from models import build_model, suggest_params
from shap_utils import save_shap_values
from splits import temporal_split, walk_forward_splits

optuna.logging.set_verbosity(optuna.logging.WARNING)


def log(message: str) -> None:
    print(message, flush=True)


def parse_bool(value):
    if isinstance(value, bool):
        return value
    return value.lower() in {"1", "true", "yes", "y"}


def load_hyperparameter_defaults() -> dict:
    path = "/opt/ml/input/config/hyperparameters.json"
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def hyperparameter(defaults: dict, name: str, default, cast=None):
    if name not in defaults:
        return default
    value = defaults[name]
    if cast is None:
        return value
    return cast(value)


def load_parquet_dir(data_dir: str) -> pd.DataFrame:
    log(f"Scanning parquet files in {data_dir}")
    parquet_paths = []
    for root, _, files in os.walk(data_dir):
        for file in files:
            if file.endswith(".parquet"):
                parquet_paths.append(os.path.join(root, file))
    if not parquet_paths:
        raise FileNotFoundError(f"No parquet files found in {data_dir}")

    log(f"Found {len(parquet_paths):,} parquet files")
    return pd.concat(
        (pd.read_parquet(path) for path in sorted(parquet_paths)),
        ignore_index=True,
    )


def build_estimator(model_type: str, params: dict):
    model = build_model(model_type, params)
    if model_type in {"ridge", "random_forest"}:
        return make_pipeline(
            SimpleImputer(strategy="median", keep_empty_features=True),
            model,
        )
    return model


def fit_with_optuna(
    X_train: pd.DataFrame,
    y_train: pd.Series,
    X_validation: pd.DataFrame,
    y_validation: pd.Series,
    model_type: str,
    n_trials: int,
):
    def objective(trial):
        params = suggest_params(trial, model_type)
        model = build_estimator(model_type, params)
        model.fit(X_train, y_train)
        pred = model.predict(X_validation)
        return regression_metrics(y_validation, pred)["rmse"]

    study = optuna.create_study(direction="minimize")
    study.optimize(objective, n_trials=n_trials)
    return study.best_params, study


def evaluate_split(model, X: pd.DataFrame, y: pd.Series, metadata: pd.DataFrame, split: str):
    pred = model.predict(X)
    metrics = regression_metrics(y, pred)
    zafra_df = zafra_metrics(metadata, y, pred, split=split)
    return metrics, zafra_df


def run_walk_forward(
    X: pd.DataFrame,
    y: pd.Series,
    metadata: pd.DataFrame,
    model_type: str,
    params: dict,
) -> pd.DataFrame:
    rows = []
    for validation_zafra, train_idx, validation_idx in walk_forward_splits(metadata):
        train_idx = train_idx.intersection(X.index)
        validation_idx = validation_idx.intersection(X.index)
        if train_idx.empty or validation_idx.empty:
            continue

        model = build_estimator(model_type, params)
        model.fit(X.loc[train_idx], y.loc[train_idx])
        pred = model.predict(X.loc[validation_idx])
        fold_metrics = regression_metrics(y.loc[validation_idx], pred)
        fold_metrics["validation_zafra"] = validation_zafra
        fold_metrics["train_rows"] = int(len(train_idx))
        fold_metrics["validation_rows"] = int(len(validation_idx))
        rows.append(fold_metrics)
    return pd.DataFrame(rows)


def main():
    hp_defaults = load_hyperparameter_defaults()
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-type", type=str, default=hyperparameter(hp_defaults, "model-type", "xgboost"))
    parser.add_argument(
        "--dataset-type",
        type=str,
        default=hyperparameter(hp_defaults, "dataset-type", "aggregated"),
        choices=["aggregated", "feature_table", "preaggregated", "sequential"],
    )
    parser.add_argument("--target", type=str, default=hyperparameter(hp_defaults, "target", "tch"))
    parser.add_argument("--n-trials", type=int, default=hyperparameter(hp_defaults, "n-trials", 50, int))
    parser.add_argument("--walk-forward", type=parse_bool, default=hyperparameter(hp_defaults, "walk-forward", False, parse_bool))
    parser.add_argument("--light-features", type=parse_bool, default=hyperparameter(hp_defaults, "light-features", True, parse_bool))
    parser.add_argument("--shap", type=parse_bool, default=hyperparameter(hp_defaults, "shap", True, parse_bool))
    parser.add_argument("--diagnostics", type=parse_bool, default=hyperparameter(hp_defaults, "diagnostics", True, parse_bool))
    args, unknown_args = parser.parse_known_args()
    if unknown_args:
        log(f"Ignoring unknown arguments: {unknown_args}")

    data_dir = os.environ.get("SM_CHANNEL_TRAIN", "/opt/ml/input/data/train")
    model_dir = os.environ.get("SM_MODEL_DIR", "/opt/ml/model")
    output_dir = os.environ.get("SM_OUTPUT_DATA_DIR", "/opt/ml/output/data")
    os.makedirs(model_dir, exist_ok=True)
    os.makedirs(output_dir, exist_ok=True)

    input_df = load_parquet_dir(data_dir)
    log(f"Loaded input dataframe: rows={len(input_df):,}, columns={len(input_df.columns):,}")

    log(f"Building {args.dataset_type} feature matrix")
    X, y, metadata = build_dataset(
        input_df,
        dataset_type=args.dataset_type,
        target=args.target,
        light_features=args.light_features,
    )
    X = X.apply(pd.to_numeric, errors="coerce")
    log(f"Built feature matrix: rows={len(X):,}, features={X.shape[1]:,}")

    log("Creating temporal split")
    train_idx, validation_idx, test_idx = temporal_split(metadata)
    train_idx = train_idx.intersection(X.index)
    validation_idx = validation_idx.intersection(X.index)
    test_idx = test_idx.intersection(X.index)

    if train_idx.empty or validation_idx.empty or test_idx.empty:
        raise ValueError(
            "Temporal split produced an empty split: "
            f"train={len(train_idx)}, validation={len(validation_idx)}, test={len(test_idx)}"
        )

    X_train, y_train = X.loc[train_idx], y.loc[train_idx]
    X_validation, y_validation = X.loc[validation_idx], y.loc[validation_idx]
    X_test, y_test = X.loc[test_idx], y.loc[test_idx]

    log(
        "Dataset: "
        f"input_rows={len(input_df):,}, matrix_rows={len(X):,}, features={X.shape[1]:,}, "
        f"train={len(train_idx):,}, validation={len(validation_idx):,}, test={len(test_idx):,}"
    )

    if args.diagnostics:
        log("Saving feature diagnostics")
        save_feature_diagnostics(X, train_idx, validation_idx, test_idx, output_dir)
    else:
        log("Skipping feature diagnostics")

    log(f"Starting Optuna: model_type={args.model_type}, n_trials={args.n_trials}")
    best_params, study = fit_with_optuna(
        X_train,
        y_train,
        X_validation,
        y_validation,
        model_type=args.model_type,
        n_trials=args.n_trials,
    )
    log(f"Best params: {best_params}")

    log("Training final model on train split")
    model = build_estimator(args.model_type, best_params)
    model.fit(X_train, y_train)

    metrics_by_split = {}
    zafra_frames = []
    for split, split_idx in {
        "train": train_idx,
        "validation": validation_idx,
        "test": test_idx,
    }.items():
        split_metrics, split_zafra = evaluate_split(
            model,
            X.loc[split_idx],
            y.loc[split_idx],
            metadata,
            split=split,
        )
        metrics_by_split[split] = split_metrics
        zafra_frames.append(split_zafra)
        log(f"{split} metrics: {split_metrics}")

    metrics_by_zafra = pd.concat(zafra_frames, ignore_index=True)

    walk_forward_metrics = pd.DataFrame()
    if args.walk_forward:
        walk_forward_metrics = run_walk_forward(X, y, metadata, args.model_type, best_params)
        log(f"Walk-forward metrics: {walk_forward_metrics.to_dict(orient='records')}")

    if args.shap:
        log("Generating SHAP artifacts if available")
        save_shap_values(model, args.model_type, X.loc[test_idx], output_dir)
    else:
        log("Skipping SHAP artifacts")

    log("Saving artifacts")
    joblib.dump(model, os.path.join(model_dir, "model.joblib"))
    metrics_by_zafra.to_csv(os.path.join(output_dir, "metrics_by_zafra.csv"), index=False)
    if not walk_forward_metrics.empty:
        walk_forward_metrics.to_csv(os.path.join(output_dir, "walk_forward_metrics.csv"), index=False)

    with open(os.path.join(output_dir, "metrics.json"), "w") as f:
        json.dump(metrics_by_split, f, indent=2)
    with open(os.path.join(output_dir, "best_params.json"), "w") as f:
        json.dump(best_params, f, indent=2)
    with open(os.path.join(output_dir, "feature_list.json"), "w") as f:
        json.dump(list(X.columns), f, indent=2)
    with open(os.path.join(output_dir, "split_metadata.json"), "w") as f:
        json.dump(
            {
                "dataset_type": args.dataset_type,
                "model_type": args.model_type,
                "target": args.target,
                "input_rows": int(len(input_df)),
                "matrix_rows": int(len(X)),
                "feature_count": int(X.shape[1]),
                "light_features": bool(args.light_features),
                "shap": bool(args.shap),
                "diagnostics": bool(args.diagnostics),
                "train_rows": int(len(train_idx)),
                "validation_rows": int(len(validation_idx)),
                "test_rows": int(len(test_idx)),
                "train_zafras": sorted(metadata.set_index("cod_cg_zafra").loc[train_idx, "zafra_norm"].dropna().unique()),
                "validation_zafras": sorted(metadata.set_index("cod_cg_zafra").loc[validation_idx, "zafra_norm"].dropna().unique()),
                "test_zafras": sorted(metadata.set_index("cod_cg_zafra").loc[test_idx, "zafra_norm"].dropna().unique()),
            },
            f,
            indent=2,
        )

    log("Artifacts saved.")


if __name__ == "__main__":
    main()
