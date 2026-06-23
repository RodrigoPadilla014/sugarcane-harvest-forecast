import numpy as np
import pandas as pd

from weighting import (
    sample_weights_for_index,
    training_weights_for_index,
)


def build_inputs():
    index = pd.Index([f"row_{i}" for i in range(8)], name="cod_cg_zafra")
    metadata = pd.DataFrame(
        {
            "cod_cg_zafra": index,
            "snapshot_weight": [0.5, 0.5, 1.0, 1.0, 0.5, 0.5, 1.0, 1.0],
            "area": [1, 4, 9, 16, 25, 36, 49, 64],
            "prod_estrato": ["ALTO", "ALTO", "MEDIO", "MEDIO"] * 2,
        }
    )
    y = pd.Series(
        [60, 80, 95, 105, 115, 125, 135, 145],
        index=index,
        dtype=float,
    )
    X = pd.DataFrame(
        {"last_hist_tch": [65, 75, 90, 100, 115, 125, 140, 150]},
        index=index,
        dtype=float,
    )
    return index, metadata, y, X


def main():
    index, metadata, y, X = build_inputs()
    train_idx = index[:6]

    baseline = sample_weights_for_index(metadata, train_idx)
    controlled = training_weights_for_index(
        metadata,
        y,
        X,
        train_idx,
        train_idx,
        mode="snapshot",
        max_multiplier=2.0,
    )
    assert np.allclose(baseline, controlled)

    for mode in [
        "snapshot_sqrt_area",
        "snapshot_density",
        "snapshot_historical_tch",
        "snapshot_area_density",
    ]:
        weights = training_weights_for_index(
            metadata,
            y,
            X,
            train_idx,
            train_idx,
            mode=mode,
            max_multiplier=1.5,
            density_bin_width=10.0,
        )
        modifier = weights / baseline
        assert float(modifier.min()) >= 1.0
        assert float(modifier.max()) <= 1.5 + 1e-12

    original = training_weights_for_index(
        metadata,
        y,
        X,
        train_idx,
        train_idx,
        mode="snapshot_density",
        max_multiplier=2.0,
        density_bin_width=10.0,
    )
    changed_validation = y.copy()
    changed_validation.loc[index[6:]] = [1_000, 2_000]
    unchanged = training_weights_for_index(
        metadata,
        changed_validation,
        X,
        train_idx,
        train_idx,
        mode="snapshot_density",
        max_multiplier=2.0,
        density_bin_width=10.0,
    )
    assert np.allclose(original, unchanged), "Validation targets leaked into weights"

    print("weighting tests passed")


if __name__ == "__main__":
    main()
