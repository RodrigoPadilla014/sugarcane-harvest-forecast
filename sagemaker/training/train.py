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
    transform_categorical_features,
    validate_categorical_mode_for_model,
)
from feature_diagnostics import save_feature_diagnostics
from features import build_dataset
from metrics import (
    estrato_metrics,
    future_scoring_estrato_metrics,
    lot_error_metrics,
    lot_predictions,
    aggregate_zafra_metrics,
    quantile_interval_metrics,
    regression_metrics,
    snapshot_day_metrics,
    tail_error_report,
    tch_range_metrics,
    zafra_metrics,
    zafra_quantile_metrics,
)
from models import build_model, suggest_params
from shap_utils import save_shap_values
from splits import indexes_for_zafras, walk_forward_splits
from weighting import (
    WEIGHT_MODES,
    sample_weights_for_index,
    training_weights_for_index,
    weight_diagnostics,
)

optuna.logging.set_verbosity(optuna.logging.WARNING)
QUANTILE_ALPHAS = (0.10, 0.50, 0.90)
OBJECTIVE_MODES = {"auto", "lot_rmse", "walk_forward_r2", "aggregate_tch_sum", "aggregate_metric_tons"}
TARGET_MODES = {"absolute", "residual_last_hist_tch", "direct_metric_tons"}
RESIDUAL_ANCHOR_FEATURE = "last_hist_tch"
DIRECT_AREA_FEATURE = "direct_area"
HIGH_YIELD_THRESHOLD = 115.0


def log(message: str) -> None:
    print(message, flush=True)


def parse_bool(value):
    if isinstance(value, bool):
        return value
    return value.lower() in {"1", "true", "yes", "y"}


def truthy_series(series: pd.Series, default: bool = True) -> pd.Series:
    if pd.api.types.is_bool_dtype(series):
        return series.fillna(default).astype(bool)
    normalized = series.fillna(default).astype(str).str.strip().str.lower()
    return normalized.isin({"1", "true", "yes", "y", "t"})


def parse_csv_list(value) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [part.strip() for part in str(value).split(",") if part.strip()]


def validate_zafra_configuration(
    train_zafras: list[str],
    evaluation_zafras: list[str],
    scoring_zafras: list[str],
) -> None:
    groups = {
        "train": train_zafras,
        "evaluation": evaluation_zafras,
        "scoring": scoring_zafras,
    }
    if not train_zafras:
        raise ValueError("--train-zafras must contain at least one zafra")
    if not evaluation_zafras:
        raise ValueError("--evaluation-zafras must contain at least one zafra")

    for name, values in groups.items():
        if len(values) != len(set(values)):
            raise ValueError(f"Duplicate zafras in --{name}-zafras: {values}")

    names = list(groups)
    for pos, left_name in enumerate(names):
        for right_name in names[pos + 1 :]:
            overlap = sorted(set(groups[left_name]) & set(groups[right_name]))
            if overlap:
                raise ValueError(
                    f"Zafras cannot appear in both {left_name} and {right_name}: {overlap}"
                )


def require_requested_zafras(
    requested: list[str],
    available,
    group_name: str,
) -> None:
    missing = sorted(set(requested) - set(available))
    if missing:
        raise ValueError(f"Requested {group_name} zafras are absent from the eligible dataset: {missing}")


def exclude_feature_columns(
    X: pd.DataFrame,
    requested: list[str],
) -> tuple[pd.DataFrame, list[str]]:
    if not requested:
        return X, []

    missing = sorted(set(requested) - set(X.columns))
    if missing:
        raise ValueError(
            "Requested --exclude-features columns are absent from the feature matrix: "
            f"{missing}"
        )

    excluded = [column for column in X.columns if column in set(requested)]
    remaining = X.drop(columns=excluded)
    if remaining.shape[1] == 0:
        raise ValueError("--exclude-features cannot remove every feature")
    return remaining, excluded


def partition_unified_rows(
    df: pd.DataFrame,
    target: str,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, dict]:
    """Separate labeled training rows, valid future scoring rows, and exclusions."""
    input_rows = int(len(df))
    role_counts = {}
    if "dataset_role" in df.columns:
        role_counts = {
            str(key): int(value)
            for key, value in df["dataset_role"].fillna("<missing>").value_counts(dropna=False).items()
        }

    training_mask = pd.Series(True, index=df.index)
    if "dataset_role" in df.columns:
        training_mask &= df["dataset_role"].fillna("training").eq("training")
    if "has_target_tch" in df.columns:
        training_mask &= truthy_series(df["has_target_tch"], default=True)
    if "asof_valid" in df.columns:
        training_mask &= truthy_series(df["asof_valid"], default=True)
    if "scoring_age_eligible" in df.columns:
        training_mask &= truthy_series(df["scoring_age_eligible"], default=True)
    if target in df.columns:
        training_mask &= df[target].notna()

    scoring_mask = pd.Series(False, index=df.index)
    if "dataset_role" in df.columns:
        scoring_mask = df["dataset_role"].fillna("").eq("scoring")
        if "has_target_tch" in df.columns:
            scoring_mask &= ~truthy_series(df["has_target_tch"], default=False)
        if target in df.columns:
            scoring_mask &= df[target].isna()

    scoring_quality_mask = scoring_mask.copy()
    if "asof_valid" in df.columns:
        scoring_quality_mask &= truthy_series(df["asof_valid"], default=False)
    if "scoring_age_eligible" in df.columns:
        scoring_quality_mask &= truthy_series(
            df["scoring_age_eligible"],
            default=False,
        )

    training_df = df.loc[training_mask].copy()
    scoring_df = df.loc[scoring_quality_mask].copy()
    excluded_scoring_df = df.loc[scoring_mask & ~scoring_quality_mask].copy()
    info = {
        "input_rows_before_training_filter": input_rows,
        "input_rows_after_training_filter": int(len(training_df)),
        "filtered_non_training_rows": int(input_rows - len(training_df)),
        "dataset_role_counts": role_counts,
        "asof_invalid_rows": int(
            (~truthy_series(df["asof_valid"], default=True)).sum()
            if "asof_valid" in df.columns
            else 0
        ),
        "training_filter_applied": bool(
            "dataset_role" in df.columns
            or "has_target_tch" in df.columns
            or "asof_valid" in df.columns
        ),
        "future_scoring_rows": int(len(scoring_df)),
        "future_scoring_excluded_rows": int(len(excluded_scoring_df)),
    }
    return training_df, scoring_df, excluded_scoring_df, info


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


def model_target(y_actual: pd.Series, X: pd.DataFrame, target_mode: str) -> pd.Series:
    if target_mode == "absolute":
        return y_actual.copy()
    if target_mode == "residual_last_hist_tch":
        if RESIDUAL_ANCHOR_FEATURE not in X.columns:
            raise ValueError(
                f"target_mode={target_mode} requires feature {RESIDUAL_ANCHOR_FEATURE}"
            )
        anchor = pd.to_numeric(X[RESIDUAL_ANCHOR_FEATURE], errors="coerce")
        missing = int(anchor.isna().sum())
        if missing:
            raise ValueError(
                f"target_mode={target_mode} has {missing} rows without "
                f"{RESIDUAL_ANCHOR_FEATURE}"
            )
        result = y_actual - anchor
        result.name = f"{y_actual.name}_residual"
        return result
    if target_mode == "direct_metric_tons":
        if DIRECT_AREA_FEATURE not in X.columns:
            raise ValueError(
                f"target_mode={target_mode} requires feature {DIRECT_AREA_FEATURE}"
            )
        area = pd.to_numeric(X[DIRECT_AREA_FEATURE], errors="coerce")
        if area.isna().any() or (area <= 0).any():
            raise ValueError(
                f"target_mode={target_mode} requires positive, non-missing area"
            )
        result = y_actual * area
        result.name = "metric_tons"
        return result
    raise ValueError(f"Unknown target_mode: {target_mode}")


def reconstruct_tch_predictions(
    raw_predictions,
    X: pd.DataFrame,
    target_mode: str,
) -> np.ndarray:
    predictions = np.asarray(raw_predictions, dtype=float)
    if target_mode == "absolute":
        return predictions
    if target_mode == "residual_last_hist_tch":
        if RESIDUAL_ANCHOR_FEATURE not in X.columns:
            raise ValueError(
                f"target_mode={target_mode} requires feature {RESIDUAL_ANCHOR_FEATURE}"
            )
        anchor = pd.to_numeric(X[RESIDUAL_ANCHOR_FEATURE], errors="coerce").to_numpy()
        if np.isnan(anchor).any():
            raise ValueError(
                f"target_mode={target_mode} cannot reconstruct rows without "
                f"{RESIDUAL_ANCHOR_FEATURE}"
            )
        return anchor + predictions
    if target_mode == "direct_metric_tons":
        if DIRECT_AREA_FEATURE not in X.columns:
            raise ValueError(
                f"target_mode={target_mode} requires feature {DIRECT_AREA_FEATURE}"
            )
        area = pd.to_numeric(
            X[DIRECT_AREA_FEATURE],
            errors="coerce",
        ).to_numpy()
        if np.isnan(area).any() or (area <= 0).any():
            raise ValueError(
                f"target_mode={target_mode} requires positive, non-missing area"
            )
        return predictions / area
    raise ValueError(f"Unknown target_mode: {target_mode}")


