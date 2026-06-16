import os

import numpy as np
import pandas as pd

try:
    from sklearn.feature_selection import mutual_info_regression
except Exception:
    mutual_info_regression = None


UNIVARIATE_SAMPLE_ROWS = 20000
INTERACTION_TOP_FEATURES = 30
NEAR_ZERO_VARIANCE_THRESHOLD = 1e-8


def _numeric_frame(X: pd.DataFrame) -> pd.DataFrame:
    return X.select_dtypes(include="number")


def _deduplicate_columns(X: pd.DataFrame) -> pd.DataFrame:
    seen = {}
    columns = []
    for col in X.columns:
        count = seen.get(col, 0)
        columns.append(col if count == 0 else f"{col}_{count}")
        seen[col] = count + 1

    if list(X.columns) == columns:
        return X
    deduplicated = X.copy()
    deduplicated.columns = columns
    return deduplicated


def _split_indexes(frame: pd.DataFrame, train_idx, evaluation_idx) -> dict[str, pd.Index]:
    return {
        "train": pd.Index(train_idx).intersection(frame.index),
        "evaluation": pd.Index(evaluation_idx).intersection(frame.index),
    }


def _safe_abs(value) -> float:
    if pd.isna(value):
        return 0.0
    return float(abs(value))


def _minmax_score(series: pd.Series, higher_is_better: bool = True) -> pd.Series:
    values = pd.to_numeric(series, errors="coerce")
    min_value = values.min(skipna=True)
    max_value = values.max(skipna=True)
    if pd.isna(min_value) or pd.isna(max_value) or min_value == max_value:
        return pd.Series(0.0, index=series.index)

    score = (values - min_value) / (max_value - min_value)
    if not higher_is_better:
        score = 1.0 - score
    return score.fillna(0.0)


def _pearson_corr(left: pd.Series, right: pd.Series) -> float:
    return left.corr(right, method="pearson")


def _spearman_corr(left: pd.Series, right: pd.Series) -> float:
    return left.rank().corr(right.rank(), method="pearson")


def save_missing_rate(
    X: pd.DataFrame,
    train_idx,
    evaluation_idx,
    output_dir: str,
) -> pd.DataFrame:
    splits = _split_indexes(X, train_idx, evaluation_idx)
    rows = []
    for col in X.columns:
        split_stats = {}
        for split, split_idx in splits.items():
            values = X.loc[split_idx, col]
            split_stats[f"{split}_missing_rate"] = float(values.isna().mean()) if len(values) else np.nan
            split_stats[f"{split}_non_null_count"] = int(values.notna().sum())

        overall_missing_rate = float(X[col].isna().mean())
        rows.append(
            {
                "feature": col,
                "missing_rate": split_stats["train_missing_rate"],
                "non_null_count": split_stats["train_non_null_count"],
                "overall_missing_rate": overall_missing_rate,
                "overall_non_null_count": int(X[col].notna().sum()),
                "dtype": str(X[col].dtype),
                **split_stats,
            }
        )
    df = pd.DataFrame(rows).sort_values(["train_missing_rate", "feature"], ascending=[False, True])
    df.to_csv(os.path.join(output_dir, "feature_missing_rate.csv"), index=False)
    return df


def save_split_stability(
    X: pd.DataFrame,
    train_idx,
    evaluation_idx,
    output_dir: str,
) -> pd.DataFrame:
    numeric = _numeric_frame(X)
    splits = {
        "train": train_idx.intersection(numeric.index),
        "evaluation": evaluation_idx.intersection(numeric.index),
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
            "evaluation_mean": numeric.loc[splits["evaluation"], col].mean(),
            "evaluation_std": numeric.loc[splits["evaluation"], col].std(),
        }
        denom = train_std if pd.notna(train_std) and train_std > 0 else np.nan
        row["evaluation_mean_shift_std"] = (row["evaluation_mean"] - train_mean) / denom
        row["max_abs_mean_shift_std"] = abs(row["evaluation_mean_shift_std"])
        rows.append(row)

    df = pd.DataFrame(rows).sort_values("max_abs_mean_shift_std", ascending=False, na_position="last")
    df.to_csv(os.path.join(output_dir, "feature_stability_by_split.csv"), index=False)
    return df


