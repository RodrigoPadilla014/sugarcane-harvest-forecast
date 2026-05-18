import json
import os
import re
from dataclasses import dataclass, field
from typing import Any

import numpy as np
import pandas as pd


CATEGORICAL_MODE_CONTROLLED = "controlled"
CATEGORICAL_MODE_NATIVE = "native"
CATEGORICAL_MODE_NONE = "none"
CATEGORICAL_MODES = {
    CATEGORICAL_MODE_CONTROLLED,
    CATEGORICAL_MODE_NATIVE,
    CATEGORICAL_MODE_NONE,
}

OTHER_CATEGORY = "__OTHER__"
MISSING_CATEGORY = "__MISSING__"

DROP_CATEGORICAL_COLS = {
    "prod_finca",
}

DEFAULT_CATEGORICAL_RULE = {"strategy": "all"}

CATEGORICAL_ENCODING_RULES = {
    "prod_familia_de_suelo": {"strategy": "min_count", "min_count": 30},
    "prod_variedad": {"strategy": "top_n_or_min_count", "top_n": 30, "min_count": 30},
    "prod_codigo_zae": {"strategy": "min_count", "min_count": 30},
    "prod_ingenio": {"strategy": "all"},
    "prod_grupo_de_suelo": {"strategy": "all"},
    "prod_grupo_de_humedad": {"strategy": "all"},
    "prod_no_corte": {"strategy": "all"},
    "prod_cosecha": {"strategy": "all"},
}

NATIVE_CATEGORICAL_MODEL_TYPES = {"catboost"}


def categorical_feature_columns(X: pd.DataFrame) -> list[str]:
    return list(X.select_dtypes(exclude="number").columns)


def sanitize_feature_name(name: object) -> str:
    sanitized = re.sub(r"[^0-9A-Za-z_]+", "_", str(name))
    sanitized = re.sub(r"_+", "_", sanitized).strip("_")
    if not sanitized:
        sanitized = "feature"
    if sanitized[0].isdigit():
        sanitized = f"f_{sanitized}"
    return sanitized


def sanitize_feature_columns(features: pd.DataFrame) -> pd.DataFrame:
    sanitized_columns = [sanitize_feature_name(col) for col in features.columns]
    seen = {}
    unique_columns = []
    for col in sanitized_columns:
        count = seen.get(col, 0)
        unique_columns.append(col if count == 0 else f"{col}_{count}")
        seen[col] = count + 1

    features = features.copy()
    features.columns = unique_columns
    return features


def _normalize_category_value(value: Any) -> str:
    if pd.isna(value):
        return MISSING_CATEGORY
    return str(value)


def _category_series(series: pd.Series) -> pd.Series:
    return series.astype("string").fillna(MISSING_CATEGORY).astype(str)


def _categories_for_rule(series: pd.Series, rule: dict) -> list[str]:
    values = _category_series(series)
    counts = values[values != MISSING_CATEGORY].value_counts(dropna=False)
    strategy = rule.get("strategy", DEFAULT_CATEGORICAL_RULE["strategy"])

    if strategy == "all":
        keep = counts.index.tolist()
    elif strategy == "min_count":
        min_count = int(rule["min_count"])
        keep = counts[counts >= min_count].index.tolist()
    elif strategy == "top_n":
        top_n = int(rule["top_n"])
        keep = counts.head(top_n).index.tolist()
    elif strategy == "top_n_or_min_count":
        top_n = int(rule["top_n"])
        min_count = int(rule["min_count"])
        top_values = set(counts.head(top_n).index)
        frequent_values = set(counts[counts >= min_count].index)
        keep = [value for value in counts.index if value in top_values or value in frequent_values]
    elif strategy == "drop":
        keep = []
    else:
        raise ValueError(f"Unknown categorical encoding strategy: {strategy}")

    return sorted(str(value) for value in keep)


@dataclass
class CategoricalEncodingState:
    mode: str
    rules: dict[str, dict] = field(default_factory=dict)
    drop_cols: list[str] = field(default_factory=list)
    categorical_cols: list[str] = field(default_factory=list)
    vocabularies: dict[str, list[str]] = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "mode": self.mode,
            "rules": self.rules,
            "drop_cols": self.drop_cols,
            "categorical_cols": self.categorical_cols,
            "vocabularies": self.vocabularies,
            "other_category": OTHER_CATEGORY,
            "missing_category": MISSING_CATEGORY,
        }


def resolve_categorical_mode(
    categorical_mode: str | None,
    one_hot_features: bool | None = None,
) -> str:
    if categorical_mode:
        mode = categorical_mode.lower()
    elif one_hot_features is False:
        mode = CATEGORICAL_MODE_NATIVE
    else:
        mode = CATEGORICAL_MODE_CONTROLLED

    if mode not in CATEGORICAL_MODES:
        raise ValueError(f"Unknown categorical_mode={categorical_mode!r}. Expected one of {sorted(CATEGORICAL_MODES)}")
    return mode


