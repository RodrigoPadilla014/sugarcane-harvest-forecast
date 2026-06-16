# Query organization

The query tree is organized by lifecycle and model version.

```text
queries/
|-- active/          Current dataset SQL used for uploads and training
|-- diagnostics/     Audits, runners, and diagnostic reports
|-- templates/       Local reusable raw or longitudinal templates
`-- archive/         Historical datasets, views, and experiments
```

## Active dataset

The active dataset is v9:

```text
active/v9/dataset/tch_v9_productivity_snapshot_spine.sql
active/v9/dataset/tch_features_v9_productivity_snapshots.sql
```

V9 is snapshot-aware and uses `productividad` as the historical source of truth.
It keeps valid historical productive lot-cycles, creates fixed snapshots at
180, 210, 240, 270, 300, and 340 days, and adds current scoring rows for
`2026_2027` based on productive lots observed in `2025_2026`.

Upload it as a partitioned parquet dataset:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v9_productivity_snapshots `
  --chunksize 50000 `
  --replace
```

The uploader resolves local SQL includes:

```text
{{ include:tch_v9_productivity_snapshot_spine }}
```

so feature SQL can compose reusable spine logic without duplicating the full
query.

## Supporting active experiments

V7 and V8 remain under `active/` for comparison and rollback context:

```text
active/v7/dataset/tch_features_v7_dynamic_all_cycles.sql
active/v8/dataset/tch_features_v8_dynamic_radar.sql
```

V7 introduced dynamic as-of windows and explicit scoring validity. V8 preserved
that structure while testing radar-first satellite features. V9 is the current
candidate because it moves the design toward productividad-defined historical
validity plus updateable scoring snapshots.

## Diagnostics

Diagnostics are grouped by purpose:

```text
diagnostics/v7/
diagnostics/v8/
diagnostics/v9/
diagnostics/scoring_coverage/
diagnostics/productivity_transitions/
```

Generated diagnostic CSV/parquet outputs should go under `.tmp/` or another
scratch location, not under `queries/active/`.

## Historical material

Older fixed-window datasets are archived by version:

```text
archive/v5/asof_180/
archive/v6/asof_180/
```

Older aggregated, sequential, and pseudo-sequential experiments remain under
`archive/v1` through `archive/v4`.

`archive/`, `diagnostics/`, and `templates/` are intentionally ignored by Git.
The committed active SQL should be limited to dataset definitions that are
still useful for current training or comparison.

## Conventions

- Keep current candidate SQL under `active/<version>/dataset/`.
- Put executable audits and their reports under `diagnostics/<version>/`.
- Store generated CSV, parquet, and temporary outputs outside `queries/`.
- Move superseded dataset SQL to `archive/<version>/`.
- Name dataset files after the S3 dataset key used by the uploader/training
  pipeline.