def aggregate_tch_sum_pct_diff(
    y_true: pd.Series,
    y_pred,
    metadata: pd.DataFrame | None = None,
) -> float:
    if metadata is not None and "snapshot_day" in metadata.columns:
        aligned = metadata.set_index("cod_cg_zafra").reindex(y_true.index)
        frame = pd.DataFrame(
            {
                "snapshot_day": aligned["snapshot_day"].to_numpy(),
                "actual": y_true.to_numpy(),
                "pred": np.asarray(y_pred),
            }
        )
        pct_diffs = []
        for _, group in frame.groupby("snapshot_day", dropna=False):
            actual_sum = float(group["actual"].sum())
            if actual_sum:
                pct_diffs.append(
                    100.0
                    * (float(group["pred"].sum()) - actual_sum)
                    / actual_sum
                )
        return float(np.mean(np.abs(pct_diffs))) if pct_diffs else 0.0

    actual_sum = float(np.sum(y_true))
    pred_sum = float(np.sum(y_pred))
    if actual_sum == 0:
        return 0.0
    return 100.0 * (pred_sum - actual_sum) / actual_sum


def aggregate_metric_tons_pct_diff(
    y_true: pd.Series,
    y_pred,
    metadata: pd.DataFrame | None = None,
) -> float:
    if metadata is None or "area" not in metadata.columns:
        raise ValueError("aggregate_metric_tons objective requires an area column in metadata")

    aligned = metadata.set_index("cod_cg_zafra").reindex(y_true.index)
    frame_data = {
        "area": pd.to_numeric(aligned["area"], errors="coerce").to_numpy(),
        "actual": y_true.to_numpy(),
        "pred": np.asarray(y_pred),
    }
    if "snapshot_day" in aligned.columns:
        frame_data["snapshot_day"] = aligned["snapshot_day"].to_numpy()
    if "zafra_norm" in aligned.columns:
        frame_data["zafra_norm"] = aligned["zafra_norm"].to_numpy()
    frame = pd.DataFrame(frame_data).dropna(subset=["area", "actual", "pred"])
    if frame.empty:
        return 0.0

    def pct_diff(group: pd.DataFrame) -> float | None:
        actual_sum = float((group["actual"] * group["area"]).sum())
        if actual_sum == 0:
            return None
        pred_sum = float((group["pred"] * group["area"]).sum())
        return 100.0 * (pred_sum - actual_sum) / actual_sum

    group_cols = [col for col in ["zafra_norm", "snapshot_day"] if col in frame.columns]
    if group_cols:
        pct_diffs = [
            diff
            for _, group in frame.groupby(group_cols, dropna=False)
            if (diff := pct_diff(group)) is not None
        ]
        return float(np.mean(np.abs(pct_diffs))) if pct_diffs else 0.0

    diff = pct_diff(frame)
    return float(diff) if diff is not None else 0.0


def high_yield_area_weighted_abs_bias(
    y_true: pd.Series,
    y_pred,
    metadata: pd.DataFrame,
    threshold: float = HIGH_YIELD_THRESHOLD,
) -> float:
    aligned = metadata.set_index("cod_cg_zafra").reindex(y_true.index)
    frame = pd.DataFrame(
        {
            "area": pd.to_numeric(aligned["area"], errors="coerce").to_numpy(),
            "actual": y_true.to_numpy(),
            "pred": np.asarray(y_pred),
        }
    ).dropna()
    frame = frame[frame["actual"] > threshold]
    if frame.empty or float(frame["area"].sum()) == 0:
        return 0.0
    return float(
        abs(np.average(frame["pred"] - frame["actual"], weights=frame["area"]))
    )


def worst_estrato_metric_tons_abs_pct_error(
    y_true: pd.Series,
    y_pred,
    metadata: pd.DataFrame,
) -> float:
    aligned = metadata.set_index("cod_cg_zafra").reindex(y_true.index)
    if "prod_estrato" not in aligned.columns:
        return 0.0
    frame = pd.DataFrame(
        {
            "estrato": aligned["prod_estrato"].fillna("<sin estrato>").to_numpy(),
            "area": pd.to_numeric(aligned["area"], errors="coerce").to_numpy(),
            "actual": y_true.to_numpy(),
            "pred": np.asarray(y_pred),
        }
    ).dropna(subset=["area", "actual", "pred"])
    errors = []
    for _, group in frame.groupby("estrato", dropna=False):
        actual_tm = float((group["actual"] * group["area"]).sum())
        if actual_tm:
            pred_tm = float((group["pred"] * group["area"]).sum())
            errors.append(abs(100.0 * (pred_tm - actual_tm) / actual_tm))
    return float(max(errors)) if errors else 0.0


def composite_metric_tons_objective(
    rmse: float,
    abs_metric_tons_pct_diff: float,
    aggregate_penalty: float,
    high_yield_abs_bias: float = 0.0,
    high_yield_penalty: float = 0.0,
    worst_estrato_abs_pct_error: float = 0.0,
    worst_estrato_penalty: float = 0.0,
) -> float:
    return float(
        rmse
        + aggregate_penalty * abs_metric_tons_pct_diff
        + high_yield_penalty * high_yield_abs_bias
        + worst_estrato_penalty * worst_estrato_abs_pct_error
    )


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


def fit_model(
    model,
    model_type: str,
    X: pd.DataFrame,
    y: pd.Series,
    categorical_mode: str,
    sample_weight: pd.Series | None = None,
):
    fit_kwargs = {}
    if sample_weight is not None:
        fit_kwargs["sample_weight"] = sample_weight.to_numpy()
    if model_type == "catboost" and categorical_mode == CATEGORICAL_MODE_NATIVE:
        cat_cols = categorical_feature_columns(X)
        model.fit(X, y, cat_features=cat_cols, **fit_kwargs)
    elif sample_weight is not None and hasattr(model, "steps"):
        final_step_name = model.steps[-1][0]
        model.fit(
            X,
            y,
            **{f"{final_step_name}__sample_weight": sample_weight.to_numpy()},
        )
    else:
        model.fit(X, y, **fit_kwargs)
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
    sample_weight: pd.Series | None = None,
    quantile_alphas=QUANTILE_ALPHAS,
):
    if model_type == "random_forest":
        return {}

    models = {}
    for alpha in quantile_alphas:
        model = build_quantile_estimator(model_type, params, alpha)
        fit_model(
            model,
            model_type,
            X_train,
            y_train,
            categorical_mode,
            sample_weight=sample_weight,
        )
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
    target_mode: str = "absolute",
) -> pd.DataFrame:
    df = metadata.set_index("cod_cg_zafra").loc[y.index].copy()
    df.index.name = "cod_cg_zafra"
    df = df.reset_index()
    df["split"] = split
    df["actual_tch"] = y.to_numpy()
    if RESIDUAL_ANCHOR_FEATURE in X.columns:
        df[RESIDUAL_ANCHOR_FEATURE] = pd.to_numeric(
            X[RESIDUAL_ANCHOR_FEATURE],
            errors="coerce",
        ).to_numpy()
    for alpha in QUANTILE_ALPHAS:
        percentile = int(round(alpha * 100))
        if model_type == "random_forest":
            raw_pred = random_forest_quantile_predictions(base_model, X, alpha)
        else:
            raw_pred = quantile_models[alpha].predict(X)
        df[f"pred_tch_p{percentile}"] = reconstruct_tch_predictions(
            raw_pred,
            X,
            target_mode,
        )

    ordered_cols = [
        "split",
        "cod_cg_zafra",
        "cod_cg",
        "zafra_norm",
        "area",
        "cycle_id",
        "snapshot_day",
        "snapshot_date",
        "actual_tch",
        "pred_tch_p10",
        "pred_tch_p50",
        "pred_tch_p90",
    ]
    return df[[col for col in ordered_cols if col in df.columns]]


