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
    composite_metric_tons_objective,
    fit_model,
    high_yield_area_weighted_abs_bias,
    model_target,
    partition_unified_rows,
    reconstruct_tch_predictions,
    sample_weights_for_index,
    worst_estrato_metric_tons_abs_pct_error,
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

    objective_metadata = metadata.copy()
    objective_metadata["prod_estrato"] = np.where(
        objective_metadata["cycle_id"].eq("A"),
        "ALTO",
        "MEDIO",
    )
    assert high_yield_area_weighted_abs_bias(
        y,
        prediction,
        objective_metadata,
        threshold=95.0,
    ) > 0
    assert worst_estrato_metric_tons_abs_pct_error(
        y,
        prediction,
        objective_metadata,
    ) > 0
    control_score = composite_metric_tons_objective(
        rmse=16.0,
        abs_metric_tons_pct_diff=2.0,
        aggregate_penalty=3.0,
    )
    assert control_score == 22.0
    assert composite_metric_tons_objective(
        rmse=16.0,
        abs_metric_tons_pct_diff=2.0,
        aggregate_penalty=3.0,
        high_yield_abs_bias=10.0,
        high_yield_penalty=0.0,
        worst_estrato_abs_pct_error=5.0,
        worst_estrato_penalty=0.0,
    ) == control_score

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

    residual_X = X.copy()
    residual_X["last_hist_tch"] = y.to_numpy() - 5.0
    residual_y = model_target(y, residual_X, "residual_last_hist_tch")
    assert np.allclose(residual_y.to_numpy(), 5.0)
    reconstructed = reconstruct_tch_predictions(
        residual_y.to_numpy(),
        residual_X,
        "residual_last_hist_tch",
    )
    assert np.allclose(reconstructed, y.to_numpy())
    assert np.allclose(
        reconstruct_tch_predictions(y.to_numpy(), X, "absolute"),
        y.to_numpy(),
    )
    direct_X = X.copy()
    direct_X["direct_area"] = np.linspace(1.0, 2.0, len(X))
    direct_y = model_target(y, direct_X, "direct_metric_tons")
    assert np.allclose(
        direct_y.to_numpy(),
        y.to_numpy() * direct_X["direct_area"].to_numpy(),
    )
    assert np.allclose(
        reconstruct_tch_predictions(
            direct_y.to_numpy(),
            direct_X,
            "direct_metric_tons",
        ),
        y.to_numpy(),
    )
    print("snapshot support smoke test passed")


if __name__ == "__main__":
    main()
