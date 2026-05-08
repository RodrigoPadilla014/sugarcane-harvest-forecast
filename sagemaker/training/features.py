import pandas as pd

# Edit this list between iterations based on SHAP findings.
# If empty, all numeric columns (except target) are used.
FEATURES: list[str] = []


def build_features(df: pd.DataFrame, target: str = "tch") -> tuple[pd.DataFrame, pd.Series]:
    df = df.dropna(subset=[target])

    if FEATURES:
        X = df[FEATURES]
    else:
        X = df.select_dtypes(include="number").drop(columns=[target], errors="ignore")

    y = df[target]
    return X, y
