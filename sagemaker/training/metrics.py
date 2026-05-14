import numpy as np
import pandas as pd
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score


def regression_metrics(y_true, y_pred):
    return {
        "rmse": float(np.sqrt(mean_squared_error(y_true, y_pred))),
        "mae": float(mean_absolute_error(y_true, y_pred)),
        "r2": float(r2_score(y_true, y_pred)),
        "bias": float(np.mean(np.asarray(y_pred) - np.asarray(y_true))),
    }


def zafra_metrics(metadata: pd.DataFrame, y_true: pd.Series, y_pred, split: str) -> pd.DataFrame:
    df = metadata.set_index("cod_cg_zafra").loc[y_true.index].copy()
    df["actual_tch"] = y_true
    df["pred_tch"] = y_pred
    df["actual_tc_from_tch"] = df["actual_tch"] * df["area"]
    df["pred_tc_from_tch"] = df["pred_tch"] * df["area"]

    grouped = df.groupby("zafra_norm", dropna=False).agg(
        rows=("actual_tch", "size"),
        actual_tch_mean=("actual_tch", "mean"),
        pred_tch_mean=("pred_tch", "mean"),
        actual_tc=("actual_tc_from_tch", "sum"),
        pred_tc=("pred_tc_from_tch", "sum"),
    )
    grouped["tc_error"] = grouped["pred_tc"] - grouped["actual_tc"]
    grouped["tc_pct_error"] = grouped["tc_error"] / grouped["actual_tc"]
    grouped.insert(0, "split", split)
    return grouped.reset_index()
