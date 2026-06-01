# v5 as-of-180 feature blocks

These blocks document the source-family boundaries used by the final
self-contained query:

```text
queries/active/asof_180/queries/tch_features_v5_asof_180d_core.sql
```

The final query embeds the same block structure as CTEs so
`sagemaker/jobs/upload_dataset.py` can upload a single SQL file directly.

Block intent:

- `tch_agronomy_asof_180_v5.sql`: target, metadata, cutoff fields, and safe static agronomy.
- `tch_optical_asof_180_v5.sql`: STAC optical summaries using only age 0-180.
- `tch_climate_asof_180_v5.sql`: pentadal climate summaries using only age 0-180.
- `tch_enso_asof_180_v5.sql`: ENSO pre-cycle and age 0-180 context.

Do not add harvest operation, quality/lab, full-cycle, or post-cutoff fields to these blocks.
