# Query layout

`queries/` keeps only active dataset SQL and reusable templates in version control.

- `active/`: current production-style feature query assets.
- `templates/`: reusable source or raw-longitudinal SQL templates.

Historical experiments and diagnostics are local scratch material and are ignored
by Git.

The active SageMaker upload path is:

```text
queries/active/asof_180/queries/tch_features_v5_asof_180d_core.sql
```
