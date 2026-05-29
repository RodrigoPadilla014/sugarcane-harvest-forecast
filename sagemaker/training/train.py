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
import numpy as np
import optuna
import pandas as pd
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.impute import SimpleImputer
from sklearn.pipeline import make_pipeline

from categorical_encoding import (
    CATEGORICAL_MODE_NATIVE,
    CATEGORICAL_MODES,
    categorical_feature_columns,
    fit_transform_categorical_features,
    resolve_categorical_mode,
    save_categorical_encoding_state,
    validate_categorical_mode_for_model,
)
from feature_diagnostics import save_feature_diagnostics
from features import build_dataset
from metrics import (
    lot_error_metrics,
    lot_predictions,
    aggregate_zafra_metrics,
    quantile_interval_metrics,
    regression_metrics,
    tail_error_report,
    tch_range_metrics,
    zafra_metrics,
    zafra_quantile_metrics,
)
from models import build_model, suggest_params
from shap_utils import save_shap_values
from splits import temporal_split, walk_forward_splits

optuna.logging.set_verbosity(optuna.logging.WARNING)
QUANTILE_ALPHAS = (0.10, 0.50, 0.90)
OBJECTIVE_MODES = {"auto", "lot_rmse", "walk_forward_r2", "aggregate_tch_sum"}


def log(message: str) -> None:
    print(message, flush=True)


def parse_bool(value):
    if isinstance(value, bool):
        return value
    return value.lower() in {"1", "true", "yes", "y"}


def parse_csv_list(value) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [part.strip() for part in str(value).split(",") if part.strip()]


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


def resolve_objective_mode(objective_mode: str, walk_forward: bool) -> str:
    if objective_mode == "auto":
        return "walk_forward_r2" if walk_forward else "lot_rmse"
    return objective_mode


def aggregate_tch_sum_pct_diff(y_true: pd.Series, y_pred) -> float:
    actual_sum = float(np.sum(y_true))
    pred_sum = float(np.sum(y_pred))
    if actual_sum == 0:
        return 0.0
    return 100.0 * (pred_sum - actual_sum) / actual_sum


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


def prepare_features_for_model(
    X: pd.DataFrame,
    model_type: str,
    categorical_mode: str,
) -> pd.DataFrame:
    if categorical_mode == CATEGORICAL_MODE_NATIVE:
        validate_categorical_mode_for_model(categorical_mode, model_type)
        return X.copy()
    return X.apply(pd.to_numeric, errors="coerce")


def fit_model(model, model_type: str, X: pd.DataFrame, y: pd.Series, categorical_mode: str):
    if model_type == "catboost" and categorical_mode == CATEGORICAL_MODE_NATIVE:
        cat_cols = categorical_feature_columns(X)
        model.fit(X, y, cat_features=cat_cols)
    else:
        model.fit(X, y)
    return model


def build_quantile_estimator(model_type: str, params: dict, alpha: float):
    if model_type == "lightgbm":
        quantile_params = dict(params)
        quantile_params.update(
            {
                "objective": "quantile",
                "alpha": alpha,
            }
        )
        return build_estimator(model_type, quantile_params)

    if model_type == "catboost":
        quantile_params = dict(params)
        quantile_params["loss_function"] = f"Quantile:alpha={alpha}"
        return build_estimator(model_type, quantile_params)

    return make_pipeline(
        SimpleImputer(strategy="median", keep_empty_features=True),
        GradientBoostingRegressor(
            loss="quantile",
            alpha=alpha,
            n_estimators=300,
            learning_rate=0.05,
            max_depth=3,
            random_state=42,
        ),
    )


def fit_quantile_models(
    X_train: pd.DataFrame,
    y_train: pd.Series,
    model_type: str,
    params: dict,
    categorical_mode: str,
    quantile_alphas=QUANTILE_ALPHAS,
):
    if model_type == "random_forest":
        return {}

    models = {}
    for alpha in quantile_alphas:
        model = build_quantile_estimator(model_type, params, alpha)
        fit_model(model, model_type, X_train, y_train, categorical_mode)
        models[alpha] = model
    return models