def future_scoring_predictions(
    model,
    model_type: str,
    quantile_models: dict,
    X: pd.DataFrame,
    metadata: pd.DataFrame,
    target_mode: str = "absolute",
) -> pd.DataFrame:
    df = metadata.set_index("cod_cg_zafra").loc[X.index].copy()
    df.index.name = "cod_cg_zafra"
    df = df.reset_index()
    df["split"] = "future_scoring"
    if RESIDUAL_ANCHOR_FEATURE in X.columns:
        df[RESIDUAL_ANCHOR_FEATURE] = pd.to_numeric(
            X[RESIDUAL_ANCHOR_FEATURE],
            errors="coerce",
        ).to_numpy()
    df["pred_tch"] = reconstruct_tch_predictions(
        model.predict(X),
        X,
        target_mode,
    )

    if quantile_models or model_type == "random_forest":
        for alpha in QUANTILE_ALPHAS:
            percentile = int(round(alpha * 100))
            if model_type == "random_forest":
                pred = random_forest_quantile_predictions(model, X, alpha)
            else:
                pred = quantile_models[alpha].predict(X)
            df[f"pred_tch_p{percentile}"] = reconstruct_tch_predictions(
                pred,
                X,
                target_mode,
            )

    ordered_cols = [
        "split",
        "cod_cg_zafra",
        "cod_cg",
        "zafra_norm",
        "area",
        "cycle_id",
        "snapshot_day",
        "snapshot_date",
        "scoring_age_eligible",
        "as_of_date",
        "as_of_age_days",
        "cycle_status",
        "pred_tch",
        "pred_tch_p10",
        "pred_tch_p50",
        "pred_tch_p90",
    ]
    extra_cols = [col for col in df.columns if col not in ordered_cols]
    return df[[col for col in [*ordered_cols, *extra_cols] if col in df.columns]]


def summarize_future_scoring(predictions: pd.DataFrame) -> pd.DataFrame:
    if predictions.empty:
        return pd.DataFrame()

    aggregations = {
        "rows": ("pred_tch", "size"),
        "pred_tch_sum": ("pred_tch", "sum"),
        "pred_tch_mean": ("pred_tch", "mean"),
        "pred_tch_median": ("pred_tch", "median"),
    }
    if "area" in predictions.columns:
        predictions = predictions.copy()
        predictions["pred_area_weighted_tch"] = predictions["pred_tch"] * predictions["area"]
        aggregations["area_sum"] = ("area", "sum")
        aggregations["pred_area_weighted_tch_sum"] = ("pred_area_weighted_tch", "sum")
    for percentile in (10, 50, 90):
        col = f"pred_tch_p{percentile}"
        if col in predictions.columns:
            aggregations[f"{col}_sum"] = (col, "sum")
            if "area" in predictions.columns:
                area_col = f"pred_area_weighted_tch_p{percentile}"
                predictions[area_col] = predictions[col] * predictions["area"]
                aggregations[f"{area_col}_sum"] = (area_col, "sum")

    return predictions.groupby("zafra_norm", dropna=False).agg(**aggregations).reset_index()


