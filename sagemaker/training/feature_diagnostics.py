import os

import numpy as np
import pandas as pd


def _numeric_frame(X: pd.DataFrame) -> pd.DataFrame:
    return X.select_dtypes(include="number")


def save_missing_rate(X: pd.DataFrame, output_dir: str) -> pd.DataFrame:
    rows = []
    for col in X.columns:
        missing_rate = float(X[col].isna().mean())
        rows.append(
            {
                "feature": col,
                "missing_rate": missing_rate,
                "non_null_count": int(X[col].notna().sum()),
                "dtype": str(X[col].dtype),
            }
        )
    df = pd.DataFrame(rows).sort_values(["missing_rate", "feature"], ascending=[False, True])
    df.to_csv(os.path.join(output_dir, "feature_missing_rate.csv"), index=False)
    return df


def save_split_stability(
    X: pd.DataFrame,
    train_idx,
    validation_idx,
    test_idx,
    output_dir: str,
) -> pd.DataFrame:
    numeric = _numeric_frame(X)
    splits = {
        "train": train_idx.intersection(numeric.index),
        "validation": validation_idx.intersection(numeric.index),
        "test": test_idx.intersection(numeric.index),
    }

    rows = []
    for col in numeric.columns:
        train_values = numeric.loc[splits["train"], col]
        train_mean = train_values.mean()
        train_std = train_values.std()

        row = {
            "feature": col,
            "train_mean": train_mean,
            "train_std": train_std,
            "validation_mean": numeric.loc[splits["validation"], col].mean(),
            "validation_std": numeric.loc[splits["validation"], col].std(),
            "test_mean": numeric.loc[splits["test"], col].mean(),
            "test_std": numeric.loc[splits["test"], col].std(),
        }
        denom = train_std if pd.notna(train_std) and train_std > 0 else np.nan
        row["validation_mean_shift_std"] = (row["validation_mean"] - train_mean) / denom
        row["test_mean_shift_std"] = (row["test_mean"] - train_mean) / denom
        shifts = np.abs([row["validation_mean_shift_std"], row["test_mean_shift_std"]])
        row["max_abs_mean_shift_std"] = np.nan if np.isnan(shifts).all() else np.nanmax(shifts)
        rows.append(row)

    df = pd.DataFrame(rows).sort_values("max_abs_mean_shift_std", ascending=False, na_position="last")
    df.to_csv(os.path.join(output_dir, "feature_stability_by_split.csv"), index=False)
    return df


def save_correlation_clusters(
    X: pd.DataFrame,
    output_dir: str,
    threshold: float = 0.98,
    max_features: int = 1200,
) -> pd.DataFrame:
    numeric = _numeric_frame(X)
    variance = numeric.var(skipna=True).sort_values(ascending=False)
    keep_cols = variance[variance > 0].head(max_features).index.tolist()
    if len(keep_cols) < 2:
        df = pd.DataFrame(columns=["feature_a", "feature_b", "abs_corr"])
        df.to_csv(os.path.join(output_dir, "feature_correlation_pairs.csv"), index=False)
        return df

    corr = numeric[keep_cols].corr().abs()
    mask = np.triu(np.ones(corr.shape, dtype=bool), k=1)
    pairs = corr.where(mask).stack().reset_index()
    pairs.columns = ["feature_a", "feature_b", "abs_corr"]
    pairs = pairs[pairs["abs_corr"] >= threshold].sort_values("abs_corr", ascending=False)
    pairs.to_csv(os.path.join(output_dir, "feature_correlation_pairs.csv"), index=False)
    return pairs


def save_pruning_recommendations(
    missing_rate: pd.DataFrame,
    stability: pd.DataFrame,
    correlations: pd.DataFrame,
    output_dir: str,
) -> pd.DataFrame:
    high_missing = set(missing_rate.loc[missing_rate["missing_rate"] >= 0.95, "feature"])
    unstable = set(stability.loc[stability["max_abs_mean_shift_std"] >= 3.0, "feature"])
    correlated = set(correlations["feature_b"]) if not correlations.empty else set()

    rows = []
    for feature in sorted(high_missing | unstable | correlated):
        reasons = []
        if feature in high_missing:
            reasons.append("missing_rate>=0.95")
        if feature in unstable:
            reasons.append("split_mean_shift>=3_train_std")
        if feature in correlated:
            reasons.append("correlated_redundant_candidate")
        rows.append({"feature": feature, "reasons": ";".join(reasons)})

    df = pd.DataFrame(rows)
    df.to_csv(os.path.join(output_dir, "feature_pruning_recommendations.csv"), index=False)
    return df


def save_feature_diagnostics(
    X: pd.DataFrame,
    train_idx,
    validation_idx,
    test_idx,
    output_dir: str,
) -> None:
    missing_rate = save_missing_rate(X, output_dir)
    stability = save_split_stability(X, train_idx, validation_idx, test_idx, output_dir)
    correlations = save_correlation_clusters(X, output_dir)
    save_pruning_recommendations(missing_rate, stability, correlations, output_dir)