def save_feature_variance(
    X: pd.DataFrame,
    train_idx,
    evaluation_idx,
    output_dir: str,
    threshold: float = NEAR_ZERO_VARIANCE_THRESHOLD,
) -> pd.DataFrame:
    numeric = _numeric_frame(X)
    splits = _split_indexes(numeric, train_idx, evaluation_idx)
    rows = []
    for col in numeric.columns:
        split_stats = {}
        for split, split_idx in splits.items():
            values = pd.to_numeric(numeric.loc[split_idx, col], errors="coerce")
            split_stats[f"{split}_variance"] = values.var(skipna=True)
            split_stats[f"{split}_std"] = values.std(skipna=True)
            split_stats[f"{split}_unique_count"] = int(values.nunique(dropna=True))

        train_variance = split_stats["train_variance"]
        rows.append(
            {
                "feature": col,
                "variance": train_variance,
                "std": split_stats["train_std"],
                "unique_count": split_stats["train_unique_count"],
                "near_zero_variance": bool(pd.notna(train_variance) and train_variance <= threshold),
                **split_stats,
            }
        )

    df = pd.DataFrame(rows).sort_values(["near_zero_variance", "train_variance", "feature"], ascending=[False, True, True])
    df.to_csv(os.path.join(output_dir, "feature_variance.csv"), index=False)
    return df


def save_univariate_target_association(
    X: pd.DataFrame,
    y: pd.Series,
    train_idx,
    output_dir: str,
    sample_rows: int = UNIVARIATE_SAMPLE_ROWS,
) -> pd.DataFrame:
    train_index = pd.Index(train_idx).intersection(X.index)
    numeric = _numeric_frame(X.loc[train_index])
    aligned_y = pd.to_numeric(y.reindex(numeric.index), errors="coerce")

    rows = []
    for col in numeric.columns:
        feature = pd.to_numeric(numeric[col], errors="coerce")
        valid = feature.notna() & aligned_y.notna()
        valid_count = int(valid.sum())
        unique_count = int(feature[valid].nunique(dropna=True)) if valid_count else 0

        pearson = np.nan
        spearman = np.nan
        if valid_count >= 3 and unique_count > 1:
            pearson = _pearson_corr(feature[valid], aligned_y[valid])
            spearman = _spearman_corr(feature[valid], aligned_y[valid])

        rows.append(
            {
                "feature": col,
                "pearson": pearson,
                "pearson_abs": _safe_abs(pearson),
                "spearman": spearman,
                "spearman_abs": _safe_abs(spearman),
                "valid_count": valid_count,
                "unique_count": unique_count,
                "reference_split": "train",
            }
        )

    df = pd.DataFrame(rows)
    if df.empty:
        df.to_csv(os.path.join(output_dir, "feature_univariate_target_association.csv"), index=False)
        return df

    mi_cols = df.loc[df["valid_count"] >= 3, "feature"].tolist()
    mi_values = {}
    if mi_cols and mutual_info_regression is not None:
        sample_index = aligned_y.dropna().index.intersection(numeric.index)
        if len(sample_index) > sample_rows:
            sample_index = pd.Index(sample_index).to_series().sample(sample_rows, random_state=42).index

        mi_frame = numeric.loc[sample_index, mi_cols].copy()
        mi_target = aligned_y.loc[sample_index]
        non_constant_cols = [col for col in mi_cols if mi_frame[col].nunique(dropna=True) > 1]
        if non_constant_cols:
            mi_frame = mi_frame[non_constant_cols].replace([np.inf, -np.inf], np.nan)
            mi_frame = mi_frame.fillna(mi_frame.median(numeric_only=True)).fillna(0.0)
            mi_scores = mutual_info_regression(mi_frame, mi_target, random_state=42)
            mi_values = dict(zip(non_constant_cols, mi_scores))

    df["mutual_info"] = df["feature"].map(mi_values).fillna(0.0)
    df["target_association_score"] = df[["spearman_abs", "pearson_abs", "mutual_info"]].max(axis=1)
    df = df.sort_values(
        ["target_association_score", "spearman_abs", "mutual_info", "feature"],
        ascending=[False, False, False, True],
    )
    df.to_csv(os.path.join(output_dir, "feature_univariate_target_association.csv"), index=False)
    return df


def save_correlation_pairs(
    X: pd.DataFrame,
    train_idx,
    output_dir: str,
    threshold: float = 0.98,
    max_features: int = 1200,
    method: str = "pearson",
    filename: str = "feature_correlation_pairs.csv",
) -> pd.DataFrame:
    train_index = pd.Index(train_idx).intersection(X.index)
    numeric = _numeric_frame(X.loc[train_index])
    variance = numeric.var(skipna=True).sort_values(ascending=False)
    keep_cols = variance[variance > 0].head(max_features).index.tolist()
    if len(keep_cols) < 2:
        df = pd.DataFrame(columns=["feature_a", "feature_b", "abs_corr"])
        df.to_csv(os.path.join(output_dir, filename), index=False)
        return df

    corr = numeric[keep_cols].corr(method=method).abs()
    mask = np.triu(np.ones(corr.shape, dtype=bool), k=1)
    pairs = corr.where(mask).stack().reset_index()
    pairs.columns = ["feature_a", "feature_b", "abs_corr"]
    pairs = pairs[pairs["abs_corr"] >= threshold].sort_values("abs_corr", ascending=False)
    pairs.to_csv(os.path.join(output_dir, filename), index=False)
    return pairs