def random_forest_quantile_predictions(model, X: pd.DataFrame, alpha: float) -> np.ndarray:
    forest = model
    forest_X = X
    if hasattr(model, "named_steps"):
        imputer = model.named_steps["simpleimputer"]
        forest = model.named_steps["randomforestregressor"]
        forest_X = imputer.transform(X)

    tree_predictions = np.column_stack([tree.predict(forest_X) for tree in forest.estimators_])
    return np.quantile(tree_predictions, alpha, axis=1)


def predict_quantiles(
    base_model,
    model_type: str,
    quantile_models: dict,
    X: pd.DataFrame,
    y: pd.Series,
    metadata: pd.DataFrame,
    split: str,
) -> pd.DataFrame:
    df = metadata.set_index("cod_cg_zafra").loc[y.index].copy()
    df.index.name = "cod_cg_zafra"
    df = df.reset_index()
    df["split"] = split
    df["actual_tch"] = y.to_numpy()
    for alpha in QUANTILE_ALPHAS:
        percentile = int(round(alpha * 100))
        if model_type == "random_forest":
            df[f"pred_tch_p{percentile}"] = random_forest_quantile_predictions(base_model, X, alpha)
        else:
            df[f"pred_tch_p{percentile}"] = quantile_models[alpha].predict(X)

    ordered_cols = [
        "split",
        "cod_cg_zafra",
        "cod_cg",
        "zafra_norm",
        "area",
        "actual_tch",
        "pred_tch_p10",
        "pred_tch_p50",
        "pred_tch_p90",
    ]
    return df[[col for col in ordered_cols if col in df.columns]]


