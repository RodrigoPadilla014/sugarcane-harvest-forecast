import os

import pandas as pd


def save_shap_values(model, model_type: str, X: pd.DataFrame, output_dir: str, max_rows: int = 5000) -> None:
    if model_type not in {"xgboost", "lightgbm", "catboost", "random_forest"}:
        return

    try:
        import shap
    except Exception as exc:
        with open(os.path.join(output_dir, "shap_error.txt"), "w") as f:
            f.write(f"SHAP import failed: {exc}\n")
        print(f"SHAP skipped: {exc}")
        return

    try:
        sample = X.sample(n=min(max_rows, len(X)), random_state=42) if len(X) > max_rows else X
        estimator = model
        explain_sample = sample
        if hasattr(model, "steps"):
            estimator = model.steps[-1][1]
            transformed = model[:-1].transform(sample)
            explain_sample = pd.DataFrame(transformed, columns=sample.columns, index=sample.index)

        explainer = shap.TreeExplainer(estimator)
        shap_values = explainer.shap_values(explain_sample)
        shap_df = pd.DataFrame(shap_values, columns=sample.columns, index=sample.index)
        shap_df.to_parquet(os.path.join(output_dir, "shap_values.parquet"), index=True)

        importance = (
            shap_df.abs()
            .mean()
            .rename("mean_abs_shap")
            .reset_index()
            .rename(columns={"index": "feature"})
            .sort_values("mean_abs_shap", ascending=False)
        )
        importance.to_csv(os.path.join(output_dir, "feature_importance_shap.csv"), index=False)
    except Exception as exc:
        with open(os.path.join(output_dir, "shap_error.txt"), "w") as f:
            f.write(f"SHAP generation failed: {exc}\n")
        print(f"SHAP skipped: {exc}")