def save_correlation_clusters(
    correlations: pd.DataFrame,
    missing_rate: pd.DataFrame,
    stability: pd.DataFrame,
    univariate: pd.DataFrame,
    output_dir: str,
) -> pd.DataFrame:
    if correlations.empty:
        df = pd.DataFrame(
            columns=[
                "cluster_id",
                "feature",
                "recommended_keep_feature",
                "is_recommended_keep",
                "drop_recommended",
                "cluster_size",
                "target_association_score",
                "missing_rate",
                "max_abs_mean_shift_std",
                "selection_score",
                "max_abs_corr_to_cluster",
            ]
        )
        df.to_csv(os.path.join(output_dir, "feature_correlation_clusters.csv"), index=False)
        return df

    features = sorted(set(correlations["feature_a"]) | set(correlations["feature_b"]))
    parent = {feature: feature for feature in features}

    def find(feature):
        while parent[feature] != feature:
            parent[feature] = parent[parent[feature]]
            feature = parent[feature]
        return feature

    def union(a, b):
        root_a = find(a)
        root_b = find(b)
        if root_a != root_b:
            parent[root_b] = root_a

    for row in correlations.itertuples(index=False):
        union(row.feature_a, row.feature_b)

    clusters = {}
    for feature in features:
        clusters.setdefault(find(feature), []).append(feature)

    evidence = pd.DataFrame({"feature": features})
    evidence = evidence.merge(
        univariate[["feature", "target_association_score", "spearman_abs", "mutual_info"]],
        on="feature",
        how="left",
    )
    evidence = evidence.merge(missing_rate[["feature", "missing_rate", "non_null_count"]], on="feature", how="left")
    evidence = evidence.merge(stability[["feature", "max_abs_mean_shift_std"]], on="feature", how="left")
    evidence["association_norm"] = _minmax_score(evidence["target_association_score"], higher_is_better=True)
    evidence["missing_norm"] = _minmax_score(evidence["missing_rate"], higher_is_better=False)
    evidence["stability_norm"] = _minmax_score(evidence["max_abs_mean_shift_std"], higher_is_better=False)
    evidence["coverage_norm"] = _minmax_score(evidence["non_null_count"], higher_is_better=True)
    evidence["selection_score"] = (
        0.55 * evidence["association_norm"]
        + 0.20 * evidence["missing_norm"]
        + 0.15 * evidence["stability_norm"]
        + 0.10 * evidence["coverage_norm"]
    )

    rows = []
    for cluster_id, members in enumerate(sorted(clusters.values(), key=lambda values: values[0]), start=1):
        member_evidence = evidence[evidence["feature"].isin(members)].sort_values(
            ["selection_score", "target_association_score", "missing_rate", "max_abs_mean_shift_std", "feature"],
            ascending=[False, False, True, True, True],
        )
        keep_feature = member_evidence.iloc[0]["feature"]

        cluster_pairs = correlations[
            correlations["feature_a"].isin(members) & correlations["feature_b"].isin(members)
        ]
        max_corr_by_feature = {feature: np.nan for feature in members}
        for pair in cluster_pairs.itertuples(index=False):
            max_corr_by_feature[pair.feature_a] = np.nanmax([max_corr_by_feature[pair.feature_a], pair.abs_corr])
            max_corr_by_feature[pair.feature_b] = np.nanmax([max_corr_by_feature[pair.feature_b], pair.abs_corr])

        for _, row in member_evidence.sort_values("feature").iterrows():
            is_keep = row["feature"] == keep_feature
            rows.append(
                {
                    "cluster_id": cluster_id,
                    "feature": row["feature"],
                    "recommended_keep_feature": keep_feature,
                    "is_recommended_keep": bool(is_keep),
                    "drop_recommended": bool(not is_keep),
                    "cluster_size": int(len(members)),
                    "target_association_score": row["target_association_score"],
                    "spearman_abs": row["spearman_abs"],
                    "mutual_info": row["mutual_info"],
                    "missing_rate": row["missing_rate"],
                    "non_null_count": row["non_null_count"],
                    "max_abs_mean_shift_std": row["max_abs_mean_shift_std"],
                    "selection_score": row["selection_score"],
                    "max_abs_corr_to_cluster": max_corr_by_feature[row["feature"]],
                }
            )

    df = pd.DataFrame(rows).sort_values(["cluster_id", "drop_recommended", "selection_score"], ascending=[True, True, False])
    df.to_csv(os.path.join(output_dir, "feature_correlation_clusters.csv"), index=False)
    return df