def validate_categorical_mode_for_model(categorical_mode: str, model_type: str) -> None:
    if categorical_mode == CATEGORICAL_MODE_NATIVE and model_type not in NATIVE_CATEGORICAL_MODEL_TYPES:
        supported = ", ".join(sorted(NATIVE_CATEGORICAL_MODEL_TYPES))
        raise ValueError(
            f"categorical_mode='native' is not implemented for model_type='{model_type}'. "
            f"Use categorical_mode='controlled' or choose one of: {supported}."
        )


def fit_categorical_encoder(
    X: pd.DataFrame,
    train_idx,
    mode: str,
    rules: dict[str, dict] | None = None,
    drop_cols: set[str] | None = None,
) -> CategoricalEncodingState:
    rules = dict(CATEGORICAL_ENCODING_RULES if rules is None else rules)
    drop_cols = set(DROP_CATEGORICAL_COLS if drop_cols is None else drop_cols)
    categorical_cols = [col for col in categorical_feature_columns(X) if col not in drop_cols]
    present_drop_cols = sorted(col for col in drop_cols if col in X.columns)

    state = CategoricalEncodingState(
        mode=mode,
        rules={col: dict(rules.get(col, DEFAULT_CATEGORICAL_RULE)) for col in categorical_cols},
        drop_cols=present_drop_cols,
        categorical_cols=categorical_cols,
    )

    if mode != CATEGORICAL_MODE_CONTROLLED:
        return state

    train_index = pd.Index(train_idx).intersection(X.index)
    if train_index.empty:
        raise ValueError("Cannot fit categorical encoder: train index is empty after alignment.")

    for col in categorical_cols:
        rule = state.rules[col]
        state.vocabularies[col] = _categories_for_rule(X.loc[train_index, col], rule)

    return state


def _apply_controlled_vocab(series: pd.Series, vocabulary: list[str]) -> pd.Series:
    values = _category_series(series)
    allowed = set(vocabulary)
    values = values.where(values.isin(allowed) | (values == MISSING_CATEGORY), OTHER_CATEGORY)
    categories = list(vocabulary)
    for category in (OTHER_CATEGORY, MISSING_CATEGORY):
        if category not in categories:
            categories.append(category)
    return pd.Series(pd.Categorical(values, categories=categories), index=series.index, name=series.name)


def transform_categorical_features(X: pd.DataFrame, state: CategoricalEncodingState) -> pd.DataFrame:
    transformed = X.drop(columns=[col for col in state.drop_cols if col in X.columns]).copy()
    categorical_cols = [col for col in state.categorical_cols if col in transformed.columns]

    if state.mode == CATEGORICAL_MODE_NONE:
        return sanitize_feature_columns(transformed.drop(columns=categorical_cols)).replace([np.inf, -np.inf], np.nan)

    if state.mode == CATEGORICAL_MODE_NATIVE:
        for col in categorical_cols:
            transformed[col] = _category_series(transformed[col])
        return sanitize_feature_columns(transformed).replace([np.inf, -np.inf], np.nan)

    if state.mode != CATEGORICAL_MODE_CONTROLLED:
        raise ValueError(f"Unknown categorical encoding mode: {state.mode}")

    dummy_source = transformed[categorical_cols].copy()
    for col in categorical_cols:
        dummy_source[col] = _apply_controlled_vocab(dummy_source[col], state.vocabularies.get(col, []))

    numeric = transformed.drop(columns=categorical_cols)
    dummies = pd.get_dummies(dummy_source, dummy_na=False, dtype=np.uint8)
    encoded = pd.concat([numeric, dummies], axis=1)
    return sanitize_feature_columns(encoded).replace([np.inf, -np.inf], np.nan)


def fit_transform_categorical_features(
    X: pd.DataFrame,
    train_idx,
    mode: str,
    rules: dict[str, dict] | None = None,
    drop_cols: set[str] | None = None,
) -> tuple[pd.DataFrame, CategoricalEncodingState]:
    state = fit_categorical_encoder(X, train_idx, mode=mode, rules=rules, drop_cols=drop_cols)
    return transform_categorical_features(X, state), state


def save_categorical_encoding_state(state: CategoricalEncodingState, output_dir: str) -> None:
    os.makedirs(output_dir, exist_ok=True)
    path = os.path.join(output_dir, "categorical_encoding.json")
    with open(path, "w") as f:
        json.dump(state.to_dict(), f, indent=2)
