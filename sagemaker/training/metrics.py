import numpy as np
import pandas as pd
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

TCH_RANGE_BINS = [-np.inf, 70, 85, 100, 115, 130, np.inf]
TCH_RANGE_LABELS = ["<=70", "70-85", "85-100", "100-115", "115-130", ">130"]
TCH_TOLERANCES = [5, 10, 15]
QUANTILE_LOWER = "pred_tch_p10"
QUANTILE_MEDIAN = "pred_tch_p50"
QUANTILE_UPPER = "pred_tch_p90"


def regression_metrics(y_true, y_pred):
    return {
        "rmse": float(np.sqrt(mean_squared_error(y_true, y_pred))),
        "mae": float(mean_absolute_error(y_true, y_pred)),
        "r2": float(r2_score(y_true, y_pred)),
        "bias": float(np.mean(np.asarray(y_pred) - np.asarray(y_true))),
    }


def lot_predictions(metadata: pd.DataFrame, y_true: pd.Series, y_pred, split: str) -> pd.DataFrame:
    metadata_by_group = metadata.set_index("cod_cg_zafra").loc[y_true.index].copy()
    metadata_by_group.index.name = "cod_cg_zafra"
    df = metadata_by_group.reset_index()
    df["split"] = split
    df["actual_tch"] = y_true.to_numpy()
    df["pred_tch"] = np.asarray(y_pred)
    df["tch_error"] = df["pred_tch"] - df["actual_tch"]
    df["tch_abs_error"] = df["tch_error"].abs()
    df["tch_pct_error"] = df["tch_error"] / df["actual_tch"]

    ordered_cols = [
        "split",
        "cod_cg_zafra",
        "cod_cg",
        "zafra_norm",
        "area",
        "actual_tch",
        "pred_tch",
        "tch_error",
        "tch_abs_error",
        "tch_pct_error",
    ]
    return df[[col for col in ordered_cols if col in df.columns]]


def lot_error_metrics(predictions_by_lot: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for split, df in predictions_by_lot.groupby("split", dropna=False):
        row = {
            "split": split,
            "rows": int(len(df)),
            "tch_bias": float(df["tch_error"].mean()),
            "tch_mae": float(df["tch_abs_error"].mean()),
            "tch_rmse": float(np.sqrt(np.mean(df["tch_error"] ** 2))),
        }
        for tolerance in TCH_TOLERANCES:
            row[f"pct_within_{tolerance}_tch"] = float((df["tch_abs_error"] <= tolerance).mean() * 100.0)
        rows.append(row)
    return pd.DataFrame(rows)


def tch_range_metrics(predictions_by_lot: pd.DataFrame) -> pd.DataFrame:
    df = predictions_by_lot.copy()
    df["actual_tch_range"] = pd.cut(
        df["actual_tch"],
        bins=TCH_RANGE_BINS,
        labels=TCH_RANGE_LABELS,
        right=True,
        include_lowest=True,
    )

    grouped = df.groupby(["split", "actual_tch_range"], observed=False, dropna=False).agg(
        rows=("actual_tch", "size"),
        actual_tch_mean=("actual_tch", "mean"),
        pred_tch_mean=("pred_tch", "mean"),
        tch_bias=("tch_error", "mean"),
        tch_mae=("tch_abs_error", "mean"),
    )
    rmse = df.groupby(["split", "actual_tch_range"], observed=False, dropna=False)["tch_error"].apply(
        lambda values: float(np.sqrt(np.mean(values**2))) if len(values) else np.nan
    )
    grouped["tch_rmse"] = rmse
    for tolerance in TCH_TOLERANCES:
        grouped[f"pct_within_{tolerance}_tch"] = df.groupby(
            ["split", "actual_tch_range"], observed=False, dropna=False
        )["tch_abs_error"].apply(lambda values, t=tolerance: float((values <= t).mean() * 100.0) if len(values) else np.nan)

    return grouped.reset_index()


def quantile_interval_metrics(quantile_predictions: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for split, df in quantile_predictions.groupby("split", dropna=False):
        interval_width = df[QUANTILE_UPPER] - df[QUANTILE_LOWER]
        interval_hit = df["actual_tch"].between(df[QUANTILE_LOWER], df[QUANTILE_UPPER])
        crossing = df[QUANTILE_LOWER] > df[QUANTILE_UPPER]
        median_error = df[QUANTILE_MEDIAN] - df["actual_tch"]
        rows.append(
            {
                "split": split,
                "rows": int(len(df)),
                "p10_p90_coverage_pct": float(interval_hit.mean() * 100.0),
                "p10_p90_width_mean": float(interval_width.mean()),
                "p10_p90_width_median": float(interval_width.median()),
                "quantile_crossing_pct": float(crossing.mean() * 100.0),
                "p50_bias": float(median_error.mean()),
                "p50_mae": float(median_error.abs().mean()),
                "p50_rmse": float(np.sqrt(np.mean(median_error**2))),
            }
        )
    return pd.DataFrame(rows)


def zafra_metrics(metadata: pd.DataFrame, y_true: pd.Series, y_pred, split: str) -> pd.DataFrame:
    df = lot_predictions(metadata, y_true, y_pred, split)

    grouped = df.groupby("zafra_norm", dropna=False).agg(
        rows=("actual_tch", "size"),
        actual_tch_mean=("actual_tch", "mean"),
        pred_tch_mean=("pred_tch", "mean"),
        actual_tch_median=("actual_tch", "median"),
        pred_tch_median=("pred_tch", "median"),
        tch_bias=("tch_error", "mean"),
        tch_mae=("tch_abs_error", "mean"),
    )
    rmse = df.groupby("zafra_norm", dropna=False)["tch_error"].apply(lambda values: float(np.sqrt(np.mean(values**2))))
    grouped["tch_rmse"] = rmse
    grouped["tch_mean_error"] = grouped["pred_tch_mean"] - grouped["actual_tch_mean"]
    grouped["tch_mean_pct_error"] = grouped["tch_mean_error"] / grouped["actual_tch_mean"]
    grouped.insert(0, "split", split)
    return grouped.reset_index()