def save_interaction_candidates(
    X: pd.DataFrame,
    y: pd.Series,
    univariate: pd.DataFrame,
    train_idx,
    output_dir: str,
    top_features: int = INTERACTION_TOP_FEATURES,
    sample_rows: int = UNIVARIATE_SAMPLE_ROWS,
) -> pd.DataFrame:
    train_index = pd.Index(train_idx).intersection(X.index)
    numeric = _numeric_frame(X.loc[train_index])
    aligned_y = pd.to_numeric(y.reindex(numeric.index), errors="coerce")
    candidate_cols = [
        col
        for col in univariate.head(top_features)["feature"].tolist()
        if col in numeric.columns and numeric[col].nunique(dropna=True) > 1
    ]

    if len(candidate_cols) < 2:
        df = pd.DataFrame(
            columns=[
                "feature_a",
                "feature_b",
                "interaction_spearman_abs",
                "best_individual_spearman_abs",
                "interaction_gain",
            ]
        )
        df.to_csv(os.path.join(output_dir, "feature_interaction_candidates.csv"), index=False)
        return df

    sample_index = aligned_y.dropna().index.intersection(numeric.index)
    if len(sample_index) > sample_rows:
        sample_index = pd.Index(sample_index).to_series().sample(sample_rows, random_state=42).index

    sample_X = numeric.loc[sample_index, candidate_cols].replace([np.inf, -np.inf], np.nan)
    sample_y = aligned_y.loc[sample_index]
    sample_X = sample_X.fillna(sample_X.median(numeric_only=True)).fillna(0.0)
    standardized = (sample_X - sample_X.mean()) / sample_X.std(ddof=0).replace(0, np.nan)

    individual = univariate.set_index("feature")["spearman_abs"].to_dict()
    rows = []
    for pos, feature_a in enumerate(candidate_cols):
        for feature_b in candidate_cols[pos + 1 :]:
            product = standardized[feature_a] * standardized[feature_b]
            valid = product.notna() & sample_y.notna()
            if valid.sum() < 3:
                continue
            interaction_spearman = _spearman_corr(product[valid], sample_y[valid])
            interaction_abs = _safe_abs(interaction_spearman)
            best_individual = max(_safe_abs(individual.get(feature_a)), _safe_abs(individual.get(feature_b)))
            rows.append(
                {
                    "feature_a": feature_a,
                    "feature_b": feature_b,
                    "interaction_spearman": interaction_spearman,
                    "interaction_spearman_abs": interaction_abs,
                    "best_individual_spearman_abs": best_individual,
                    "interaction_gain": interaction_abs - best_individual,
                }
            )

    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.sort_values(
            ["interaction_gain", "interaction_spearman_abs", "feature_a", "feature_b"],
            ascending=[False, False, True, True],
        )
    df.to_csv(os.path.join(output_dir, "feature_interaction_candidates.csv"), index=False)
    return df


