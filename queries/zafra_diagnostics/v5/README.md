# v5 anomalous zafra diagnostics

Diagnostics for the v5 `asof_180` model, focused on explaining why a specific
zafra behaves differently from the historical training years.

Default focus:

- anomalous zafra: `2023_2024`
- reference zafras: `2020_2021`, `2021_2022`, `2022_2023`
- test zafra: `2024_2025`
- external partial zafra: `2025_2026`

Run from the repository root after the model artifacts and dataset parquet are
available locally:

```powershell
python queries/zafra_diagnostics/v5/run_anomalous_zafra_diagnostic.py `
  --dataset-parquet .tmp/tch_features_v5_asof_180d_core.parquet `
  --artifact-dir .tmp/tch-tch-features-v5-asof-180d-core-catboost-20260528-143010 `
  --output-dir queries/zafra_diagnostics/v5/artifacts/tch-tch-features-v5-asof-180d-core-catboost-20260528-143010
```

Generated artifacts:

- `target_distribution_by_zafra.csv`
- `aggregate_prediction_by_zafra.csv`
- `feature_drift_top_shap.csv`
- `data_quality_by_zafra.csv`
- `error_by_category.csv`
- `error_by_feature_bins_2023_2024.csv`
- `shap_sample_coverage.csv`
- `shap_importance_saved_sample.csv`
- `anomalous_zafra_report.md`

The script does not touch the database.
