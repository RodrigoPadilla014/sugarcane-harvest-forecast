# Query organization

The committed query tree keeps the official production dataset and active
challenger datasets under `queries/active`. Earlier dataset versions can be
kept locally under `queries/archive`, but archive content is intentionally
ignored by Git.

```text
queries/
|-- active/          Official and challenger dataset SQL
`-- archive/         Local historical SQL and experiments, ignored by Git
```

## Active datasets

The production dataset is V10:

```text
active/v10/dataset/tch_v10_productivity_snapshot_spine.sql
active/v10/dataset/tch_features_v10_productivity_history_snapshots.sql
```

V13 is a challenger dataset under active development:

```text
active/v13/dataset/tch_features_v13_spatial_enso_harvest.sql
active/v13/dataset/tch_v13_diagnostics.sql
```

Upload V10 as a partitioned parquet dataset:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v10_productivity_history_snapshots `
  --chunked `
  --chunksize 50000
```

The uploader resolves local SQL includes:

```text
{{ include:tch_v10_productivity_snapshot_spine }}
```

so the feature query can reuse the snapshot spine without duplicating the full
SQL.

Upload V13 with:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v13_spatial_enso_harvest `
  --chunked `
  --chunksize 50000
```

## V10 dataset logic

V10 is a snapshot-aware productivity dataset. It uses `productividad` as the
historical source of truth for lot-cycle validity, then joins climate, optical,
radar, ENSO, soil, variety, cut, and management features as explanatory inputs.

Historical rows:

- keep valid productive lot-cycles with usable TCH;
- create fixed snapshots at 180, 210, 240, 270, 300, and 340 days;
- apply snapshot weights so one cycle does not dominate only because it has
  multiple snapshots;
- include lagged historical productivity features computed only from earlier
  zafras.

Scoring rows:

- represent the next productive zafra;
- include only lots old enough to be scored at the current snapshot date;
- keep pending lots outside the scored population until enough observations are
  available;
- use the latest available historical productivity as the residual-model anchor.

## V13 challenger logic

V13 starts from the V10 population and adds:

- same-year spatial shape features with fallback metadata;
- leakage-checked ENSO probability forecasts;
- lagged expected harvest-timing features;
- diagnostics for realized harvest timing, blocked from model training.

V10 remains the official production baseline until real-world monitoring or a
future validation cycle promotes a challenger.

## Conventions

- Keep the official production dataset and current challengers under `active/`.
- Move superseded or abandoned SQL versions to `archive/`.
- Do not commit generated CSV, parquet, credentials, local extracts, or
  diagnostic outputs.
- Name dataset files after the S3 dataset key expected by the uploader and
  training runner.