def save_pruning_recommendations(
    missing_rate: pd.DataFrame,
    stability: pd.DataFrame,
    variance: pd.DataFrame,
    correlation_clusters: pd.DataFrame,
    univariate: pd.DataFrame,
    interactions: pd.DataFrame,
    output_dir: str,
) -> pd.DataFrame:
    high_missing = set(missing_rate.loc[missing_rate["missing_rate"] >= 0.95, "feature"])
    unstable = set(stability.loc[stability["max_abs_mean_shift_std"] >= 3.0, "feature"])
    near_zero_variance = set(variance.loc[variance["near_zero_variance"], "feature"])
    correlated = (
        set(correlation_clusters.loc[correlation_clusters["drop_recommended"], "feature"])
        if not correlation_clusters.empty
        else set()
    )
    low_target_signal = set(
        univariate.loc[
            (univariate["target_association_score"] <= 0.01) & (univariate["valid_count"] >= 100),
            "feature",
        ]
    )
    interaction_candidates = set()
    if not interactions.empty:
        strong_interactions = interactions.loc[interactions["interaction_gain"] > 0.02].head(100)
        interaction_candidates = set(strong_interactions["feature_a"]) | set(strong_interactions["feature_b"])

    missing_cols = [
        col
        for col in [
            "feature",
            "missing_rate",
            "non_null_count",
            "overall_missing_rate",
            "overall_non_null_count",
            "train_missing_rate",
            "evaluation_missing_rate",
            "train_non_null_count",
            "evaluation_non_null_count",
        ]
        if col in missing_rate.columns
    ]
    variance_cols = [
        col
        for col in [
            "feature",
            "variance",
            "std",
            "unique_count",
            "train_variance",
            "evaluation_variance",
            "train_unique_count",
            "evaluation_unique_count",
            "near_zero_variance",
        ]
        if col in variance.columns
    ]

    evidence = missing_rate[missing_cols].merge(
        stability[["feature", "max_abs_mean_shift_std"]],
        on="feature",
        how="left",
    )
    evidence = evidence.merge(variance[variance_cols], on="feature", how="left")
    evidence = evidence.merge(
        univariate[["feature", "target_association_score", "spearman_abs", "mutual_info"]],
        on="feature",
        how="left",
    )
    cluster_lookup = correlation_clusters[
        ["feature", "cluster_id", "recommended_keep_feature", "selection_score"]
    ] if not correlation_clusters.empty else pd.DataFrame(
        columns=["feature", "cluster_id", "recommended_keep_feature", "selection_score"]
    )
    evidence = evidence.merge(cluster_lookup, on="feature", how="left")
    evidence = evidence.set_index("feature")

    rows = []
    for feature in sorted(high_missing | unstable | near_zero_variance | correlated | low_target_signal | interaction_candidates):
        reasons = []
        recommendation = "review"
        if feature in high_missing:
            reasons.append("missing_rate>=0.95")
        if feature in unstable:
            reasons.append("split_mean_shift>=3_train_std")
        if feature in near_zero_variance:
            reasons.append("near_zero_variance")
        if feature in correlated:
            reasons.append("correlated_cluster_redundant_candidate")
        if feature in low_target_signal:
            reasons.append("low_univariate_target_signal")
        if feature in interaction_candidates:
            reasons.append("interaction_candidate")

        if feature in high_missing:
            recommendation = "drop_high_missing"
        elif feature in near_zero_variance:
            recommendation = "drop_near_zero_variance"
        elif feature in correlated:
            recommendation = "drop_correlated_redundant"
        elif feature in unstable:
            recommendation = "review_unstable"
        elif feature in low_target_signal:
            recommendation = "review_low_target_signal"
        elif feature in interaction_candidates:
            recommendation = "review_interaction_candidate"

        row = {
            "feature": feature,
            "recommendation": recommendation,
            "reasons": ";".join(reasons),
        }
        if feature in evidence.index:
            row.update(evidence.loc[feature].to_dict())
        rows.append(row)

    columns = [
        "feature",
        "recommendation",
        "reasons",
        "missing_rate",
        "non_null_count",
        "overall_missing_rate",
        "overall_non_null_count",
        "train_missing_rate",
        "evaluation_missing_rate",
        "train_non_null_count",
        "evaluation_non_null_count",
        "variance",
        "std",
        "unique_count",
        "train_variance",
        "evaluation_variance",
        "train_unique_count",
        "evaluation_unique_count",
        "near_zero_variance",
        "max_abs_mean_shift_std",
        "target_association_score",
        "spearman_abs",
        "mutual_info",
        "cluster_id",
        "recommended_keep_feature",
        "selection_score",
    ]
    df = pd.DataFrame(rows)
    if df.empty:
        df = pd.DataFrame(columns=columns)
    else:
        df = df.sort_values(["recommendation", "feature"])
    df.to_csv(os.path.join(output_dir, "feature_pruning_recommendations.csv"), index=False)
    return df


def save_feature_diagnostics(
    X: pd.DataFrame,
    y: pd.Series,
    train_idx,
    evaluation_idx,
    output_dir: str,
) -> None:
    X = _deduplicate_columns(X)
    missing_rate = save_missing_rate(X, train_idx, evaluation_idx, output_dir)
    stability = save_split_stability(X, train_idx, evaluation_idx, output_dir)
    variance = save_feature_variance(X, train_idx, evaluation_idx, output_dir)
    univariate = save_univariate_target_association(X, y, train_idx, output_dir)
    correlations = save_correlation_pairs(X, train_idx, output_dir)
    save_correlation_pairs(
        X,
        train_idx,
        output_dir,
        method="spearman",
        filename="feature_spearman_correlation_pairs.csv",
    )
    correlation_clusters = save_correlation_clusters(correlations, missing_rate, stability, univariate, output_dir)
    interactions = save_interaction_candidates(X, y, univariate, train_idx, output_dir)
    save_pruning_recommendations(missing_rate, stability, variance, correlation_clusters, univariate, interactions, output_dir)
