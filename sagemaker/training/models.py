import optuna
from sklearn.ensemble import RandomForestRegressor
from sklearn.linear_model import Ridge


def build_model(model_type: str, params: dict):
    if model_type == "xgboost":
        import xgboost as xgb

        return xgb.XGBRegressor(**params, random_state=42, verbosity=0)
    if model_type == "lightgbm":
        import lightgbm as lgb

        return lgb.LGBMRegressor(**params, random_state=42, verbosity=-1)
    if model_type == "catboost":
        import catboost as cb

        return cb.CatBoostRegressor(**params, random_seed=42, verbose=False)
    if model_type == "random_forest":
        return RandomForestRegressor(**params, random_state=42, n_jobs=-1)
    if model_type == "ridge":
        return Ridge(**params)
    raise ValueError(f"Unknown model type: {model_type}")


def suggest_params(trial: optuna.Trial, model_type: str) -> dict:
    if model_type == "xgboost":
        return {
            "n_estimators": trial.suggest_int("n_estimators", 200, 1200),
            "max_depth": trial.suggest_int("max_depth", 3, 10),
            "learning_rate": trial.suggest_float("learning_rate", 1e-3, 0.2, log=True),
            "subsample": trial.suggest_float("subsample", 0.6, 1.0),
            "colsample_bytree": trial.suggest_float("colsample_bytree", 0.6, 1.0),
            "min_child_weight": trial.suggest_float("min_child_weight", 1.0, 20.0),
            "reg_alpha": trial.suggest_float("reg_alpha", 1e-8, 10.0, log=True),
            "reg_lambda": trial.suggest_float("reg_lambda", 1e-4, 20.0, log=True),
        }
    if model_type == "lightgbm":
        return {
            "n_estimators": trial.suggest_int("n_estimators", 200, 1200),
            "num_leaves": trial.suggest_int("num_leaves", 16, 256),
            "max_depth": trial.suggest_int("max_depth", 3, 12),
            "learning_rate": trial.suggest_float("learning_rate", 1e-3, 0.2, log=True),
            "subsample": trial.suggest_float("subsample", 0.6, 1.0),
            "colsample_bytree": trial.suggest_float("colsample_bytree", 0.6, 1.0),
            "min_child_samples": trial.suggest_int("min_child_samples", 5, 100),
            "reg_alpha": trial.suggest_float("reg_alpha", 1e-8, 10.0, log=True),
            "reg_lambda": trial.suggest_float("reg_lambda", 1e-4, 20.0, log=True),
        }
    if model_type == "catboost":
        return {
            "iterations": trial.suggest_int("iterations", 300, 800),
            "depth": trial.suggest_int("depth", 3, 10),
            "learning_rate": trial.suggest_float("learning_rate", 1e-3, 0.2, log=True),
            "l2_leaf_reg": trial.suggest_float("l2_leaf_reg", 1e-3, 20.0, log=True),
            "random_strength": trial.suggest_float("random_strength", 1e-3, 10.0, log=True),
            "loss_function": "RMSE",
        }
    if model_type == "random_forest":
        return {
            "n_estimators": trial.suggest_int("n_estimators", 200, 800),
            "max_depth": trial.suggest_int("max_depth", 3, 30),
            "min_samples_leaf": trial.suggest_int("min_samples_leaf", 1, 20),
        }
    if model_type == "ridge":
        return {"alpha": trial.suggest_float("alpha", 1e-3, 1e3, log=True)}
    raise ValueError(f"Unknown model type: {model_type}")
