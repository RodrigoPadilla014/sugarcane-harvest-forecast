import numpy as np
import pandas as pd

from features import build_dataset
from metrics import (
    aggregate_zafra_metrics,
    lot_predictions,
    snapshot_day_metrics,
    zafra_metrics,
)
from train import (
    aggregate_tch_sum_pct_diff,
    fit_model,
    partition_unified_rows,
    sample_weights_for_index,
)


def main():
    rows = []
    cycles = (
        ("A", "2022_2023", 100.0, (180, 210, 240, 270, 300, 340)),
        ("B", "2022_2023", 110.0, (180, 210)),
    )
    for cycle_id, zafra, tch, snapshot_days in cycles:
        for snapshot_day in snapshot_days:
            rows.append(
                {
                    "cod_cg_zafra": f"{cycle_id}_d{snapshot_day}",
                    "cycle_id": cycle_id,
                    "cod_cg": cycle_id,
                    "zafra_norm": zafra,
                    "dataset_role": "training",
                    "has_target_tch": True,
                    "scoring_age_eligible": True,
                    "snapshot_day": snapshot_day,
                    "snapshot_weight": 1.0 / len(snapshot_days),
                    "area": 1.0,
                    "tch": tch,
                    "prediction_age_days": snapshot_day,
                    "feature_x": snapshot_day / 100.0,
                }
            )

    source = pd.DataFrame(rows)
    training, _, _, _ = partition_unified_rows(source, "tch")
    X, y, metadata = build_dataset(
        training,
        dataset_type="feature_table",
        light_features=False,
    )
    weights = sample_weights_for_index(metadata, X.index)
    cycle_by_row = metadata.set_index("cod_cg_zafra").loc[
        weights.index,
        "cycle_id",
    ]
    weight_totals = (
        pd.DataFrame({"cycle_id": cycle_by_row, "weight": weights})
        .groupby("cycle_id")["weight"]
        .sum()
    )
    assert np.allclose(weight_totals.to_numpy(), 1.0)

    prediction = y.to_numpy() + 1.0
    predictions = lot_predictions(
        metadata,
        y,
        prediction,
        split="evaluation",
    )
    by_snapshot = snapshot_day_metrics(predictions)
    assert set(by_snapshot["snapshot_day"]) == {
        180,
        210,
        240,
        270,
        300,
        340,
    }

    by_zafra = zafra_metrics(
        metadata,
        y,
        prediction,
        split="evaluation",
    )
    assert "snapshot_day" in by_zafra.columns
    aggregate = aggregate_zafra_metrics(by_zafra)
    assert len(aggregate) == 12

    aggregate_error = aggregate_tch_sum_pct_diff(
        y,
        prediction,
        metadata,
    )
    assert aggregate_error > 0

    from models import build_model

    model = build_model("catboost", {"iterations": 2, "depth": 2})
    fit_model(
        model,
        "catboost",
        X,
        y,
        categorical_mode="native",
        sample_weight=weights,
    )
    assert len(model.predict(X)) == len(X)
    print("snapshot support smoke test passed")


if __name__ == "__main__":
    main()