def fit_with_optuna(
    X_train: pd.DataFrame,
    y_train: pd.Series,
    X_validation: pd.DataFrame,
    y_validation: pd.Series,
    X: pd.DataFrame,
    y: pd.Series,
    metadata: pd.DataFrame,
    model_type: str,
    n_trials: int,
    walk_forward: bool,
    stability_penalty: float,
    categorical_mode: str,
    objective_mode: str,
    aggregate_penalty: float,
):
    walk_forward_folds = walk_forward_splits(metadata) if walk_forward else []
    resolved_objective_mode = resolve_objective_mode(objective_mode, walk_forward)

    def objective(trial):
        params = suggest_params(trial, model_type)

        if walk_forward:
            fold_scores = []
            fold_rmses = []
            fold_aggregate_pct_diffs = []
            for validation_zafra, train_idx, validation_idx in walk_forward_folds:
                train_idx = train_idx.intersection(X.index)
                validation_idx = validation_idx.intersection(X.index)
                if train_idx.empty or validation_idx.empty:
                    continue

                model = build_estimator(model_type, params)
                fit_model(model, model_type, X.loc[train_idx], y.loc[train_idx], categorical_mode)
                pred = model.predict(X.loc[validation_idx])
                fold_metrics = regression_metrics(y.loc[validation_idx], pred)
                fold_scores.append(fold_metrics["r2"])
                fold_rmses.append(fold_metrics["rmse"])
                fold_aggregate_pct_diffs.append(aggregate_tch_sum_pct_diff(y.loc[validation_idx], pred))

            if not fold_scores:
                raise ValueError("Walk-forward objective produced no valid folds")

            mean_r2 = float(np.mean(fold_scores))
            std_r2 = float(np.std(fold_scores))
            mean_rmse = float(np.mean(fold_rmses))
            mean_abs_aggregate_pct_diff = float(np.mean(np.abs(fold_aggregate_pct_diffs)))
            trial.set_user_attr("fold_r2", fold_scores)
            trial.set_user_attr("fold_rmse", fold_rmses)
            trial.set_user_attr("fold_aggregate_tch_sum_pct_diff", fold_aggregate_pct_diffs)
            trial.set_user_attr("mean_r2", mean_r2)
            trial.set_user_attr("std_r2", std_r2)
            trial.set_user_attr("mean_rmse", mean_rmse)
            trial.set_user_attr("mean_abs_aggregate_tch_sum_pct_diff", mean_abs_aggregate_pct_diff)
            if resolved_objective_mode == "aggregate_tch_sum":
                return mean_rmse + aggregate_penalty * mean_abs_aggregate_pct_diff
            return mean_r2 - stability_penalty * std_r2

        model = build_estimator(model_type, params)
        fit_model(model, model_type, X_train, y_train, categorical_mode)
        pred = model.predict(X_validation)
        rmse = regression_metrics(y_validation, pred)["rmse"]
        aggregate_pct_diff = aggregate_tch_sum_pct_diff(y_validation, pred)
        trial.set_user_attr("rmse", float(rmse))
        trial.set_user_attr("aggregate_tch_sum_pct_diff", float(aggregate_pct_diff))
        trial.set_user_attr("abs_aggregate_tch_sum_pct_diff", float(abs(aggregate_pct_diff)))
        if resolved_objective_mode == "aggregate_tch_sum":
            return rmse + aggregate_penalty * abs(aggregate_pct_diff)
        return rmse

    def trial_callback(study: optuna.Study, trial: optuna.trial.FrozenTrial) -> None:
        if resolved_objective_mode == "aggregate_tch_sum":
            if walk_forward:
                mean_rmse = trial.user_attrs.get("mean_rmse")
                mean_abs_agg = trial.user_attrs.get("mean_abs_aggregate_tch_sum_pct_diff")
                log(
                    f"Trial {trial.number + 1}/{n_trials} | aggregate_score={trial.value:.4f} | "
                    f"mean_rmse={mean_rmse:.4f} | mean_abs_tch_sum_pct_diff={mean_abs_agg:.4f} | "
                    f"best={study.best_value:.4f}"
                )
            else:
                rmse = trial.user_attrs.get("rmse")
                abs_agg = trial.user_attrs.get("abs_aggregate_tch_sum_pct_diff")
                log(
                    f"Trial {trial.number + 1}/{n_trials} | aggregate_score={trial.value:.4f} | "
                    f"rmse={rmse:.4f} | abs_tch_sum_pct_diff={abs_agg:.4f} | best={study.best_value:.4f}"
                )
        elif walk_forward:
            mean_r2 = trial.user_attrs.get("mean_r2")
            std_r2 = trial.user_attrs.get("std_r2")
            log(
                f"Trial {trial.number + 1}/{n_trials} | "
                f"wf_score={trial.value:.4f} | mean_r2={mean_r2:.4f} | "
                f"std_r2={std_r2:.4f} | best={study.best_value:.4f}"
            )
        else:
            log(f"Trial {trial.number + 1}/{n_trials} | rmse={trial.value:.4f} | best={study.best_value:.4f}")

    direction = "maximize" if resolved_objective_mode == "walk_forward_r2" else "minimize"
    study = optuna.create_study(direction=direction)
    study.optimize(objective, n_trials=n_trials, callbacks=[trial_callback])
    return study.best_params, study


def evaluate_split(model, X: pd.DataFrame, y: pd.Series, metadata: pd.DataFrame, split: str):
    pred = model.predict(X)
    metrics = regression_metrics(y, pred)
    zafra_df = zafra_metrics(metadata, y, pred, split=split)
    lot_df = lot_predictions(metadata, y, pred, split=split)
    return metrics, zafra_df, lot_df


