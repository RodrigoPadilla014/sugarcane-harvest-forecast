"""
SageMaker training entry point.

Runs: feature engineering → Optuna → train best model → SHAP → save artifacts.
"""
import argparse
import json
import os

import joblib
import numpy as np
import optuna
import pandas as pd
import shap
import xgboost as xgb
from sklearn.ensemble import RandomForestRegressor
from sklearn.linear_model import Ridge
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score
from sklearn.model_selection import cross_val_score

from features import build_features

optuna.logging.set_verbosity(optuna.logging.WARNING)


def build_model(model_type: str, params: dict):
    if model_type == "xgboost":
        return xgb.XGBRegressor(**params, random_state=42, verbosity=0)
    if model_type == "random_forest":
        return RandomForestRegressor(**params, random_state=42)
    if model_type == "ridge":
        return Ridge(**params)
    raise ValueError(f"Unknown model type: {model_type}")


def suggest_params(trial: optuna.Trial, model_type: str) -> dict:
    if model_type == "xgboost":
        return {
            "n_estimators": trial.suggest_int("n_estimators", 100, 1000),
            "max_depth": trial.suggest_int("max_depth", 3, 10),
            "learning_rate": trial.suggest_float("learning_rate", 1e-3, 0.3, log=True),
            "subsample": trial.suggest_float("subsample", 0.6, 1.0),
            "colsample_bytree": trial.suggest_float("colsample_bytree", 0.6, 1.0),
        }
    if model_type == "random_forest":
        return {
            "n_estimators": trial.suggest_int("n_estimators", 100, 500),
            "max_depth": trial.suggest_int("max_depth", 3, 20),
            "min_samples_leaf": trial.suggest_int("min_samples_leaf", 1, 10),
        }
    if model_type == "ridge":
        return {"alpha": trial.suggest_float("alpha", 1e-3, 1e3, log=True)}
    raise ValueError(f"Unknown model type: {model_type}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-type", type=str, default="xgboost")
    parser.add_argument("--target", type=str, default="tch")
    parser.add_argument("--n-trials", type=int, default=50)
    args = parser.parse_args()

    data_dir = os.environ.get("SM_CHANNEL_TRAIN", "/opt/ml/input/data/train")
    model_dir = os.environ.get("SM_MODEL_DIR", "/opt/ml/model")
    output_dir = os.environ.get("SM_OUTPUT_DATA_DIR", "/opt/ml/output/data")
    os.makedirs(output_dir, exist_ok=True)

    parquet_file = next(f for f in os.listdir(data_dir) if f.endswith(".parquet"))
    df = pd.read_parquet(os.path.join(data_dir, parquet_file))
    X, y = build_features(df, target=args.target)
    print(f"Dataset: {X.shape[0]} rows, {X.shape[1]} features")

    def objective(trial):
        params = suggest_params(trial, args.model_type)
        model = build_model(args.model_type, params)
        scores = cross_val_score(model, X, y, cv=5, scoring="neg_root_mean_squared_error")
        return scores.mean()

    study = optuna.create_study(direction="maximize")
    study.optimize(objective, n_trials=args.n_trials)
    best_params = study.best_params
    print(f"Best params: {best_params}")

    model = build_model(args.model_type, best_params)
    model.fit(X, y)

    y_pred = model.predict(X)
    metrics = {
        "rmse": float(np.sqrt(mean_squared_error(y, y_pred))),
        "mae": float(mean_absolute_error(y, y_pred)),
        "r2": float(r2_score(y, y_pred)),
    }
    print(f"Metrics: {metrics}")

    explainer = shap.TreeExplainer(model)
    shap_values = explainer.shap_values(X)
    shap_df = pd.DataFrame(shap_values, columns=X.columns)
    shap_df.to_parquet(os.path.join(output_dir, "shap_values.parquet"), index=False)

    joblib.dump(model, os.path.join(model_dir, "model.joblib"))
    with open(os.path.join(output_dir, "metrics.json"), "w") as f:
        json.dump(metrics, f, indent=2)
    with open(os.path.join(output_dir, "best_params.json"), "w") as f:
        json.dump(best_params, f, indent=2)

    print("Artifacts saved.")


if __name__ == "__main__":
    main()
