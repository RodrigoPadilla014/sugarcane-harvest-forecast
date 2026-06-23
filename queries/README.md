# Query organization

The committed query tree keeps only the production dataset definition under
`queries/active`. Earlier dataset versions can be kept locally under
`queries/archive`, but archive content is intentionally ignored by Git.

```text
queries/
|-- active/          Current production dataset SQL
`-- archive/         Local historical SQL and experiments, ignored by Git
```

## Active dataset

The active dataset is V10:

```text
active/v10/dataset/tch_v10_productivity_snapshot_spine.sql
active/v10/dataset/tch_features_v10_productivity_history_snapshots.sql
```

Upload it as a partitioned parquet dataset:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v10_productivity_history_snapshots `
  --chunked `
  --chunksize 50000 `
  --replace
```

The uploader resolves local SQL includes:

```text
{{ include:tch_v10_productivity_snapshot_spine }}
```

so the feature query can reuse the snapshot spine without duplicating the full
SQL.

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

## Conventions

- Keep exactly one committed production dataset under `active/`.
- Move superseded SQL versions to `archive/`.
- Do not commit generated CSV, parquet, credentials, local extracts, or
  diagnostic outputs.
- Name dataset files after the S3 dataset key expected by the uploader and
  training runner.
