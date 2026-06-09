# Query organization

The query tree is organized by lifecycle and model version.

```text
queries/
|-- active/          Current dataset used for uploads and training
|-- diagnostics/     Audits, runners, and diagnostic reports
|-- templates/       Local reusable raw or longitudinal templates
`-- archive/         Historical datasets, views, and experiments
```

## Current dataset

The only active dataset is v7:

```text
active/v7/dataset/tch_features_v7_dynamic_all_cycles.sql
```

It produces one row per lot-cycle and includes:

- training zafras `2020_2021` through `2025_2026`;
- open scoring cycles for `2026_2027`;
- natural as-of ages between 180 and 340 days;
- optical, climate, ENSO, agronomic, and historical features;
- explicit source-quality flags and `asof_valid`.

Upload it with:

```powershell
python sagemaker/jobs/upload_dataset.py tch_features_v7_dynamic_all_cycles
```

## V7 diagnostics

Diagnostics are grouped by purpose:

```text
diagnostics/v7/
|-- acceptance/      Final dataset inclusion and coverage checks
|-- cycle/           Crop-cycle age and boundary investigations
|-- lot_keys/        Source-key matching and historical rescue audits
`-- optical/         Vegetation quality and threshold recalibration
```

Diagnostic outputs are written under `.tmp/v7_dynamic_audits/`; generated
artifacts do not belong in the active query directory.

## Local historical material

Fixed 180-day datasets are archived by their actual version:

```text
archive/v5/asof_180/
archive/v6/asof_180/
```

Older aggregated, sequential, and pseudo-sequential experiments remain under
`archive/v1` through `archive/v4`.

`archive/`, `diagnostics/`, and `templates/` are intentionally local and
ignored by Git. The uploader can still resolve local archived v5 and v6
dataset names, but committed dataset SQL should live only under `active/`.

## Conventions

- Keep only the current production candidate under `active/`.
- Put executable audits and their reports under `diagnostics/<version>/`.
- Store generated CSV, parquet, and temporary outputs outside `queries/`.
- Move superseded dataset SQL to `archive/<version>/`.
- Name dataset files after the S3 dataset key used by SageMaker.
