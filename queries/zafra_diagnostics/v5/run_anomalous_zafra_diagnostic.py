"""Diagnose anomalous zafra behavior for the v5 as-of-180 model.

This script compares one zafra against the historical training zafras, test,
and external partial zafra using the uploaded feature table plus model artifacts.
It does not touch the database.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_JOB = "tch-tch-features-v5-asof-180d-core-catboost-20260528-143010"
DEFAULT_ARTIFACT_DIR = ROOT / ".tmp" / DEFAULT_JOB
DEFAULT_DATASET = ROOT / ".tmp" / "tch_features_v5_asof_180d_core.parquet"
DEFAULT_OUTPUT_DIR = Path(__file__).resolve().parent / "artifacts" / DEFAULT_JOB

CATEGORY_FEATURES = [
    "prod_ingenio",
    "prod_codigo_zae",
    "prod_no_corte",
    "prod_variedad",
    "prod_grupo_de_suelo",
    "prod_grupo_de_humedad",
    "prod_familia_de_suelo",
]

QUALITY_FEATURES = [
    "optical_obs_count_0_180",
    "optical_first_obs_age_0_180",
    "optical_last_obs_age_0_180",
    "optical_max_gap_days_0_180",
    "climate_pentad_count_0_180",
    "climate_max_gap_days_0_180",
    "cycle_age_max",
]


def read_csv(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(path)
    return pd.read_csv(path)


def q(series: pd.Series, pct: float) -> float:
    clean = pd.to_numeric(series, errors="coerce").dropna()
    if clean.empty:
        return np.nan
    return float(clean.quantile(pct))


def summarize_prediction_group(df: pd.DataFrame, group_cols: list[str]) -> pd.DataFrame:
    rows = []
    for keys, group in df.groupby(group_cols, dropna=False):
        if not isinstance(keys, tuple):
            keys = (keys,)
        actual_sum = group["actual_tch"].sum()
        pred_sum = group["pred_tch"].sum()
        row = dict(zip(group_cols, keys))
        row.update(
            {
                "rows": len(group),
                "actual_tch_sum": actual_sum,
                "pred_tch_sum": pred_sum,
                "tch_sum_diff": pred_sum - actual_sum,
                "tch_sum_pct_diff": (pred_sum - actual_sum) / actual_sum if actual_sum else np.nan,
                "actual_tch_mean": group["actual_tch"].mean(),
                "pred_tch_mean": group["pred_tch"].mean(),
                "tch_bias": group["tch_error"].mean(),
                "tch_mae": group["tch_abs_error"].mean(),
                "tch_rmse": float(np.sqrt(np.mean(np.square(group["tch_error"])))),
            }
        )
        rows.append(row)
    return pd.DataFrame(rows)


def target_distribution(pred: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for zafra, group in pred.groupby("zafra_norm", dropna=False):
        rows.append(
            {
                "zafra_norm": zafra,
                "split": ",".join(sorted(group["split"].dropna().astype(str).unique())),
                "rows": len(group),
                "actual_tch_sum": group["actual_tch"].sum(),
                "actual_tch_mean": group["actual_tch"].mean(),
                "actual_tch_median": group["actual_tch"].median(),
                "actual_tch_std": group["actual_tch"].std(),
                "actual_tch_p10": q(group["actual_tch"], 0.10),
                "actual_tch_p25": q(group["actual_tch"], 0.25),
                "actual_tch_p75": q(group["actual_tch"], 0.75),
                "actual_tch_p90": q(group["actual_tch"], 0.90),
                "area_sum": pd.to_numeric(group.get("area"), errors="coerce").sum(),
                "area_mean": pd.to_numeric(group.get("area"), errors="coerce").mean(),
            }
        )
    return pd.DataFrame(rows).sort_values("zafra_norm")


def source_for_feature(feature: str) -> str:
    if feature.startswith("optical_"):
        return "optical"
    if feature.startswith("climate_"):
        return "climate"
    if feature.startswith("enso_"):
        return "enso"
    if feature.startswith("prod_"):
        return "productividad"
    if feature.startswith("cycle_") or feature.startswith("cutoff_"):
        return "cycle"
    return "other"


def numeric_feature_drift(
    data: pd.DataFrame,
    top_features: list[str],
    anomaly_zafra: str,
    reference_zafras: list[str],
) -> pd.DataFrame:
    rows = []
    numeric_features = [f for f in top_features if f in data.columns and pd.api.types.is_numeric_dtype(data[f])]
    reference = data[data["zafra_norm"].isin(reference_zafras)]
    anomaly = data[data["zafra_norm"] == anomaly_zafra]

    for feature in numeric_features:
        ref = pd.to_numeric(reference[feature], errors="coerce")
        anom = pd.to_numeric(anomaly[feature], errors="coerce")
        ref_std = ref.std()
        ref_mean = ref.mean()
        anom_mean = anom.mean()
        zafra_means = data.groupby("zafra_norm")[feature].mean(numeric_only=True)
        rows.append(
            {
                "feature": feature,
                "source": source_for_feature(feature),
                "anomaly_mean": anom_mean,
                "reference_mean": ref_mean,
                "test_2024_2025_mean": data.loc[data["zafra_norm"] == "2024_2025", feature].mean(),
                "external_2025_2026_mean": data.loc[data["zafra_norm"] == "2025_2026", feature].mean(),
                "anomaly_minus_reference": anom_mean - ref_mean,
                "std_diff_vs_reference": (anom_mean - ref_mean) / ref_std if ref_std and not np.isnan(ref_std) else np.nan,
                "anomaly_median": anom.median(),
                "reference_median": ref.median(),
                "anomaly_missing_rate": anom.isna().mean(),
                "reference_missing_rate": ref.isna().mean(),
                "anomaly_zafra_mean_rank": int(zafra_means.rank(method="min").loc[anomaly_zafra])
                if anomaly_zafra in zafra_means.index
                else np.nan,
                "zafra_count": zafra_means.notna().sum(),
            }
        )
    return pd.DataFrame(rows).sort_values("std_diff_vs_reference", key=lambda s: s.abs(), ascending=False)


def category_error(pred: pd.DataFrame, anomaly_zafra: str) -> pd.DataFrame:
    frames = []
    for feature in CATEGORY_FEATURES:
        if feature not in pred.columns:
            continue
        cols = ["zafra_norm", "split", feature]
        summary = summarize_prediction_group(pred, cols)
        summary.insert(0, "feature", feature)
        summary = summary.rename(columns={feature: "category_value"})
        summary["is_anomaly_zafra"] = summary["zafra_norm"].eq(anomaly_zafra)
        frames.append(summary)
    if not frames:
        return pd.DataFrame()
    out = pd.concat(frames, ignore_index=True)
    return out.sort_values(["is_anomaly_zafra", "feature", "rows"], ascending=[False, True, False])


def error_by_feature_bins(data: pd.DataFrame, anomaly_zafra: str, top_features: list[str]) -> pd.DataFrame:
    frames = []
    anomaly = data[data["zafra_norm"] == anomaly_zafra].copy()
    for feature in top_features:
        if feature not in anomaly.columns or not pd.api.types.is_numeric_dtype(anomaly[feature]):
            continue
        valid = anomaly.dropna(subset=[feature]).copy()
        if valid[feature].nunique() < 4:
            continue
        valid["feature_bin"] = pd.qcut(valid[feature], q=5, duplicates="drop")
        summary = summarize_prediction_group(valid, ["feature_bin"])
        summary.insert(0, "feature", feature)
        summary["feature_bin"] = summary["feature_bin"].astype(str)
        frames.append(summary)
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()


def data_quality_by_zafra(data: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for zafra, group in data.groupby("zafra_norm", dropna=False):
        row = {"zafra_norm": zafra, "rows": len(group)}
        for feature in QUALITY_FEATURES:
            if feature not in group.columns:
                continue
            values = pd.to_numeric(group[feature], errors="coerce")
            row[f"{feature}_mean"] = values.mean()
            row[f"{feature}_median"] = values.median()
            row[f"{feature}_p10"] = q(values, 0.10)
            row[f"{feature}_p90"] = q(values, 0.90)
            row[f"{feature}_missing_rate"] = values.isna().mean()
        rows.append(row)
    return pd.DataFrame(rows).sort_values("zafra_norm")


def shap_sample_coverage(shap_path: Path, pred: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    if not shap_path.exists():
        return pd.DataFrame(), pd.DataFrame()
    shap = pd.read_parquet(shap_path)
    shap.index = shap.index.astype(str)
    pred_indexed = pred.set_index("cod_cg_zafra")
    common = shap.index.intersection(pred_indexed.index)
    coverage = pred_indexed.loc[common, ["split", "zafra_norm"]].reset_index()
    coverage_summary = coverage.groupby(["split", "zafra_norm"]).size().reset_index(name="shap_rows")
    shap_abs = shap.loc[common].abs().mean().sort_values(ascending=False).reset_index()
    shap_abs.columns = ["feature", "mean_abs_shap_in_saved_sample"]
    return coverage_summary, shap_abs


def md_table(df: pd.DataFrame, columns: list[str], rows: int = 8) -> str:
    if df.empty:
        return "_Sin datos._"
    view = df.loc[:, [c for c in columns if c in df.columns]].head(rows).copy()
    for col in view.columns:
        if pd.api.types.is_float_dtype(view[col]):
            view[col] = view[col].map(lambda x: "" if pd.isna(x) else f"{x:,.4f}")
    header = "| " + " | ".join(view.columns) + " |"
    sep = "| " + " | ".join(["---"] * len(view.columns)) + " |"
    body = ["| " + " | ".join(str(v) for v in row) + " |" for row in view.to_numpy()]
    return "\n".join([header, sep, *body])


def write_report(
    output_dir: Path,
    anomaly_zafra: str,
    target_df: pd.DataFrame,
    aggregate_df: pd.DataFrame,
    drift_df: pd.DataFrame,
    quality_df: pd.DataFrame,
    category_df: pd.DataFrame,
    shap_coverage: pd.DataFrame,
) -> None:
    anomaly_agg = aggregate_df[aggregate_df["zafra_norm"].eq(anomaly_zafra)]
    worst_drift = drift_df.head(10)
    anomaly_categories = category_df[category_df["is_anomaly_zafra"]].copy()
    anomaly_categories = anomaly_categories.sort_values("tch_sum_diff", key=lambda s: s.abs(), ascending=False)

    lines = [
        f"# Diagnostico zafra anomala {anomaly_zafra} - v5 as-of-180",
        "",
        "## Lectura corta",
    ]
    if not anomaly_agg.empty:
        row = anomaly_agg.iloc[0]
        lines.append(
            f"- La zafra {anomaly_zafra} tuvo diferencia agregada de "
            f"{row['tch_sum_diff']:,.0f} TCH ({row['tch_sum_pct_diff']:.2%})."
        )
        lines.append(
            f"- Real agregado: {row['actual_tch_sum']:,.0f}; predicho agregado: {row['pred_tch_sum']:,.0f}; "
            f"filas: {int(row['rows']):,}."
        )
    lines.extend(
        [
            "- El objetivo del diagnostico es separar si el problema viene de distribucion del target, drift de features, calidad/cobertura o grupos categoricos concretos.",
            "- Nota SHAP: el archivo `shap_values.parquet` guardado por este job contiene muestra de test 2024_2025, no validation 2023_2024; por eso no permite SHAP local directo para la zafra anomala.",
            "",
            "## Agregado por zafra",
            md_table(
                aggregate_df,
                [
                    "zafra_norm",
                    "split",
                    "rows",
                    "actual_tch_sum",
                    "pred_tch_sum",
                    "tch_sum_diff",
                    "tch_sum_pct_diff",
                    "r2",
                ],
                rows=10,
            ),
            "",
            "## Distribucion del target",
            md_table(
                target_df,
                [
                    "zafra_norm",
                    "split",
                    "rows",
                    "actual_tch_mean",
                    "actual_tch_median",
                    "actual_tch_p10",
                    "actual_tch_p90",
                    "area_sum",
                ],
                rows=10,
            ),
            "",
            "## Drift de features top SHAP",
            md_table(
                worst_drift,
                [
                    "feature",
                    "source",
                    "anomaly_mean",
                    "reference_mean",
                    "test_2024_2025_mean",
                    "external_2025_2026_mean",
                    "std_diff_vs_reference",
                    "anomaly_missing_rate",
                ],
                rows=10,
            ),
            "",
            "## Calidad y cobertura",
            md_table(
                quality_df,
                [
                    "zafra_norm",
                    "rows",
                    "optical_obs_count_0_180_mean",
                    "optical_max_gap_days_0_180_mean",
                    "climate_pentad_count_0_180_mean",
                    "climate_max_gap_days_0_180_mean",
                    "cycle_age_max_mean",
                ],
                rows=10,
            ),
            "",
            "## Categorias con mayor contribucion al error en la zafra anomala",
            md_table(
                anomaly_categories,
                [
                    "feature",
                    "category_value",
                    "rows",
                    "actual_tch_sum",
                    "pred_tch_sum",
                    "tch_sum_diff",
                    "tch_sum_pct_diff",
                    "tch_mae",
                ],
                rows=15,
            ),
            "",
            "## Cobertura SHAP guardada",
            md_table(shap_coverage, ["split", "zafra_norm", "shap_rows"], rows=10),
            "",
            "## Archivos generados",
            "- `target_distribution_by_zafra.csv`",
            "- `aggregate_prediction_by_zafra.csv`",
            "- `feature_drift_top_shap.csv`",
            "- `data_quality_by_zafra.csv`",
            "- `error_by_category.csv`",
            "- `error_by_feature_bins_2023_2024.csv`",
            "- `shap_sample_coverage.csv`",
            "- `shap_importance_saved_sample.csv`",
        ]
    )
    (output_dir / "anomalous_zafra_report.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-parquet", default=str(DEFAULT_DATASET))
    parser.add_argument("--artifact-dir", default=str(DEFAULT_ARTIFACT_DIR))
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR))
    parser.add_argument("--anomaly-zafra", default="2023_2024")
    parser.add_argument("--reference-zafras", default="2020_2021,2021_2022,2022_2023")
    parser.add_argument("--top-n-features", type=int, default=30)
    args = parser.parse_args()

    dataset_path = Path(args.dataset_parquet)
    artifact_dir = Path(args.artifact_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    pred = read_csv(artifact_dir / "predictions_by_lot.csv")
    metrics_by_zafra = read_csv(artifact_dir / "metrics_by_zafra.csv")
    importance = read_csv(artifact_dir / "feature_importance_shap.csv")
    features = pd.read_parquet(dataset_path)

    data = pred.merge(features, on="cod_cg_zafra", how="left", suffixes=("", "_feature"))
    reference_zafras = [z.strip() for z in args.reference_zafras.split(",") if z.strip()]
    top_features = importance["feature"].head(args.top_n_features).astype(str).tolist()

    target_df = target_distribution(pred)
    aggregate_df = metrics_by_zafra.sort_values("zafra_norm")
    drift_df = numeric_feature_drift(data, top_features, args.anomaly_zafra, reference_zafras)
    quality_df = data_quality_by_zafra(data)
    category_df = category_error(pred, args.anomaly_zafra)
    bins_df = error_by_feature_bins(data, args.anomaly_zafra, top_features)
    shap_coverage, shap_importance_sample = shap_sample_coverage(artifact_dir / "shap_values.parquet", pred)

    target_df.to_csv(output_dir / "target_distribution_by_zafra.csv", index=False)
    aggregate_df.to_csv(output_dir / "aggregate_prediction_by_zafra.csv", index=False)
    drift_df.to_csv(output_dir / "feature_drift_top_shap.csv", index=False)
    quality_df.to_csv(output_dir / "data_quality_by_zafra.csv", index=False)
    category_df.to_csv(output_dir / "error_by_category.csv", index=False)
    bins_df.to_csv(output_dir / f"error_by_feature_bins_{args.anomaly_zafra}.csv", index=False)
    shap_coverage.to_csv(output_dir / "shap_sample_coverage.csv", index=False)
    shap_importance_sample.to_csv(output_dir / "shap_importance_saved_sample.csv", index=False)

    run_metadata = {
        "dataset_parquet": str(dataset_path),
        "artifact_dir": str(artifact_dir),
        "output_dir": str(output_dir),
        "anomaly_zafra": args.anomaly_zafra,
        "reference_zafras": reference_zafras,
        "top_n_features": args.top_n_features,
        "rows": int(len(data)),
    }
    (output_dir / "run_metadata.json").write_text(json.dumps(run_metadata, indent=2), encoding="utf-8")
    write_report(output_dir, args.anomaly_zafra, target_df, aggregate_df, drift_df, quality_df, category_df, shap_coverage)
    print(f"Wrote anomalous zafra diagnostics to {output_dir}")


if __name__ == "__main__":
    main()