def fit_with_optuna(
    X_train: pd.DataFrame,
    y_train_model: pd.Series,
    y_train_actual: pd.Series,
    X_validation: pd.DataFrame,
    y_validation_actual: pd.Series,
    X: pd.DataFrame,
    y_model: pd.Series,
    y_actual: pd.Series,
    metadata: pd.DataFrame,
    model_type: str,
    n_trials: int,
    walk_forward: bool,
    stability_penalty: float,
    categorical_mode: str,
    objective_mode: str,
    aggregate_penalty: float,
    walk_forward_zafras: list[str],
    target_mode: str,
    weight_mode: str,
    weight_max_multiplier: float,
    weight_density_bin_width: float,
    high_yield_penalty: float,
    worst_estrato_penalty: float,
    search_profile: str,
):
    walk_forward_folds = walk_forward_splits(metadata, walk_forward_zafras) if walk_forward else []
    resolved_objective_mode = resolve_objective_mode(objective_mode, walk_forward)

    def objective(trial):
        params = suggest_params(trial, model_type, search_profile=search_profile)

        if walk_forward:
            fold_scores = []
            fold_rmses = []
            fold_aggregate_pct_diffs = []
            fold_metric_tons_pct_diffs = []
            fold_high_yield_biases = []
            fold_worst_estrato_pct_errors = []
            for validation_zafra, train_idx, validation_idx in walk_forward_folds:
                train_idx = train_idx.intersection(X.index)
                validation_idx = validation_idx.intersection(X.index)
                if train_idx.empty or validation_idx.empty:
                    continue

                model = build_estimator(model_type, params)
                fit_model(
                    model,
                    model_type,
                    X.loc[train_idx],
                    y_model.loc[train_idx],
                    categorical_mode,
                    sample_weight=training_weights_for_index(
                        metadata,
                        y_actual,
                        X,
                        train_idx,
                        train_idx,
                        mode=weight_mode,
                        max_multiplier=weight_max_multiplier,
                        density_bin_width=weight_density_bin_width,
                    ),
                )
                pred = reconstruct_tch_predictions(
                    model.predict(X.loc[validation_idx]),
                    X.loc[validation_idx],
                    target_mode,
                )
                fold_metrics = regression_metrics(
                    y_actual.loc[validation_idx],
                    pred,
                    sample_weight=sample_weights_for_index(
                        metadata,
                        validation_idx,
                    ),
                )
                fold_scores.append(fold_metrics["r2"])
                fold_rmses.append(fold_metrics["rmse"])
                fold_aggregate_pct_diffs.append(
                    aggregate_tch_sum_pct_diff(
                        y_actual.loc[validation_idx],
                        pred,
                        metadata,
                    )
                )
                fold_metric_tons_pct_diffs.append(
                    aggregate_metric_tons_pct_diff(
                        y_actual.loc[validation_idx],
                        pred,
                        metadata,
                    )
                )
                fold_high_yield_biases.append(
                    high_yield_area_weighted_abs_bias(
                        y_actual.loc[validation_idx],
                        pred,
                        metadata,
                    )
                )
                fold_worst_estrato_pct_errors.append(
                    worst_estrato_metric_tons_abs_pct_error(
                        y_actual.loc[validation_idx],
                        pred,
                        metadata,
                    )
                )

            if not fold_scores:
                raise ValueError("Walk-forward objective produced no valid folds")

            mean_r2 = float(np.mean(fold_scores))
            std_r2 = float(np.std(fold_scores))
            mean_rmse = float(np.mean(fold_rmses))
            mean_abs_aggregate_pct_diff = float(np.mean(np.abs(fold_aggregate_pct_diffs)))
            mean_abs_metric_tons_pct_diff = float(np.mean(np.abs(fold_metric_tons_pct_diffs)))
            mean_high_yield_abs_bias = float(np.mean(fold_high_yield_biases))
            mean_worst_estrato_abs_pct_error = float(
                np.mean(fold_worst_estrato_pct_errors)
            )
            trial.set_user_attr("fold_r2", fold_scores)
            trial.set_user_attr("fold_rmse", fold_rmses)
            trial.set_user_attr("fold_aggregate_tch_sum_pct_diff", fold_aggregate_pct_diffs)
            trial.set_user_attr("fold_aggregate_metric_tons_pct_diff", fold_metric_tons_pct_diffs)
            trial.set_user_attr("fold_high_yield_abs_bias", fold_high_yield_biases)
            trial.set_user_attr(
                "fold_worst_estrato_abs_pct_error",
                fold_worst_estrato_pct_errors,
            )
            trial.set_user_attr("mean_r2", mean_r2)
            trial.set_user_attr("std_r2", std_r2)
            trial.set_user_attr("mean_rmse", mean_rmse)
            trial.set_user_attr("mean_abs_aggregate_tch_sum_pct_diff", mean_abs_aggregate_pct_diff)
            trial.set_user_attr("mean_abs_aggregate_metric_tons_pct_diff", mean_abs_metric_tons_pct_diff)
            trial.set_user_attr("mean_high_yield_abs_bias", mean_high_yield_abs_bias)
            trial.set_user_attr(
                "mean_worst_estrato_abs_pct_error",
                mean_worst_estrato_abs_pct_error,
            )
            if resolved_objective_mode == "aggregate_tch_sum":
                return mean_rmse + aggregate_penalty * mean_abs_aggregate_pct_diff
            if resolved_objective_mode == "aggregate_metric_tons":
                return composite_metric_tons_objective(
                    mean_rmse
                    ,
                    mean_abs_metric_tons_pct_diff,
                    aggregate_penalty,
                    mean_high_yield_abs_bias,
                    high_yield_penalty,
                    mean_worst_estrato_abs_pct_error,
                    worst_estrato_penalty,
                )
            return mean_r2 - stability_penalty * std_r2

        model = build_estimator(model_type, params)
        fit_model(
            model,
            model_type,
            X_train,
            y_train_model,
            categorical_mode,
            sample_weight=training_weights_for_index(
                metadata,
                y_train_actual,
                X,
                X_train.index,
                X_train.index,
                mode=weight_mode,
                max_multiplier=weight_max_multiplier,
                density_bin_width=weight_density_bin_width,
            ),
        )
        pred = reconstruct_tch_predictions(
            model.predict(X_validation),
            X_validation,
            target_mode,
        )
        rmse = regression_metrics(
            y_validation_actual,
            pred,
            sample_weight=sample_weights_for_index(
                metadata,
                y_validation_actual.index,
            ),
        )["rmse"]
        aggregate_pct_diff = aggregate_tch_sum_pct_diff(
            y_validation_actual,
            pred,
            metadata,
        )
        metric_tons_pct_diff = aggregate_metric_tons_pct_diff(
            y_validation_actual,
            pred,
            metadata,
        )
        high_yield_abs_bias = high_yield_area_weighted_abs_bias(
            y_validation_actual,
            pred,
            metadata,
        )
        worst_estrato_abs_pct_error = worst_estrato_metric_tons_abs_pct_error(
            y_validation_actual,
            pred,
            metadata,
        )
        trial.set_user_attr("rmse", float(rmse))
        trial.set_user_attr("aggregate_tch_sum_pct_diff", float(aggregate_pct_diff))
        trial.set_user_attr("abs_aggregate_tch_sum_pct_diff", float(abs(aggregate_pct_diff)))
        trial.set_user_attr("aggregate_metric_tons_pct_diff", float(metric_tons_pct_diff))
        trial.set_user_attr("abs_aggregate_metric_tons_pct_diff", float(abs(metric_tons_pct_diff)))
        trial.set_user_attr("high_yield_abs_bias", float(high_yield_abs_bias))
        trial.set_user_attr(
            "worst_estrato_abs_pct_error",
            float(worst_estrato_abs_pct_error),
        )
        if resolved_objective_mode == "aggregate_tch_sum":
            return rmse + aggregate_penalty * abs(aggregate_pct_diff)
        if resolved_objective_mode == "aggregate_metric_tons":
            return composite_metric_tons_objective(
                rmse
                ,
                abs(metric_tons_pct_diff),
                aggregate_penalty,
                high_yield_abs_bias,
                high_yield_penalty,
                worst_estrato_abs_pct_error,
                worst_estrato_penalty,
            )
        return rmse

    def trial_callback(study: optuna.Study, trial: optuna.trial.FrozenTrial) -> None:
        if resolved_objective_mode in {"aggregate_tch_sum", "aggregate_metric_tons"}:
            metric_label = "metric_tons" if resolved_objective_mode == "aggregate_metric_tons" else "tch_sum"
            if walk_forward:
                mean_rmse = trial.user_attrs.get("mean_rmse")
                attr = (
                    "mean_abs_aggregate_metric_tons_pct_diff"
                    if resolved_objective_mode == "aggregate_metric_tons"
                    else "mean_abs_aggregate_tch_sum_pct_diff"
                )
                mean_abs_agg = trial.user_attrs.get(attr)
                log(
                    f"Trial {trial.number + 1}/{n_trials} | aggregate_score={trial.value:.4f} | "
                    f"mean_rmse={mean_rmse:.4f} | mean_abs_{metric_label}_pct_diff={mean_abs_agg:.4f} | "
                    f"best={study.best_value:.4f}"
                )
            else:
                rmse = trial.user_attrs.get("rmse")
                attr = (
                    "abs_aggregate_metric_tons_pct_diff"
                    if resolved_objective_mode == "aggregate_metric_tons"
                    else "abs_aggregate_tch_sum_pct_diff"
                )
                abs_agg = trial.user_attrs.get(attr)
                log(
                    f"Trial {trial.number + 1}/{n_trials} | aggregate_score={trial.value:.4f} | "
                    f"rmse={rmse:.4f} | abs_{metric_label}_pct_diff={abs_agg:.4f} | best={study.best_value:.4f}"
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


def evaluate_split(
    model,
    X: pd.DataFrame,
    y_actual: pd.Series,
    metadata: pd.DataFrame,
    split: str,
    target_mode: str = "absolute",
):
    pred = reconstruct_tch_predictions(model.predict(X), X, target_mode)
    metrics = regression_metrics(
        y_actual,
        pred,
        sample_weight=sample_weights_for_index(metadata, y_actual.index),
    )
    zafra_df = zafra_metrics(metadata, y_actual, pred, split=split)
    lot_df = lot_predictions(metadata, y_actual, pred, split=split)
    if RESIDUAL_ANCHOR_FEATURE in X.columns:
        anchor = pd.to_numeric(
            X.loc[y_actual.index, RESIDUAL_ANCHOR_FEATURE],
            errors="coerce",
        ).to_numpy()
        lot_df[RESIDUAL_ANCHOR_FEATURE] = anchor
        lot_df["actual_change_from_history"] = lot_df["actual_tch"] - anchor
        lot_df["pred_change_from_history"] = lot_df["pred_tch"] - anchor
    return metrics, zafra_df, lot_df


def run_walk_forward(
    X: pd.DataFrame,
    y_model: pd.Series,
    y_actual: pd.Series,
    metadata: pd.DataFrame,
    model_type: str,
    params: dict,
    categorical_mode: str,
    zafras: list[str],
    target_mode: str = "absolute",
    weight_mode: str = "snapshot",
    weight_max_multiplier: float = 1.0,
    weight_density_bin_width: float = 5.0,
    quantiles_enabled: bool = False,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    rows = []
    prediction_frames = []
    quantile_prediction_frames = []
    for validation_zafra, train_idx, validation_idx in walk_forward_splits(metadata, zafras):
        train_idx = train_idx.intersection(X.index)
        validation_idx = validation_idx.intersection(X.index)
        if train_idx.empty or validation_idx.empty:
            continue

        model = build_estimator(model_type, params)
        fold_train_weight = training_weights_for_index(
            metadata,
            y_actual,
            X,
            train_idx,
            train_idx,
            mode=weight_mode,
            max_multiplier=weight_max_multiplier,
            density_bin_width=weight_density_bin_width,
        )
        fit_model(
            model,
            model_type,
            X.loc[train_idx],
            y_model.loc[train_idx],
            categorical_mode,
            sample_weight=fold_train_weight,
        )
        pred = reconstruct_tch_predictions(
            model.predict(X.loc[validation_idx]),
            X.loc[validation_idx],
            target_mode,
        )
        fold_metrics = regression_metrics(
            y_actual.loc[validation_idx],
            pred,
            sample_weight=sample_weights_for_index(
                metadata,
                validation_idx,
            ),
        )
        fold_metadata = metadata.set_index("cod_cg_zafra").reindex(validation_idx)
        has_snapshots = "snapshot_day" in fold_metadata.columns
        actual_tch_sum = (
            np.nan if has_snapshots else float(y_actual.loc[validation_idx].sum())
        )
        pred_tch_sum = np.nan if has_snapshots else float(np.sum(pred))
        tch_sum_diff = pred_tch_sum - actual_tch_sum
        fold_metrics["validation_zafra"] = validation_zafra
        fold_metrics["train_rows"] = int(len(train_idx))
        fold_metrics["validation_rows"] = int(len(validation_idx))
        fold_metrics["actual_tch_sum"] = actual_tch_sum
        fold_metrics["pred_tch_sum"] = pred_tch_sum
        fold_metrics["tch_sum_diff"] = tch_sum_diff
        fold_metrics["tch_sum_pct_diff"] = (
            aggregate_tch_sum_pct_diff(
                y_actual.loc[validation_idx],
                pred,
                metadata,
            )
            / 100.0
            if has_snapshots
            else tch_sum_diff / actual_tch_sum
            if actual_tch_sum
            else np.nan
        )
        fold_metrics["abs_tch_sum_pct_diff"] = abs(fold_metrics["tch_sum_pct_diff"])
        rows.append(fold_metrics)

        fold_predictions = lot_predictions(
            metadata,
            y_actual.loc[validation_idx],
            pred,
            split="walk_forward",
        )
        fold_predictions["validation_zafra"] = validation_zafra
        if RESIDUAL_ANCHOR_FEATURE in X.columns:
            anchor = pd.to_numeric(
                X.loc[validation_idx, RESIDUAL_ANCHOR_FEATURE],
                errors="coerce",
            ).to_numpy()
            fold_predictions[RESIDUAL_ANCHOR_FEATURE] = anchor
            fold_predictions["actual_change_from_history"] = (
                fold_predictions["actual_tch"] - anchor
            )
            fold_predictions["pred_change_from_history"] = (
                fold_predictions["pred_tch"] - anchor
            )
        prediction_frames.append(fold_predictions)

        if quantiles_enabled:
            fold_quantile_models = fit_quantile_models(
                X.loc[train_idx],
                y_model.loc[train_idx],
                model_type,
                params,
                categorical_mode,
                sample_weight=fold_train_weight,
            )
            fold_quantile_predictions = predict_quantiles(
                model,
                model_type,
                fold_quantile_models,
                X.loc[validation_idx],
                y_actual.loc[validation_idx],
                metadata,
                split="walk_forward",
                target_mode=target_mode,
            )
            fold_quantile_predictions["validation_zafra"] = validation_zafra
            quantile_prediction_frames.append(fold_quantile_predictions)

    predictions = (
        pd.concat(prediction_frames, ignore_index=True)
        if prediction_frames
        else pd.DataFrame()
    )
    quantile_predictions = (
        pd.concat(quantile_prediction_frames, ignore_index=True)
        if quantile_prediction_frames
        else pd.DataFrame()
    )
    return pd.DataFrame(rows), predictions, quantile_predictions


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
    parser.add_argument(
        "--target-mode",
        type=str,
        default=hyperparameter(hp_defaults, "target-mode", "absolute"),
        choices=sorted(TARGET_MODES),
    )
    parser.add_argument("--n-trials", type=int, default=hyperparameter(hp_defaults, "n-trials", 50, int))
    parser.add_argument(
        "--search-profile",
        type=str,
        default=hyperparameter(hp_defaults, "search-profile", "default"),
        choices=["default", "phase4_catboost"],
    )
    parser.add_argument("--walk-forward", type=parse_bool, default=hyperparameter(hp_defaults, "walk-forward", False, parse_bool))
    parser.add_argument("--walk-forward-stability-penalty", type=float, default=hyperparameter(hp_defaults, "walk-forward-stability-penalty", 0.25, float))
    parser.add_argument(
        "--objective-mode",
        type=str,
        default=hyperparameter(hp_defaults, "objective-mode", "auto"),
        choices=sorted(OBJECTIVE_MODES),
    )
    parser.add_argument("--aggregate-penalty", type=float, default=hyperparameter(hp_defaults, "aggregate-penalty", 1.0, float))
    parser.add_argument(
        "--high-yield-penalty",
        type=float,
        default=hyperparameter(hp_defaults, "high-yield-penalty", 0.0, float),
    )
    parser.add_argument(
        "--worst-estrato-penalty",
        type=float,
        default=hyperparameter(hp_defaults, "worst-estrato-penalty", 0.0, float),
    )
    parser.add_argument(
        "--weight-mode",
        type=str,
        default=hyperparameter(hp_defaults, "weight-mode", "snapshot"),
        choices=sorted(WEIGHT_MODES),
    )
    parser.add_argument(
        "--weight-max-multiplier",
        type=float,
        default=hyperparameter(hp_defaults, "weight-max-multiplier", 1.0, float),
    )
    parser.add_argument(
        "--weight-density-bin-width",
        type=float,
        default=hyperparameter(hp_defaults, "weight-density-bin-width", 5.0, float),
    )
    parser.add_argument(
        "--fixed-params-json",
        type=str,
        default=hyperparameter(hp_defaults, "fixed-params-json", ""),
    )
    parser.add_argument("--light-features", type=parse_bool, default=hyperparameter(hp_defaults, "light-features", True, parse_bool))
    parser.add_argument("--one-hot-features", type=parse_bool, default=hyperparameter(hp_defaults, "one-hot-features", True, parse_bool))
    parser.add_argument(
        "--categorical-mode",
        type=str,
        default=hyperparameter(hp_defaults, "categorical-mode", None),
        choices=sorted(CATEGORICAL_MODES),
    )
    parser.add_argument("--quantiles", type=parse_bool, default=hyperparameter(hp_defaults, "quantiles", True, parse_bool))
    parser.add_argument("--walk-forward-quantiles", type=parse_bool, default=hyperparameter(hp_defaults, "walk-forward-quantiles", False, parse_bool))
    parser.add_argument("--shap", type=parse_bool, default=hyperparameter(hp_defaults, "shap", True, parse_bool))
    parser.add_argument("--diagnostics", type=parse_bool, default=hyperparameter(hp_defaults, "diagnostics", True, parse_bool))
    parser.add_argument("--diagnostics-only", type=parse_bool, default=hyperparameter(hp_defaults, "diagnostics-only", False, parse_bool))
    parser.add_argument("--skip-optuna", type=parse_bool, default=hyperparameter(hp_defaults, "skip-optuna", False, parse_bool))
    parser.add_argument("--train-zafras", type=str, default=hyperparameter(hp_defaults, "train-zafras", ""))
    parser.add_argument("--evaluation-zafras", type=str, default=hyperparameter(hp_defaults, "evaluation-zafras", ""))
    parser.add_argument("--scoring-zafras", type=str, default=hyperparameter(hp_defaults, "scoring-zafras", ""))
    parser.add_argument("--exclude-features", type=str, default=hyperparameter(hp_defaults, "exclude-features", ""))
    args, unknown_args = parser.parse_known_args()
    if unknown_args:
        log(f"Ignoring unknown arguments: {unknown_args}")
    if args.diagnostics_only:
        args.diagnostics = True
    resolved_objective_mode = resolve_objective_mode(args.objective_mode, args.walk_forward)
    train_zafras = parse_csv_list(args.train_zafras)
    evaluation_zafras = parse_csv_list(args.evaluation_zafras)
    scoring_zafras = parse_csv_list(args.scoring_zafras)
    requested_excluded_features = parse_csv_list(args.exclude_features)
    if args.weight_max_multiplier < 1.0:
        raise ValueError("--weight-max-multiplier must be at least 1.0")
    if args.weight_density_bin_width <= 0:
        raise ValueError("--weight-density-bin-width must be positive")
    if args.high_yield_penalty < 0 or args.worst_estrato_penalty < 0:
        raise ValueError("Objective penalties must be non-negative")
    if args.search_profile == "phase4_catboost" and args.model_type != "catboost":
        raise ValueError("phase4_catboost search profile requires --model-type catboost")
    fixed_params = (
        json.loads(args.fixed_params_json)
        if args.fixed_params_json.strip()
        else {}
    )
    if fixed_params and not args.skip_optuna:
        raise ValueError("--fixed-params-json requires --skip-optuna true")
    validate_zafra_configuration(train_zafras, evaluation_zafras, scoring_zafras)

    data_dir = os.environ.get("SM_CHANNEL_TRAIN", "/opt/ml/input/data/train")
    model_dir = os.environ.get("SM_MODEL_DIR", "/opt/ml/model")
    output_dir = os.environ.get("SM_OUTPUT_DATA_DIR", "/opt/ml/output/data")
    os.makedirs(model_dir, exist_ok=True)
    os.makedirs(output_dir, exist_ok=True)

    source_df = load_parquet_dir(data_dir)
    log(f"Loaded input dataframe: rows={len(source_df):,}, columns={len(source_df.columns):,}")
    input_df, future_scoring_df, excluded_scoring_df, training_filter_info = partition_unified_rows(
        source_df,
        args.target,
    )
    if training_filter_info["training_filter_applied"]:
        log(
            "Filtered unified dataset for training: "
            f"before={training_filter_info['input_rows_before_training_filter']:,}, "
            f"after={training_filter_info['input_rows_after_training_filter']:,}, "
            f"removed={training_filter_info['filtered_non_training_rows']:,}, "
            f"asof_invalid={training_filter_info['asof_invalid_rows']:,}, "
            f"future_scoring={training_filter_info['future_scoring_rows']:,}, "
            f"future_scoring_excluded={training_filter_info['future_scoring_excluded_rows']:,}, "
            f"roles={training_filter_info['dataset_role_counts']}"
        )

    categorical_mode = resolve_categorical_mode(args.categorical_mode, args.one_hot_features)
    validate_categorical_mode_for_model(categorical_mode, args.model_type)
    log(f"Categorical mode: {categorical_mode}")

    log(f"Building {args.dataset_type} raw feature matrix")
    X_raw, y, metadata = build_dataset(
        input_df,
        dataset_type=args.dataset_type,
        target=args.target,
        light_features=args.light_features,
    )
    if (
        args.target_mode in {"residual_last_hist_tch", "direct_metric_tons"}
        and RESIDUAL_ANCHOR_FEATURE in requested_excluded_features
    ):
        raise ValueError(
            f"--exclude-features cannot remove {RESIDUAL_ANCHOR_FEATURE} "
            f"when target_mode={args.target_mode}"
        )
    if args.target_mode in {"residual_last_hist_tch", "direct_metric_tons"}:
        if RESIDUAL_ANCHOR_FEATURE not in X_raw.columns:
            raise ValueError(
                f"target_mode={args.target_mode} requires feature "
                f"{RESIDUAL_ANCHOR_FEATURE}"
            )
        residual_eligible = pd.to_numeric(
            X_raw[RESIDUAL_ANCHOR_FEATURE],
            errors="coerce",
        ).notna()
        removed = int((~residual_eligible).sum())
        if removed:
            log(
                f"Residual target eligibility removed {removed:,} labeled rows "
                f"without {RESIDUAL_ANCHOR_FEATURE}"
            )
        X_raw = X_raw.loc[residual_eligible].copy()
        y = y.loc[residual_eligible].copy()
        metadata = metadata[
            metadata["cod_cg_zafra"].isin(X_raw.index)
        ].copy()
    if args.target_mode == "direct_metric_tons":
        area = (
            metadata.set_index("cod_cg_zafra")["area"]
            .reindex(X_raw.index)
            .pipe(pd.to_numeric, errors="coerce")
        )
        eligible_area = area.notna() & area.gt(0)
        removed = int((~eligible_area).sum())
        if removed:
            log(
                f"Direct metric-tons eligibility removed {removed:,} rows "
                "without positive area"
            )
        X_raw = X_raw.loc[eligible_area].copy()
        y = y.loc[eligible_area].copy()
        X_raw[DIRECT_AREA_FEATURE] = area.loc[eligible_area]
        metadata = metadata[
            metadata["cod_cg_zafra"].isin(X_raw.index)
        ].copy()
    X_raw, excluded_features = exclude_feature_columns(
        X_raw,
        requested_excluded_features,
    )
    if excluded_features:
        log(f"Excluded configured features: {excluded_features}")
    if scoring_zafras:
        scoring_zafra_col = "zafra_norm" if "zafra_norm" in future_scoring_df.columns else "zafra"
        available_scoring_zafras = future_scoring_df[scoring_zafra_col].dropna().unique()
        require_requested_zafras(scoring_zafras, available_scoring_zafras, "scoring")
        future_scoring_df = future_scoring_df[
            future_scoring_df[scoring_zafra_col].isin(scoring_zafras)
        ].copy()
        if not excluded_scoring_df.empty:
            excluded_scoring_df = excluded_scoring_df[
                excluded_scoring_df[scoring_zafra_col].isin(scoring_zafras)
            ].copy()
    else:
        future_scoring_df = future_scoring_df.iloc[0:0].copy()
        excluded_scoring_df = excluded_scoring_df.iloc[0:0].copy()

    future_X_raw = pd.DataFrame()
    future_metadata = pd.DataFrame()
    if not future_scoring_df.empty:
        if args.dataset_type not in {"feature_table", "preaggregated"}:
            raise ValueError("Future scoring currently requires dataset_type=feature_table or preaggregated")
        log("Building future scoring feature matrix without requiring a target")
        future_X_raw, _, future_metadata = build_dataset(
            future_scoring_df,
            dataset_type=args.dataset_type,
            target=args.target,
            light_features=args.light_features,
            require_target=False,
        )
        future_X_raw, future_excluded_features = exclude_feature_columns(
            future_X_raw,
            requested_excluded_features,
        )
        if future_excluded_features != excluded_features:
            raise ValueError(
                "Excluded feature order differs between training and future scoring: "
                f"training={excluded_features}, scoring={future_excluded_features}"
            )
        if args.target_mode in {"residual_last_hist_tch", "direct_metric_tons"}:
            missing_future_anchor = int(
                pd.to_numeric(
                    future_X_raw[RESIDUAL_ANCHOR_FEATURE],
                    errors="coerce",
                ).isna().sum()
            )
            if missing_future_anchor:
                raise ValueError(
                    f"Future scoring has {missing_future_anchor} rows without "
                    f"{RESIDUAL_ANCHOR_FEATURE}"
                )
        if args.target_mode == "direct_metric_tons":
            future_area = (
                future_metadata.set_index("cod_cg_zafra")["area"]
                .reindex(future_X_raw.index)
                .pipe(pd.to_numeric, errors="coerce")
            )
            if future_area.isna().any() or (future_area <= 0).any():
                raise ValueError(
                    "Future scoring has rows without positive area for "
                    "target_mode=direct_metric_tons"
                )
            future_X_raw[DIRECT_AREA_FEATURE] = future_area
        log(
            f"Built future scoring matrix: rows={len(future_X_raw):,}, "
            f"features={future_X_raw.shape[1]:,}"
        )
    log(f"Built raw feature matrix: rows={len(X_raw):,}, features={X_raw.shape[1]:,}")

    log("Creating explicit train/evaluation split")
    metadata_by_group = metadata.set_index("cod_cg_zafra")
    available_labeled_zafras = metadata_by_group["zafra_norm"].dropna().unique()
    require_requested_zafras(train_zafras, available_labeled_zafras, "training")
    require_requested_zafras(evaluation_zafras, available_labeled_zafras, "evaluation")
    train_idx = indexes_for_zafras(metadata, train_zafras).intersection(X_raw.index)
    evaluation_idx = indexes_for_zafras(metadata, evaluation_zafras).intersection(X_raw.index)
    unassigned_idx = X_raw.index.difference(train_idx.union(evaluation_idx))

    if train_idx.empty or evaluation_idx.empty:
        raise ValueError(
            "Explicit split produced an empty group: "
            f"train={len(train_idx)}, evaluation={len(evaluation_idx)}"
        )
    if args.walk_forward and len(train_zafras) < 2:
        raise ValueError("Walk-forward requires at least two --train-zafras")
    if len(unassigned_idx):
        unassigned_zafras = sorted(metadata_by_group.loc[unassigned_idx, "zafra_norm"].dropna().unique())
        log(f"Ignoring labeled zafras not assigned to train/evaluation: {unassigned_zafras}")

    if args.diagnostics_only:
        log("Diagnostics-only mode enabled; saving pre-encoding diagnostics and exiting before tuning/training")
        save_feature_diagnostics(X_raw, y, train_idx, evaluation_idx, output_dir)
        with open(os.path.join(output_dir, "feature_list.json"), "w") as f:
            json.dump(list(X_raw.columns), f, indent=2)
        with open(os.path.join(output_dir, "excluded_features.json"), "w") as f:
            json.dump(excluded_features, f, indent=2)
        with open(os.path.join(output_dir, "split_metadata.json"), "w") as f:
            json.dump(
                {
                    "run_mode": "diagnostics_only",
                    "diagnostics_stage": "pre_encoding",
                    "dataset_type": args.dataset_type,
                    "model_type": args.model_type,
                    "target": args.target,
                    "target_mode": args.target_mode,
                    "input_rows": int(len(source_df)),
                    **training_filter_info,
                    "matrix_rows": int(len(X_raw)),
                    "feature_count": int(X_raw.shape[1]),
                    "snapshot_aware": bool("snapshot_day" in metadata.columns),
                    "snapshot_days": sorted(
                        int(value)
                        for value in metadata["snapshot_day"].dropna().unique()
                    ) if "snapshot_day" in metadata.columns else [],
                    "training_cycles": int(
                        metadata.loc[
                            metadata["cod_cg_zafra"].isin(train_idx),
                            "cycle_id",
                        ].nunique()
                    ) if "cycle_id" in metadata.columns else int(len(train_idx)),
                    "excluded_features": excluded_features,
                    "light_features": bool(args.light_features),
                    "one_hot_features": bool(args.one_hot_features),
                    "categorical_mode": categorical_mode,
                    "categorical_columns": categorical_feature_columns(X_raw),
                    "quantiles": False,
                    "walk_forward": bool(args.walk_forward),
                    "walk_forward_stability_penalty": float(args.walk_forward_stability_penalty),
                    "objective_mode": args.objective_mode,
                    "resolved_objective_mode": resolved_objective_mode,
                    "aggregate_penalty": float(args.aggregate_penalty),
                    "high_yield_penalty": float(args.high_yield_penalty),
                    "worst_estrato_penalty": float(args.worst_estrato_penalty),
                    "weight_mode": args.weight_mode,
                    "weight_max_multiplier": float(args.weight_max_multiplier),
                    "weight_density_bin_width": float(args.weight_density_bin_width),
                    "fixed_params": fixed_params,
                    "search_profile": args.search_profile,
                    "configured_train_zafras": train_zafras,
                    "configured_evaluation_zafras": evaluation_zafras,
                    "configured_scoring_zafras": scoring_zafras,
                    "shap": False,
                    "diagnostics": True,
                    "train_rows": int(len(train_idx)),
                    "evaluation_rows": int(len(evaluation_idx)),
                    "unassigned_labeled_rows": int(len(unassigned_idx)),
                    "future_scoring_enabled": bool(scoring_zafras),
                    "future_scoring_rows": int(len(future_X_raw)),
                    "train_zafras": sorted(metadata_by_group.loc[train_idx, "zafra_norm"].dropna().unique()),
                    "evaluation_zafras_present": sorted(metadata_by_group.loc[evaluation_idx, "zafra_norm"].dropna().unique()),
                    "scoring_zafras_present": sorted(future_metadata["zafra_norm"].dropna().unique()) if not future_metadata.empty else [],
                },
                f,
                indent=2,
            )
        log("Diagnostics artifacts saved.")
        return

    log("Encoding categorical features after explicit split")
    X, categorical_encoding_state = fit_transform_categorical_features(
        X_raw,
        train_idx=train_idx,
        mode=categorical_mode,
    )
    X = prepare_features_for_model(X, args.model_type, categorical_mode)
    y_model = model_target(y, X, args.target_mode)
    log(f"Built encoded feature matrix: rows={len(X):,}, features={X.shape[1]:,}")
    if categorical_mode == CATEGORICAL_MODE_NATIVE:
        log(f"Using native categorical columns: {categorical_feature_columns(X)}")

    X_train = X.loc[train_idx]
    y_train = y.loc[train_idx]
    y_train_model = y_model.loc[train_idx]
    X_evaluation = X.loc[evaluation_idx]
    y_evaluation = y.loc[evaluation_idx]

    log(
        "Dataset: "
        f"input_rows={len(input_df):,}, matrix_rows={len(X):,}, features={X.shape[1]:,}, "
        f"train={len(train_idx):,}, evaluation={len(evaluation_idx):,}, "
        f"future_scoring={len(future_X_raw):,}"
    )

    if args.diagnostics:
        log("Saving feature diagnostics")
        save_feature_diagnostics(X, y, train_idx, evaluation_idx, output_dir)
    else:
        log("Skipping feature diagnostics")

    if args.skip_optuna:
        best_params = fixed_params
        source = "fixed promoted parameters" if fixed_params else "default parameters"
        log(f"Skipping Optuna; using {source} for model_type={args.model_type}")
        optuna_trials = pd.DataFrame()
    elif args.walk_forward:
        if resolved_objective_mode == "aggregate_tch_sum":
            objective_description = (
                "score=mean_rmse+"
                f"{args.aggregate_penalty}*mean_abs_raw_tch_sum_pct_diff"
            )
        elif resolved_objective_mode == "aggregate_metric_tons":
            objective_description = (
                "score=mean_rmse+"
                f"{args.aggregate_penalty}*mean_abs_metric_tons_pct_diff+"
                f"{args.high_yield_penalty}*mean_high_yield_abs_bias+"
                f"{args.worst_estrato_penalty}*mean_worst_estrato_abs_pct_error"
            )
        else:
            objective_description = f"score=mean_r2-{args.walk_forward_stability_penalty}*std_r2"
        log(
            "Starting Optuna with walk-forward objective: "
            f"model_type={args.model_type}, search_profile={args.search_profile}, "
            f"n_trials={args.n_trials}, {objective_description}"
        )
        best_params, study = fit_with_optuna(
            X_train,
            y_train_model,
            y_train,
            X_evaluation,
            y_evaluation,
            X,
            y_model,
            y,
            metadata,
            model_type=args.model_type,
            n_trials=args.n_trials,
            walk_forward=args.walk_forward,
            stability_penalty=args.walk_forward_stability_penalty,
            categorical_mode=categorical_mode,
            objective_mode=args.objective_mode,
            aggregate_penalty=args.aggregate_penalty,
            walk_forward_zafras=train_zafras,
            target_mode=args.target_mode,
            weight_mode=args.weight_mode,
            weight_max_multiplier=args.weight_max_multiplier,
            weight_density_bin_width=args.weight_density_bin_width,
            high_yield_penalty=args.high_yield_penalty,
            worst_estrato_penalty=args.worst_estrato_penalty,
            search_profile=args.search_profile,
        )
        optuna_trials = study.trials_dataframe()
    else:
        if resolved_objective_mode == "aggregate_tch_sum":
            objective_description = f"score=evaluation_rmse+{args.aggregate_penalty}*abs_raw_tch_sum_pct_diff"
        elif resolved_objective_mode == "aggregate_metric_tons":
            objective_description = f"score=evaluation_rmse+{args.aggregate_penalty}*abs_metric_tons_pct_diff"
        else:
            objective_description = "score=evaluation_rmse"
        log(f"Starting Optuna: model_type={args.model_type}, n_trials={args.n_trials}, {objective_description}")
        best_params, study = fit_with_optuna(
            X_train,
            y_train_model,
            y_train,
            X_evaluation,
            y_evaluation,
            X,
            y_model,
            y,
            metadata,
            model_type=args.model_type,
            n_trials=args.n_trials,
            walk_forward=args.walk_forward,
            stability_penalty=args.walk_forward_stability_penalty,
            categorical_mode=categorical_mode,
            objective_mode=args.objective_mode,
            aggregate_penalty=args.aggregate_penalty,
            walk_forward_zafras=train_zafras,
            target_mode=args.target_mode,
            weight_mode=args.weight_mode,
            weight_max_multiplier=args.weight_max_multiplier,
            weight_density_bin_width=args.weight_density_bin_width,
            high_yield_penalty=args.high_yield_penalty,
            worst_estrato_penalty=args.worst_estrato_penalty,
            search_profile=args.search_profile,
        )
        optuna_trials = study.trials_dataframe()
    log(f"Best params: {best_params}")

    log("Training final model on train split")
    model = build_estimator(args.model_type, best_params)
    train_sample_weight = training_weights_for_index(
        metadata,
        y,
        X,
        train_idx,
        train_idx,
        mode=args.weight_mode,
        max_multiplier=args.weight_max_multiplier,
        density_bin_width=args.weight_density_bin_width,
    )
    train_weight_diagnostics = weight_diagnostics(
        metadata,
        y,
        X,
        train_idx,
        mode=args.weight_mode,
        max_multiplier=args.weight_max_multiplier,
        density_bin_width=args.weight_density_bin_width,
    )
    log(
        "Training weights: "
        f"mode={args.weight_mode}, cap={args.weight_max_multiplier}, "
        f"summary={dict(zip(train_weight_diagnostics['metric'], train_weight_diagnostics['value']))}"
    )
    fit_model(
        model,
        args.model_type,
        X_train,
        y_train_model,
        categorical_mode,
        sample_weight=train_sample_weight,
    )

    quantile_models = {}
    quantiles_enabled = bool(args.quantiles)
    if quantiles_enabled:
        if args.model_type == "random_forest":
            log("Using random forest tree-distribution quantiles: p10, p50, p90")
        elif args.model_type in {"lightgbm", "catboost"}:
            log(f"Training {args.model_type} native quantile models: p10, p50, p90")
            quantile_models = fit_quantile_models(
                X_train,
                y_train_model,
                args.model_type,
                best_params,
                categorical_mode,
                sample_weight=train_sample_weight,
            )
        else:
            log(f"Training sklearn quantile auxiliary models for {args.model_type}: p10, p50, p90")
            quantile_models = fit_quantile_models(
                X_train,
                y_train_model,
                args.model_type,
                best_params,
                categorical_mode,
                sample_weight=train_sample_weight,
            )

    metrics_by_split = {}
    zafra_frames = []
    lot_prediction_frames = []
    quantile_prediction_frames = []
    for split, split_idx in {
        "train": train_idx,
        "evaluation": evaluation_idx,
    }.items():
        if split_idx.empty:
            continue
        split_metrics, split_zafra, split_lot_predictions = evaluate_split(
            model,
            X.loc[split_idx],
            y.loc[split_idx],
            metadata,
            split=split,
            target_mode=args.target_mode,
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
                    target_mode=args.target_mode,
                )
            )
        log(f"{split} metrics: {split_metrics}")

    metrics_by_zafra = pd.concat(zafra_frames, ignore_index=True)
    predictions_by_lot = pd.concat(lot_prediction_frames, ignore_index=True)
    predictions_evaluation = predictions_by_lot[predictions_by_lot["split"] == "evaluation"].copy()
    metrics_by_zafra_evaluation = metrics_by_zafra[metrics_by_zafra["split"] == "evaluation"].copy()
    metrics_by_lot_error = lot_error_metrics(predictions_by_lot)
    metrics_by_snapshot_day = snapshot_day_metrics(predictions_by_lot)
    metrics_by_estrato = estrato_metrics(predictions_by_lot)
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
            merge_keys = ["split", "zafra_norm"]
            if (
                "snapshot_day" in metrics_by_zafra.columns
                and "snapshot_day" in metrics_by_zafra_quantiles.columns
            ):
                merge_keys.append("snapshot_day")
            metrics_by_zafra = metrics_by_zafra.merge(
                metrics_by_zafra_quantiles,
                on=merge_keys,
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
    walk_forward_predictions = pd.DataFrame()
    walk_forward_quantile_predictions = pd.DataFrame()
    if args.walk_forward:
        walk_forward_metrics, walk_forward_predictions, walk_forward_quantile_predictions = run_walk_forward(
            X,
            y_model,
            y,
            metadata,
            args.model_type,
            best_params,
            categorical_mode,
            train_zafras,
            target_mode=args.target_mode,
            weight_mode=args.weight_mode,
            weight_max_multiplier=args.weight_max_multiplier,
            weight_density_bin_width=args.weight_density_bin_width,
            quantiles_enabled=bool(args.walk_forward_quantiles),
        )
        log(f"Walk-forward metrics: {walk_forward_metrics.to_dict(orient='records')}")

    if args.shap:
        log("Generating SHAP artifacts if available")
        save_shap_values(model, args.model_type, X.loc[evaluation_idx], output_dir)
    else:
        log("Skipping SHAP artifacts")

    future_predictions = pd.DataFrame()
    future_summary = pd.DataFrame()
    future_estrato_summary = pd.DataFrame()
    if not future_X_raw.empty:
        future_X = transform_categorical_features(future_X_raw, categorical_encoding_state)
        future_X = prepare_features_for_model(
            future_X,
            args.model_type,
            categorical_mode,
        )
        missing_features = sorted(set(X.columns) - set(future_X.columns))
        extra_features = sorted(set(future_X.columns) - set(X.columns))
        if missing_features or extra_features:
            raise ValueError(
                "Future scoring feature schema differs from training: "
                f"missing={missing_features}, extra={extra_features}"
            )
        future_X = future_X[X.columns]
        future_predictions = future_scoring_predictions(
            model,
            args.model_type,
            quantile_models,
            future_X,
            future_metadata,
            target_mode=args.target_mode,
        )
        future_summary = summarize_future_scoring(future_predictions)
        future_estrato_summary = future_scoring_estrato_metrics(future_predictions)
        log(f"Future scoring summary: {future_summary.to_dict(orient='records')}")
        if not future_estrato_summary.empty:
            log(f"Future scoring by estrato: {future_estrato_summary.to_dict(orient='records')}")

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
    if not metrics_by_snapshot_day.empty:
        metrics_by_snapshot_day.to_csv(
            os.path.join(output_dir, "metrics_by_snapshot_day.csv"),
            index=False,
        )
    if not metrics_by_estrato.empty:
        metrics_by_estrato.to_csv(os.path.join(output_dir, "metrics_by_estrato.csv"), index=False)
    metrics_by_tch_range.to_csv(os.path.join(output_dir, "metrics_by_tch_range.csv"), index=False)
    metrics_tail_error.to_csv(os.path.join(output_dir, "tail_error_report.csv"), index=False)
    metrics_by_zafra.to_csv(os.path.join(output_dir, "metrics_by_zafra.csv"), index=False)
    metrics_by_zafra.to_csv(os.path.join(output_dir, "tch_by_zafra.csv"), index=False)
    metrics_by_zafra_aggregate.to_csv(os.path.join(output_dir, "metrics_by_zafra_aggregate.csv"), index=False)
    if not predictions_evaluation.empty:
        predictions_evaluation.to_csv(os.path.join(output_dir, "evaluation_predictions.csv"), index=False)
    if not metrics_by_zafra_evaluation.empty:
        metrics_by_zafra_evaluation.to_csv(os.path.join(output_dir, "evaluation_metrics_by_zafra.csv"), index=False)
    if not future_predictions.empty:
        future_predictions.to_csv(os.path.join(output_dir, "future_scoring_predictions.csv"), index=False)
    if not future_summary.empty:
        future_summary.to_csv(os.path.join(output_dir, "future_scoring_by_zafra.csv"), index=False)
    if not future_estrato_summary.empty:
        future_estrato_summary.to_csv(
            os.path.join(output_dir, "future_scoring_by_estrato.csv"),
            index=False,
        )
    if not excluded_scoring_df.empty:
        excluded_scoring_df.to_csv(os.path.join(output_dir, "future_scoring_excluded.csv"), index=False)
    optuna_trials.to_csv(os.path.join(output_dir, "optuna_trials.csv"), index=False)
    train_weight_diagnostics.to_csv(
        os.path.join(output_dir, "training_weight_diagnostics.csv"),
        index=False,
    )
    if not walk_forward_metrics.empty:
        walk_forward_metrics.to_csv(os.path.join(output_dir, "walk_forward_metrics.csv"), index=False)
    if not walk_forward_predictions.empty:
        walk_forward_predictions.to_csv(
            os.path.join(output_dir, "walk_forward_predictions.csv"),
            index=False,
        )

    if not walk_forward_quantile_predictions.empty:
        walk_forward_quantile_predictions.to_csv(
            os.path.join(output_dir, "walk_forward_quantile_predictions.csv"),
            index=False,
        )
    with open(os.path.join(output_dir, "metrics.json"), "w") as f:
        json.dump(metrics_by_split, f, indent=2)
    with open(os.path.join(output_dir, "best_params.json"), "w") as f:
        json.dump(best_params, f, indent=2)
    with open(os.path.join(output_dir, "feature_list.json"), "w") as f:
        json.dump(list(X.columns), f, indent=2)
    with open(os.path.join(output_dir, "excluded_features.json"), "w") as f:
        json.dump(excluded_features, f, indent=2)
    with open(os.path.join(output_dir, "split_metadata.json"), "w") as f:
        json.dump(
            {
                "dataset_type": args.dataset_type,
                "model_type": args.model_type,
                "target": args.target,
                "target_mode": args.target_mode,
                "input_rows": int(len(source_df)),
                **training_filter_info,
                "matrix_rows": int(len(X)),
                "feature_count": int(X.shape[1]),
                "snapshot_aware": bool("snapshot_day" in metadata.columns),
                "snapshot_days": sorted(
                    int(value)
                    for value in metadata["snapshot_day"].dropna().unique()
                ) if "snapshot_day" in metadata.columns else [],
                "training_cycles": int(
                    metadata.loc[
                        metadata["cod_cg_zafra"].isin(train_idx),
                        "cycle_id",
                    ].nunique()
                ) if "cycle_id" in metadata.columns else int(len(train_idx)),
                "evaluation_cycles": int(
                    metadata.loc[
                        metadata["cod_cg_zafra"].isin(evaluation_idx),
                        "cycle_id",
                    ].nunique()
                ) if "cycle_id" in metadata.columns else int(len(evaluation_idx)),
                "excluded_features": excluded_features,
                "light_features": bool(args.light_features),
                "one_hot_features": bool(args.one_hot_features),
                "categorical_mode": categorical_mode,
                "categorical_columns": categorical_encoding_state.categorical_cols,
                "dropped_categorical_columns": categorical_encoding_state.drop_cols,
                "quantiles": bool(quantiles_enabled),
                "walk_forward_quantiles": bool(args.walk_forward_quantiles),
                "quantile_alphas": list(QUANTILE_ALPHAS),
                "walk_forward": bool(args.walk_forward),
                "walk_forward_stability_penalty": float(args.walk_forward_stability_penalty),
                "objective_mode": args.objective_mode,
                "resolved_objective_mode": resolved_objective_mode,
                "aggregate_penalty": float(args.aggregate_penalty),
                "high_yield_penalty": float(args.high_yield_penalty),
                "worst_estrato_penalty": float(args.worst_estrato_penalty),
                "weight_mode": args.weight_mode,
                "weight_max_multiplier": float(args.weight_max_multiplier),
                "weight_density_bin_width": float(args.weight_density_bin_width),
                "fixed_params": fixed_params,
                "search_profile": args.search_profile,
                "configured_train_zafras": train_zafras,
                "configured_evaluation_zafras": evaluation_zafras,
                "configured_scoring_zafras": scoring_zafras,
                "skip_optuna": bool(args.skip_optuna),
                "optuna_direction": None if args.skip_optuna else study.direction.name,
                "optuna_best_value": None if args.skip_optuna else float(study.best_value),
                "shap": bool(args.shap),
                "diagnostics": bool(args.diagnostics),
                "train_rows": int(len(train_idx)),
                "evaluation_rows": int(len(evaluation_idx)),
                "unassigned_labeled_rows": int(len(unassigned_idx)),
                "future_scoring_enabled": bool(scoring_zafras),
                "future_scoring_rows": int(len(future_predictions)),
                "future_scoring_excluded_rows": int(len(excluded_scoring_df)),
                "future_scoring_zafras": sorted(
                    future_metadata["zafra_norm"].dropna().unique()
                ) if not future_metadata.empty else [],
                "train_zafras": sorted(metadata_by_group.loc[train_idx, "zafra_norm"].dropna().unique()),
                "evaluation_zafras_present": sorted(
                    metadata_by_group.loc[evaluation_idx, "zafra_norm"].dropna().unique()
                ),
            },
            f,
            indent=2,
        )

    log("Artifacts saved.")


if __name__ == "__main__":
    main()