def run_walk_forward(
    X: pd.DataFrame,
    y: pd.Series,
    metadata: pd.DataFrame,
    model_type: str,
    params: dict,
    categorical_mode: str,
) -> pd.DataFrame:
    rows = []
    for validation_zafra, train_idx, validation_idx in walk_forward_splits(metadata):
        train_idx = train_idx.intersection(X.index)
        validation_idx = validation_idx.intersection(X.index)
        if train_idx.empty or validation_idx.empty:
            continue

        model = build_estimator(model_type, params)
        fit_model(model, model_type, X.loc[train_idx], y.loc[train_idx], categorical_mode)
        pred = model.predict(X.loc[validation_idx])
        fold_metrics = regression_metrics(y.loc[validation_idx], pred)
        actual_tch_sum = float(y.loc[validation_idx].sum())
        pred_tch_sum = float(np.sum(pred))
        tch_sum_diff = pred_tch_sum - actual_tch_sum
        fold_metrics["validation_zafra"] = validation_zafra
        fold_metrics["train_rows"] = int(len(train_idx))
        fold_metrics["validation_rows"] = int(len(validation_idx))
        fold_metrics["actual_tch_sum"] = actual_tch_sum
        fold_metrics["pred_tch_sum"] = pred_tch_sum
        fold_metrics["tch_sum_diff"] = tch_sum_diff
        fold_metrics["tch_sum_pct_diff"] = tch_sum_diff / actual_tch_sum if actual_tch_sum else np.nan
        fold_metrics["abs_tch_sum_pct_diff"] = abs(fold_metrics["tch_sum_pct_diff"])
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
    parser.add_argument("--walk-forward-stability-penalty", type=float, default=hyperparameter(hp_defaults, "walk-forward-stability-penalty", 0.25, float))
    parser.add_argument(
        "--objective-mode",
        type=str,
        default=hyperparameter(hp_defaults, "objective-mode", "auto"),
        choices=sorted(OBJECTIVE_MODES),
    )
    parser.add_argument("--aggregate-penalty", type=float, default=hyperparameter(hp_defaults, "aggregate-penalty", 1.0, float))
    parser.add_argument("--light-features", type=parse_bool, default=hyperparameter(hp_defaults, "light-features", True, parse_bool))
    parser.add_argument("--one-hot-features", type=parse_bool, default=hyperparameter(hp_defaults, "one-hot-features", True, parse_bool))
    parser.add_argument(
        "--categorical-mode",
        type=str,
        default=hyperparameter(hp_defaults, "categorical-mode", None),
        choices=sorted(CATEGORICAL_MODES),
    )
    parser.add_argument("--quantiles", type=parse_bool, default=hyperparameter(hp_defaults, "quantiles", True, parse_bool))
    parser.add_argument("--shap", type=parse_bool, default=hyperparameter(hp_defaults, "shap", True, parse_bool))
    parser.add_argument("--diagnostics", type=parse_bool, default=hyperparameter(hp_defaults, "diagnostics", True, parse_bool))
    parser.add_argument("--diagnostics-only", type=parse_bool, default=hyperparameter(hp_defaults, "diagnostics-only", False, parse_bool))
    parser.add_argument("--skip-optuna", type=parse_bool, default=hyperparameter(hp_defaults, "skip-optuna", False, parse_bool))
    parser.add_argument("--external-zafras", type=str, default=hyperparameter(hp_defaults, "external-zafras", ""))
    args, unknown_args = parser.parse_known_args()
    if unknown_args:
        log(f"Ignoring unknown arguments: {unknown_args}")
    if args.diagnostics_only:
        args.diagnostics = True
    resolved_objective_mode = resolve_objective_mode(args.objective_mode, args.walk_forward)
    external_zafras = parse_csv_list(args.external_zafras)

    data_dir = os.environ.get("SM_CHANNEL_TRAIN", "/opt/ml/input/data/train")
    model_dir = os.environ.get("SM_MODEL_DIR", "/opt/ml/model")
    output_dir = os.environ.get("SM_OUTPUT_DATA_DIR", "/opt/ml/output/data")
    os.makedirs(model_dir, exist_ok=True)
    os.makedirs(output_dir, exist_ok=True)

    input_df = load_parquet_dir(data_dir)
    log(f"Loaded input dataframe: rows={len(input_df):,}, columns={len(input_df.columns):,}")

    categorical_mode = resolve_categorical_mode(args.categorical_mode, args.one_hot_features)
    validate_categorical_mode_for_model(categorical_mode, args.model_type)
    log(f"Categorical mode: {categorical_mode}")

    log(f"Building {args.dataset_type} raw feature matrix")
    X, y, metadata = build_dataset(
        input_df,
        dataset_type=args.dataset_type,
        target=args.target,
        light_features=args.light_features,
    )
    log(f"Built raw feature matrix: rows={len(X):,}, features={X.shape[1]:,}")

    log("Creating temporal split")
    metadata_by_group = metadata.set_index("cod_cg_zafra")
    external_idx = pd.Index([])
    split_metadata = metadata
    if external_zafras:
        external_mask = metadata_by_group["zafra_norm"].isin(external_zafras)
        external_idx = metadata_by_group.index[external_mask].intersection(X.index)
        split_metadata = metadata[~metadata["cod_cg_zafra"].isin(external_idx)].copy()
        log(
            "Holding out external scoring zafras: "
            f"{external_zafras} rows={len(external_idx):,}"
        )

    train_idx, validation_idx, test_idx = temporal_split(split_metadata)
    train_idx = train_idx.intersection(X.index)
    validation_idx = validation_idx.intersection(X.index)
    test_idx = test_idx.intersection(X.index)
    if external_zafras:
        train_idx = train_idx.difference(external_idx)
        validation_idx = validation_idx.difference(external_idx)
        test_idx = test_idx.difference(external_idx)

    if train_idx.empty or validation_idx.empty or test_idx.empty:
        raise ValueError(
            "Temporal split produced an empty split: "
            f"train={len(train_idx)}, validation={len(validation_idx)}, test={len(test_idx)}"
        )

    if args.diagnostics_only:
        log("Diagnostics-only mode enabled; saving pre-encoding diagnostics and exiting before tuning/training")
        save_feature_diagnostics(X, y, train_idx, validation_idx, test_idx, output_dir)
        with open(os.path.join(output_dir, "feature_list.json"), "w") as f:
            json.dump(list(X.columns), f, indent=2)
        with open(os.path.join(output_dir, "split_metadata.json"), "w") as f:
            json.dump(
                {
                    "run_mode": "diagnostics_only",
                    "diagnostics_stage": "pre_encoding",
                    "dataset_type": args.dataset_type,
                    "model_type": args.model_type,
                    "target": args.target,
                    "input_rows": int(len(input_df)),
                    "matrix_rows": int(len(X)),
                    "feature_count": int(X.shape[1]),
                    "light_features": bool(args.light_features),
                    "one_hot_features": bool(args.one_hot_features),
                    "categorical_mode": categorical_mode,
                    "categorical_columns": categorical_feature_columns(X),
                    "quantiles": False,
                    "walk_forward": bool(args.walk_forward),
                    "walk_forward_stability_penalty": float(args.walk_forward_stability_penalty),
                    "objective_mode": args.objective_mode,
                    "resolved_objective_mode": resolved_objective_mode,
                    "aggregate_penalty": float(args.aggregate_penalty),
                    "external_zafras": external_zafras,
                    "shap": False,
                    "diagnostics": True,
                    "train_rows": int(len(train_idx)),
                    "validation_rows": int(len(validation_idx)),
                    "test_rows": int(len(test_idx)),
                    "external_rows": int(len(external_idx)),
                    "train_zafras": sorted(metadata_by_group.loc[train_idx, "zafra_norm"].dropna().unique()),
                    "validation_zafras": sorted(metadata_by_group.loc[validation_idx, "zafra_norm"].dropna().unique()),
                    "test_zafras": sorted(metadata_by_group.loc[test_idx, "zafra_norm"].dropna().unique()),
                    "external_zafras_present": sorted(metadata_by_group.loc[external_idx, "zafra_norm"].dropna().unique()) if len(external_idx) else [],
                },
                f,
                indent=2,
            )
        log("Diagnostics artifacts saved.")
        return

    log("Encoding categorical features after temporal split")
    X, categorical_encoding_state = fit_transform_categorical_features(
        X,
        train_idx=train_idx,
        mode=categorical_mode,
    )
    X = prepare_features_for_model(X, args.model_type, categorical_mode)
    log(f"Built encoded feature matrix: rows={len(X):,}, features={X.shape[1]:,}")
    if categorical_mode == CATEGORICAL_MODE_NATIVE:
        log(f"Using native categorical columns: {categorical_feature_columns(X)}")

    X_train, y_train = X.loc[train_idx], y.loc[train_idx]
    X_validation, y_validation = X.loc[validation_idx], y.loc[validation_idx]
    X_test, y_test = X.loc[test_idx], y.loc[test_idx]

    log(
        "Dataset: "
        f"input_rows={len(input_df):,}, matrix_rows={len(X):,}, features={X.shape[1]:,}, "
        f"train={len(train_idx):,}, validation={len(validation_idx):,}, "
        f"test={len(test_idx):,}, external={len(external_idx):,}"
    )

    if args.diagnostics:
        log("Saving feature diagnostics")
        save_feature_diagnostics(X, y, train_idx, validation_idx, test_idx, output_dir)
    else:
        log("Skipping feature diagnostics")

    if args.skip_optuna:
        log(f"Skipping Optuna; using default parameters for model_type={args.model_type}")
        best_params = {}
        optuna_trials = pd.DataFrame()
    elif args.walk_forward:
        if resolved_objective_mode == "aggregate_tch_sum":
            objective_description = (
                "score=mean_rmse+"
                f"{args.aggregate_penalty}*mean_abs_raw_tch_sum_pct_diff"
            )
        else:
            objective_description = f"score=mean_r2-{args.walk_forward_stability_penalty}*std_r2"
        log(
            "Starting Optuna with walk-forward objective: "
            f"model_type={args.model_type}, n_trials={args.n_trials}, {objective_description}"
        )
        best_params, study = fit_with_optuna(
            X_train,
            y_train,
            X_validation,
            y_validation,
            X,
            y,
            metadata,
            model_type=args.model_type,
            n_trials=args.n_trials,
            walk_forward=args.walk_forward,
            stability_penalty=args.walk_forward_stability_penalty,
            categorical_mode=categorical_mode,
            objective_mode=args.objective_mode,
            aggregate_penalty=args.aggregate_penalty,
        )
        optuna_trials = study.trials_dataframe()
    else:
        if resolved_objective_mode == "aggregate_tch_sum":
            objective_description = f"score=validation_rmse+{args.aggregate_penalty}*abs_raw_tch_sum_pct_diff"
        else:
            objective_description = "score=validation_rmse"
        log(f"Starting Optuna: model_type={args.model_type}, n_trials={args.n_trials}, {objective_description}")
        best_params, study = fit_with_optuna(
            X_train,
            y_train,
            X_validation,
            y_validation,
            X,
            y,
            metadata,
            model_type=args.model_type,
            n_trials=args.n_trials,
            walk_forward=args.walk_forward,
            stability_penalty=args.walk_forward_stability_penalty,
            categorical_mode=categorical_mode,
            objective_mode=args.objective_mode,
            aggregate_penalty=args.aggregate_penalty,
        )
        optuna_trials = study.trials_dataframe()
    log(f"Best params: {best_params}")

    log("Training final model on train split")
    model = build_estimator(args.model_type, best_params)
    fit_model(model, args.model_type, X_train, y_train, categorical_mode)

    quantile_models = {}
    quantiles_enabled = bool(args.quantiles)
    if quantiles_enabled:
        if args.model_type == "random_forest":
            log("Using random forest tree-distribution quantiles: p10, p50, p90")
        elif args.model_type in {"lightgbm", "catboost"}:
            log(f"Training {args.model_type} native quantile models: p10, p50, p90")
            quantile_models = fit_quantile_models(
                X_train,
                y_train,
                args.model_type,
                best_params,
                categorical_mode,
            )
        else:
            log(f"Training sklearn quantile auxiliary models for {args.model_type}: p10, p50, p90")
            quantile_models = fit_quantile_models(
                X_train,
                y_train,
                args.model_type,
                best_params,
                categorical_mode,
            )

    metrics_by_split = {}
    zafra_frames = []
    lot_prediction_frames = []
    quantile_prediction_frames = []
    for split, split_idx in {
        "train": train_idx,
        "validation": validation_idx,
        "test": test_idx,
        "external": external_idx,
    }.items():
        if split_idx.empty:
            continue
        split_metrics, split_zafra, split_lot_predictions = evaluate_split(
            model,
            X.loc[split_idx],
            y.loc[split_idx],
            metadata,
            split=split,
        )
        metrics_by_split[split] = split_metrics
        zafra_frames.append(split_zafra)
        lot_prediction_frames.append(split_lot_predictions)
        if quantiles_enabled:
            quantile_prediction_frames.append(
                predict_quantiles(
                    model,
                    args.model_type,
                    quantile_models,
                    X.loc[split_idx],
                    y.loc[split_idx],
                    metadata,
                    split=split,
                )
            )
        log(f"{split} metrics: {split_metrics}")

    metrics_by_zafra = pd.concat(zafra_frames, ignore_index=True)
    predictions_by_lot = pd.concat(lot_prediction_frames, ignore_index=True)
    predictions_external = predictions_by_lot[predictions_by_lot["split"] == "external"].copy()
    metrics_by_zafra_external = metrics_by_zafra[metrics_by_zafra["split"] == "external"].copy()
    metrics_by_lot_error = lot_error_metrics(predictions_by_lot)
    metrics_by_tch_range = tch_range_metrics(predictions_by_lot)
    metrics_tail_error = tail_error_report(predictions_by_lot)
    for row in metrics_by_lot_error.to_dict(orient="records"):
        split = row.pop("split")
        metrics_by_split.setdefault(split, {}).update(row)
    log(f"Lot error metrics: {metrics_by_lot_error.to_dict(orient='records')}")
    log(f"TCH range metrics: {metrics_by_tch_range.to_dict(orient='records')}")

    predictions_by_quantile = pd.DataFrame()
    metrics_by_quantile_interval = pd.DataFrame()
    if quantile_prediction_frames:
        predictions_by_quantile = pd.concat(quantile_prediction_frames, ignore_index=True)
        metrics_by_quantile_interval = quantile_interval_metrics(predictions_by_quantile)
        metrics_by_zafra_quantiles = zafra_quantile_metrics(predictions_by_quantile)
        if not metrics_by_zafra_quantiles.empty:
            metrics_by_zafra = metrics_by_zafra.merge(
                metrics_by_zafra_quantiles,
                on=["split", "zafra_norm"],
                how="left",
            )
        for row in metrics_by_quantile_interval.to_dict(orient="records"):
            split = row.pop("split")
            metrics_by_split.setdefault(split, {}).update(row)
        log(f"Quantile interval metrics: {metrics_by_quantile_interval.to_dict(orient='records')}")

    metrics_by_zafra_aggregate = aggregate_zafra_metrics(metrics_by_zafra)
    metrics_by_split["aggregate_zafra"] = {
        row["split"]: {
            key: (None if pd.isna(value) else value)
            for key, value in row.items()
            if key != "split"
        }
        for row in metrics_by_zafra_aggregate.to_dict(orient="records")
    }
    log(f"Aggregate zafra metrics: {metrics_by_zafra_aggregate.to_dict(orient='records')}")

    walk_forward_metrics = pd.DataFrame()
    if args.walk_forward:
        walk_forward_metrics = run_walk_forward(
            X,
            y,
            split_metadata,
            args.model_type,
            best_params,
            categorical_mode,
        )
        log(f"Walk-forward metrics: {walk_forward_metrics.to_dict(orient='records')}")

    if args.shap:
        log("Generating SHAP artifacts if available")
        save_shap_values(model, args.model_type, X.loc[test_idx], output_dir)
    else:
        log("Skipping SHAP artifacts")

    log("Saving artifacts")
    joblib.dump(model, os.path.join(model_dir, "model.joblib"))
    save_categorical_encoding_state(categorical_encoding_state, output_dir)
    if quantile_models:
        joblib.dump(quantile_models, os.path.join(model_dir, "quantile_models.joblib"))
    predictions_by_lot.to_csv(os.path.join(output_dir, "predictions_by_lot.csv"), index=False)
    if not predictions_by_quantile.empty:
        predictions_by_quantile.to_csv(os.path.join(output_dir, "predictions_by_lot_quantiles.csv"), index=False)
    if not metrics_by_quantile_interval.empty:
        metrics_by_quantile_interval.to_csv(os.path.join(output_dir, "metrics_by_quantile_interval.csv"), index=False)
    metrics_by_lot_error.to_csv(os.path.join(output_dir, "metrics_by_lot_error.csv"), index=False)
    metrics_by_tch_range.to_csv(os.path.join(output_dir, "metrics_by_tch_range.csv"), index=False)
    metrics_tail_error.to_csv(os.path.join(output_dir, "tail_error_report.csv"), index=False)
    metrics_by_zafra.to_csv(os.path.join(output_dir, "metrics_by_zafra.csv"), index=False)
    metrics_by_zafra.to_csv(os.path.join(output_dir, "tch_by_zafra.csv"), index=False)
    metrics_by_zafra_aggregate.to_csv(os.path.join(output_dir, "metrics_by_zafra_aggregate.csv"), index=False)
    if not predictions_external.empty:
        predictions_external.to_csv(os.path.join(output_dir, "predictions_external.csv"), index=False)
    if not metrics_by_zafra_external.empty:
        metrics_by_zafra_external.to_csv(os.path.join(output_dir, "metrics_by_zafra_external.csv"), index=False)
    optuna_trials.to_csv(os.path.join(output_dir, "optuna_trials.csv"), index=False)
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
                "one_hot_features": bool(args.one_hot_features),
                "categorical_mode": categorical_mode,
                "categorical_columns": categorical_encoding_state.categorical_cols,
                "dropped_categorical_columns": categorical_encoding_state.drop_cols,
                "quantiles": bool(quantiles_enabled),
                "quantile_alphas": list(QUANTILE_ALPHAS),
                "walk_forward": bool(args.walk_forward),
                "walk_forward_stability_penalty": float(args.walk_forward_stability_penalty),
                "objective_mode": args.objective_mode,
                "resolved_objective_mode": resolved_objective_mode,
                "aggregate_penalty": float(args.aggregate_penalty),
                "external_zafras": external_zafras,
                "skip_optuna": bool(args.skip_optuna),
                "optuna_direction": None if args.skip_optuna else study.direction.name,
                "optuna_best_value": None if args.skip_optuna else float(study.best_value),
                "shap": bool(args.shap),
                "diagnostics": bool(args.diagnostics),
                "train_rows": int(len(train_idx)),
                "validation_rows": int(len(validation_idx)),
                "test_rows": int(len(test_idx)),
                "external_rows": int(len(external_idx)),
                "train_zafras": sorted(metadata_by_group.loc[train_idx, "zafra_norm"].dropna().unique()),
                "validation_zafras": sorted(metadata_by_group.loc[validation_idx, "zafra_norm"].dropna().unique()),
                "test_zafras": sorted(metadata_by_group.loc[test_idx, "zafra_norm"].dropna().unique()),
                "external_zafras_present": sorted(metadata_by_group.loc[external_idx, "zafra_norm"].dropna().unique()) if len(external_idx) else [],
            },
            f,
            indent=2,
        )

    log("Artifacts saved.")


if __name__ == "__main__":
    main()
