# V13 spatial + ENSO + harvest timing dataset

V13 is a challenger dataset. V10 remains the production baseline until V13
proves better temporal validation, aggregate metric tons behavior, and stable
bias without leakage.

## Entrypoints

```text
dataset/tch_features_v13_spatial_enso_harvest.sql
dataset/tch_v13_diagnostics.sql
```

Upload the feature dataset with:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v13_spatial_enso_harvest `
  --chunked `
  --chunksize 50000
```

## Contract

- Base population and temporal framing come from V10.
- Spatial features use same-year shapes where available.
- 2026_2027 scoring may use the latest available non-future shape, expected to
  be 2025, and must be flagged.
- ENSO probability forecasts must satisfy `forecast_issue_date <= snapshot_date`.
- Realized harvest timing fields are diagnostic only and excluded from training.
- Lagged expected harvest timing features use only earlier zafras.

## Current candidate

The retained V13 candidate keeps V10 training settings:

- residual target anchored on `last_hist_tch`;
- CatBoost;
- V10-style historical TCH weighting with cap `1.25`;
- no forced interactions or manual high-yield override;
- compare against V10, not in isolation.

The high-yield Optuna side experiment did not repair the high-yield tail, so
the weighted full V13 baseline remains the challenger for live comparison.
