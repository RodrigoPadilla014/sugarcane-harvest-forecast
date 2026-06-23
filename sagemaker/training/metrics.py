import numpy as np
import pandas as pd
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

TCH_RANGE_BINS = [-np.inf, 70, 85, 100, 115, 130, np.inf]
TCH_RANGE_LABELS = ["<=70", "70-85", "85-100", "100-115", "115-130", ">130"]
TCH_TOLERANCES = [5, 10, 15]
QUANTILE_LOWER = "pred_tch_p10"
QUANTILE_MEDIAN = "pred_tch_p50"
QUANTILE_UPPER = "pred_tch_p90"
ESTRATO_COL = "prod_estrato"


def regression_metrics(y_true, y_pred, sample_weight=None):
    weights = None if sample_weight is None else np.asarray(sample_weight)
    return {
        "rmse": float(
            np.sqrt(
                mean_squared_error(
                    y_true,
                    y_pred,
                    sample_weight=weights,
                )
            )
        ),
        "mae": float(
            mean_absolute_error(
                y_true,
                y_pred,
                sample_weight=weights,
            )
        ),
        "r2": float(
            r2_score(
                y_true,
                y_pred,
                sample_weight=weights,
            )
        ),
        "bias": float(
            np.average(
                np.asarray(y_pred) - np.asarray(y_true),
                weights=weights,
            )
        ),
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
    extra_cols = [col for col in df.columns if col not in ordered_cols]
    return df[[col for col in [*ordered_cols, *extra_cols] if col in df.columns]]


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


def snapshot_day_metrics(predictions_by_lot: pd.DataFrame) -> pd.DataFrame:
    if "snapshot_day" not in predictions_by_lot.columns:
        return pd.DataFrame()

    rows = []
    for (split, snapshot_day), df in predictions_by_lot.groupby(
        ["split", "snapshot_day"],
        dropna=False,
    ):
        actual_sum = float(df["actual_tch"].sum())
        pred_sum = float(df["pred_tch"].sum())
        rows.append(
            {
                "split": split,
                "snapshot_day": snapshot_day,
                "rows": int(len(df)),
                "cycles": int(
                    df["cycle_id"].nunique()
                    if "cycle_id" in df.columns
                    else len(df)
                ),
                "rmse": float(np.sqrt(np.mean(df["tch_error"] ** 2))),
                "mae": float(df["tch_abs_error"].mean()),
                "r2": (
                    float(r2_score(df["actual_tch"], df["pred_tch"]))
                    if len(df) >= 2
                    else np.nan
                ),
                "bias": float(df["tch_error"].mean()),
                "actual_tch_sum": actual_sum,
                "pred_tch_sum": pred_sum,
                "tch_sum_diff": pred_sum - actual_sum,
                "tch_sum_pct_diff": (
                    (pred_sum - actual_sum) / actual_sum
                    if actual_sum
                    else np.nan
                ),
            }
        )
    return pd.DataFrame(rows)


def estrato_metrics(predictions_by_lot: pd.DataFrame) -> pd.DataFrame:
    if ESTRATO_COL not in predictions_by_lot.columns:
        return pd.DataFrame()

    df = predictions_by_lot.copy()
    df[ESTRATO_COL] = df[ESTRATO_COL].fillna("<sin estrato>")
    df["actual_metric_tons"] = df["actual_tch"] * df["area"] if "area" in df.columns else np.nan
    df["pred_metric_tons"] = df["pred_tch"] * df["area"] if "area" in df.columns else np.nan

    group_cols = ["split", "zafra_norm", ESTRATO_COL]
    if "snapshot_day" in df.columns:
        group_cols.append("snapshot_day")

    grouped = df.groupby(group_cols, dropna=False).agg(
        rows=("actual_tch", "size"),
        area_sum=("area", "sum"),
        actual_tch_mean=("actual_tch", "mean"),
        pred_tch_mean=("pred_tch", "mean"),
        tch_bias=("tch_error", "mean"),
        tch_mae=("tch_abs_error", "mean"),
        actual_metric_tons_sum=("actual_metric_tons", "sum"),
        pred_metric_tons_sum=("pred_metric_tons", "sum"),
    )
    grouped["tch_rmse"] = df.groupby(group_cols, dropna=False)["tch_error"].apply(
        lambda values: float(np.sqrt(np.mean(values**2))) if len(values) else np.nan
    )
    grouped["metric_tons_diff"] = grouped["pred_metric_tons_sum"] - grouped["actual_metric_tons_sum"]
    grouped["metric_tons_pct_diff"] = grouped["metric_tons_diff"] / grouped["actual_metric_tons_sum"]
    return grouped.reset_index()


def future_scoring_estrato_metrics(predictions: pd.DataFrame) -> pd.DataFrame:
    if predictions.empty or ESTRATO_COL not in predictions.columns:
        return pd.DataFrame()

    df = predictions.copy()
    df[ESTRATO_COL] = df[ESTRATO_COL].fillna("<sin estrato>")
    df["pred_metric_tons"] = df["pred_tch"] * df["area"] if "area" in df.columns else np.nan
    for percentile in (10, 50, 90):
        col = f"pred_tch_p{percentile}"
        if col in df.columns and "area" in df.columns:
            df[f"pred_metric_tons_p{percentile}"] = df[col] * df["area"]

    group_cols = ["zafra_norm", ESTRATO_COL]
    if "snapshot_day" in df.columns:
        group_cols.append("snapshot_day")

    aggregations = {
        "rows": ("pred_tch", "size"),
        "area_sum": ("area", "sum"),
        "pred_tch_mean": ("pred_tch", "mean"),
        "pred_tch_median": ("pred_tch", "median"),
        "pred_metric_tons_sum": ("pred_metric_tons", "sum"),
    }
    for percentile in (10, 50, 90):
        col = f"pred_metric_tons_p{percentile}"
        if col in df.columns:
            aggregations[f"pred_metric_tons_p{percentile}_sum"] = (col, "sum")

    return df.groupby(group_cols, dropna=False).agg(**aggregations).reset_index()


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


def _error_summary(df: pd.DataFrame, group_cols, group_name: str) -> pd.DataFrame:
    grouped = df.groupby(group_cols, observed=False, dropna=False).agg(
        rows=("actual_tch", "size"),
        actual_tch_mean=("actual_tch", "mean"),
        pred_tch_mean=("pred_tch", "mean"),
        actual_tch_median=("actual_tch", "median"),
        pred_tch_median=("pred_tch", "median"),
        tch_bias=("tch_error", "mean"),
        tch_mae=("tch_abs_error", "mean"),
        overprediction_pct=("tch_error", lambda values: float((values > 0).mean() * 100.0)),
        underprediction_pct=("tch_error", lambda values: float((values < 0).mean() * 100.0)),
    )
    rmse = df.groupby(group_cols, observed=False, dropna=False)["tch_error"].apply(
        lambda values: float(np.sqrt(np.mean(values**2))) if len(values) else np.nan
    )
    grouped["tch_rmse"] = rmse
    for tolerance in TCH_TOLERANCES:
        grouped[f"pct_within_{tolerance}_tch"] = df.groupby(group_cols, observed=False, dropna=False)[
            "tch_abs_error"
        ].apply(lambda values, t=tolerance: float((values <= t).mean() * 100.0) if len(values) else np.nan)

    result = grouped.reset_index()
    result.insert(0, "grouping", group_name)
    return result


def tail_error_report(predictions_by_lot: pd.DataFrame, min_rows: int = 30) -> pd.DataFrame:
    df = predictions_by_lot.copy()
    df["actual_tch_range"] = pd.cut(
        df["actual_tch"],
        bins=TCH_RANGE_BINS,
        labels=TCH_RANGE_LABELS,
        right=True,
        include_lowest=True,
    )
    df["tail_group"] = pd.cut(
        df["actual_tch"],
        bins=[-np.inf, 85, 115, np.inf],
        labels=["low", "middle", "high"],
        right=True,
        include_lowest=True,
    )

    grouping_specs = [
        ("split_x_tch_range", ["split", "actual_tch_range"]),
        ("split_x_tail_group", ["split", "tail_group"]),
        ("split_x_zafra_x_tch_range", ["split", "zafra_norm", "actual_tch_range"]),
    ]
    context_cols = [
        "prod_ingenio",
        "prod_cosecha",
        "prod_no_corte",
        "prod_variedad",
        "prod_grupo_de_suelo",
        "prod_grupo_de_humedad",
        "prod_codigo_zae",
        "prod_familia_de_suelo",
        ESTRATO_COL,
    ]
    for col in context_cols:
        if col in df.columns:
            grouping_specs.append((f"split_x_{col}_x_tail_group", ["split", col, "tail_group"]))

    reports = []
    for group_name, group_cols in grouping_specs:
        report = _error_summary(df, group_cols, group_name)
        reports.append(report[report["rows"] >= min_rows])

    return pd.concat(reports, ignore_index=True, sort=False)


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


def zafra_quantile_metrics(quantile_predictions: pd.DataFrame) -> pd.DataFrame:
    if quantile_predictions.empty:
        return pd.DataFrame()

    group_cols = ["split", "zafra_norm"]
    if "snapshot_day" in quantile_predictions.columns:
        group_cols.append("snapshot_day")
    grouped = quantile_predictions.groupby(group_cols, dropna=False).agg(
        actual_tch_sum=("actual_tch", "sum"),
        pred_tch_p10_sum=(QUANTILE_LOWER, "sum"),
        pred_tch_p50_sum=(QUANTILE_MEDIAN, "sum"),
        pred_tch_p90_sum=(QUANTILE_UPPER, "sum"),
    )
    grouped["p10_tch_sum_diff"] = grouped["pred_tch_p10_sum"] - grouped["actual_tch_sum"]
    grouped["p50_tch_sum_diff"] = grouped["pred_tch_p50_sum"] - grouped["actual_tch_sum"]
    grouped["p90_tch_sum_diff"] = grouped["pred_tch_p90_sum"] - grouped["actual_tch_sum"]
    grouped["p10_tch_sum_pct_diff"] = grouped["p10_tch_sum_diff"] / grouped["actual_tch_sum"]
    grouped["p50_tch_sum_pct_diff"] = grouped["p50_tch_sum_diff"] / grouped["actual_tch_sum"]
    grouped["p90_tch_sum_pct_diff"] = grouped["p90_tch_sum_diff"] / grouped["actual_tch_sum"]
    grouped["p10_p90_tch_sum_width"] = grouped["pred_tch_p90_sum"] - grouped["pred_tch_p10_sum"]
    grouped["p10_p90_tch_sum_width_pct"] = grouped["p10_p90_tch_sum_width"] / grouped["actual_tch_sum"]
    grouped["actual_tch_sum_within_p10_p90"] = grouped["actual_tch_sum"].between(
        grouped["pred_tch_p10_sum"],
        grouped["pred_tch_p90_sum"],
    )
    return grouped.drop(columns=["actual_tch_sum"]).reset_index()


def aggregate_zafra_metrics(metrics_by_zafra: pd.DataFrame) -> pd.DataFrame:
    def summarize(df: pd.DataFrame, label: str) -> dict:
        actual = df["actual_tch_sum"].astype(float)
        pred = df["pred_tch_sum"].astype(float)
        diff = pred - actual
        row = {
            "split": label,
            "zafras": int(len(df)),
            "actual_tch_sum": float(actual.sum()),
            "pred_tch_sum": float(pred.sum()),
            "tch_sum_diff": float(diff.sum()),
            "tch_sum_pct_diff": float(diff.sum() / actual.sum()) if actual.sum() else np.nan,
            "zafra_tch_sum_mae": float(diff.abs().mean()) if len(df) else np.nan,
            "zafra_tch_sum_rmse": float(np.sqrt(np.mean(diff**2))) if len(df) else np.nan,
            "zafra_tch_sum_bias": float(diff.mean()) if len(df) else np.nan,
            "aggregate_zafra_r2": np.nan,
        }
        if len(df) >= 2:
            row["aggregate_zafra_r2"] = float(r2_score(actual, pred))
        return row

    rows = []
    if "snapshot_day" in metrics_by_zafra.columns:
        for snapshot_day, snapshot_df in metrics_by_zafra.groupby(
            "snapshot_day",
            dropna=False,
        ):
            rows.append(summarize(snapshot_df, f"all_snapshot_{snapshot_day}"))
            for split, df in snapshot_df.groupby("split", dropna=False):
                rows.append(
                    summarize(df, f"{split}_snapshot_{snapshot_day}")
                )
    else:
        rows.append(summarize(metrics_by_zafra, "all"))
        for split, df in metrics_by_zafra.groupby("split", dropna=False):
            rows.append(summarize(df, split))
    return pd.DataFrame(rows)


def zafra_metrics(metadata: pd.DataFrame, y_true: pd.Series, y_pred, split: str) -> pd.DataFrame:
    df = lot_predictions(metadata, y_true, y_pred, split)
    df["actual_area_weighted_tch"] = df["actual_tch"] * df["area"] if "area" in df.columns else np.nan
    df["pred_area_weighted_tch"] = df["pred_tch"] * df["area"] if "area" in df.columns else np.nan

    group_cols = ["zafra_norm"]
    if "snapshot_day" in df.columns:
        group_cols.append("snapshot_day")
    grouped = df.groupby(group_cols, dropna=False).agg(
        rows=("actual_tch", "size"),
        actual_tch_sum=("actual_tch", "sum"),
        pred_tch_sum=("pred_tch", "sum"),
        actual_area_weighted_tch_sum=("actual_area_weighted_tch", "sum"),
        pred_area_weighted_tch_sum=("pred_area_weighted_tch", "sum"),
        actual_tch_mean=("actual_tch", "mean"),
        pred_tch_mean=("pred_tch", "mean"),
        actual_tch_median=("actual_tch", "median"),
        pred_tch_median=("pred_tch", "median"),
        tch_bias=("tch_error", "mean"),
        tch_mae=("tch_abs_error", "mean"),
    )
    rmse = df.groupby(group_cols, dropna=False)["tch_error"].apply(
        lambda values: float(np.sqrt(np.mean(values**2)))
    )
    grouped["tch_rmse"] = rmse
    r2 = df.groupby(group_cols, dropna=False).apply(
        lambda values: float(r2_score(values["actual_tch"], values["pred_tch"])) if len(values) >= 2 else np.nan,
        include_groups=False,
    )
    grouped["r2"] = r2
    grouped["tch_sum_diff"] = grouped["pred_tch_sum"] - grouped["actual_tch_sum"]
    grouped["tch_sum_pct_diff"] = grouped["tch_sum_diff"] / grouped["actual_tch_sum"]
    grouped["area_weighted_tch_sum_diff"] = (
        grouped["pred_area_weighted_tch_sum"] - grouped["actual_area_weighted_tch_sum"]
    )
    grouped["area_weighted_tch_sum_pct_diff"] = (
        grouped["area_weighted_tch_sum_diff"] / grouped["actual_area_weighted_tch_sum"]
    )
    grouped["tch_mean_error"] = grouped["pred_tch_mean"] - grouped["actual_tch_mean"]
    grouped["tch_mean_pct_error"] = grouped["tch_mean_error"] / grouped["actual_tch_mean"]
    grouped.insert(0, "split", split)
    return grouped.reset_index()
