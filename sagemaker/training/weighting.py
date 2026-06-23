"""Fold-local sample weighting for TCH training."""

from __future__ import annotations

import numpy as np
import pandas as pd


RESIDUAL_ANCHOR_FEATURE = "last_hist_tch"
WEIGHT_MODES = {
    "snapshot",
    "snapshot_sqrt_area",
    "snapshot_density",
    "snapshot_historical_tch",
    "snapshot_area_density",
}


def sample_weights_for_index(
    metadata: pd.DataFrame,
    index: pd.Index,
) -> pd.Series | None:
    if "snapshot_weight" not in metadata.columns:
        return None
    weights = (
        metadata.set_index("cod_cg_zafra")["snapshot_weight"]
        .reindex(index)
        .astype(float)
    )
    if weights.isna().any():
        raise ValueError("snapshot_weight is missing for one or more model rows")
    return weights


def _capped_area_modifier(
    metadata_by_group: pd.DataFrame,
    index: pd.Index,
    reference_index: pd.Index,
    max_multiplier: float,
) -> pd.Series:
    area = pd.to_numeric(metadata_by_group["area"], errors="coerce")
    reference = np.sqrt(area.reindex(reference_index).dropna().clip(lower=0))
    if reference.empty:
        raise ValueError("Area weighting requires non-missing area in the training fold")
    scale = float(reference.median())
    if scale <= 0:
        return pd.Series(1.0, index=index)
    modifier = np.sqrt(area.reindex(index).clip(lower=0)) / scale
    return modifier.clip(lower=1.0, upper=max_multiplier).fillna(1.0)


def _capped_density_modifier(
    y_actual: pd.Series,
    index: pd.Index,
    reference_index: pd.Index,
    max_multiplier: float,
    bin_width: float,
) -> pd.Series:
    if bin_width <= 0:
        raise ValueError("weight_density_bin_width must be positive")
    reference = pd.to_numeric(y_actual.reindex(reference_index), errors="coerce").dropna()
    if reference.empty:
        raise ValueError("Density weighting requires targets in the training fold")
    reference_bins = np.floor(reference / bin_width).astype(int)
    counts = reference_bins.value_counts()
    max_count = float(counts.max())
    target = pd.to_numeric(y_actual.reindex(index), errors="coerce")
    target_bins = np.floor(target / bin_width)
    target_counts = target_bins.map(counts).fillna(1.0).astype(float)
    modifier = np.sqrt(max_count / target_counts)
    return modifier.clip(lower=1.0, upper=max_multiplier).fillna(1.0)


def _capped_historical_tch_modifier(
    X: pd.DataFrame,
    index: pd.Index,
    reference_index: pd.Index,
    max_multiplier: float,
) -> pd.Series:
    if RESIDUAL_ANCHOR_FEATURE not in X.columns:
        raise ValueError(
            f"Historical-TCH weighting requires {RESIDUAL_ANCHOR_FEATURE}"
        )
    history = pd.to_numeric(X[RESIDUAL_ANCHOR_FEATURE], errors="coerce")
    reference = history.reindex(reference_index).dropna()
    if reference.empty:
        raise ValueError("Historical-TCH weighting has no training-fold anchors")
    median = float(reference.median())
    upper = float(reference.quantile(0.90))
    if upper <= median:
        return pd.Series(1.0, index=index)
    relative = (history.reindex(index) - median) / (upper - median)
    modifier = 1.0 + (max_multiplier - 1.0) * relative.clip(lower=0.0, upper=1.0)
    return modifier.fillna(1.0)


def training_weights_for_index(
    metadata: pd.DataFrame,
    y_actual: pd.Series,
    X: pd.DataFrame,
    index: pd.Index,
    reference_index: pd.Index,
    mode: str = "snapshot",
    max_multiplier: float = 1.0,
    density_bin_width: float = 5.0,
) -> pd.Series | None:
    """Build fitting weights using training-fold rows as the only reference."""
    if mode not in WEIGHT_MODES:
        raise ValueError(f"Unknown weight_mode={mode!r}")
    if max_multiplier < 1.0:
        raise ValueError("weight_max_multiplier must be at least 1.0")

    base = sample_weights_for_index(metadata, index)
    if base is None:
        base = pd.Series(1.0, index=index)
    if mode == "snapshot" or max_multiplier == 1.0:
        return base

    metadata_by_group = metadata.set_index("cod_cg_zafra")
    modifier = pd.Series(1.0, index=index)
    if mode in {"snapshot_sqrt_area", "snapshot_area_density"}:
        modifier *= _capped_area_modifier(
            metadata_by_group,
            index,
            reference_index,
            max_multiplier,
        )
    if mode in {"snapshot_density", "snapshot_area_density"}:
        modifier *= _capped_density_modifier(
            y_actual,
            index,
            reference_index,
            max_multiplier,
            density_bin_width,
        )
    if mode == "snapshot_historical_tch":
        modifier *= _capped_historical_tch_modifier(
            X,
            index,
            reference_index,
            max_multiplier,
        )

    modifier = modifier.clip(lower=1.0, upper=max_multiplier)
    return base * modifier


def weight_diagnostics(
    metadata: pd.DataFrame,
    y_actual: pd.Series,
    X: pd.DataFrame,
    index: pd.Index,
    mode: str,
    max_multiplier: float,
    density_bin_width: float,
) -> pd.DataFrame:
    base = sample_weights_for_index(metadata, index)
    weights = training_weights_for_index(
        metadata,
        y_actual,
        X,
        index,
        index,
        mode=mode,
        max_multiplier=max_multiplier,
        density_bin_width=density_bin_width,
    )
    if base is None:
        base = pd.Series(1.0, index=index)
    modifier = weights / base
    return pd.DataFrame(
        {
            "metric": [
                "rows",
                "weight_min",
                "weight_median",
                "weight_mean",
                "weight_max",
                "modifier_min",
                "modifier_median",
                "modifier_mean",
                "modifier_max",
                "pct_modifier_gt_1",
            ],
            "value": [
                len(weights),
                float(weights.min()),
                float(weights.median()),
                float(weights.mean()),
                float(weights.max()),
                float(modifier.min()),
                float(modifier.median()),
                float(modifier.mean()),
                float(modifier.max()),
                float((modifier > 1.0 + 1e-12).mean() * 100.0),
            ],
        }
    )
