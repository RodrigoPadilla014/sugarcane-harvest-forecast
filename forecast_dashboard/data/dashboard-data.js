window.DASHBOARD_LATEST = {
  "current_run_id": "v10-residual-catboost-hist125-2026-06-23"
};

window.DASHBOARD_RUNS = {
  "runs": [
    {
      "id": "v10-residual-catboost-hist125-2026-06-23",
      "label": "Oficial: V10 CatBoost residual",
      "updated_at": "2026-06-23",
      "status": "Forecast oficial",
      "target_zafra": "2026_2027",
      "model": "V10 residual CatBoost, ponderaci\u00c3\u00b3n hist\u00c3\u00b3rica TCH 1.25",
      "model_role": "Forecast oficial",
      "forecast": {
        "predicted_metric_tons": 2147415.1447043745,
        "area_sum": 19020.55,
        "predicted_tch_mean": 110.3852369178497,
        "predicted_area_weighted_tch": 112.89973973961713,
        "p10_metric_tons": 1996312.5913089556,
        "p50_metric_tons": 2142648.299407044,
        "p90_metric_tons": 2318532.979436878
      },
      "coverage": {
        "eligible_lots": 1050,
        "pending_lots": 7614,
        "total_candidate_lots": 8664,
        "coverage_note": "Cobertura por conteo de lotes: lotes con predicci\u00c3\u00b3n actual sobre candidatos esperados. El \u00c3\u00a1rea total futura completa no est\u00c3\u00a1 en este archivo."
      },
      "history": [
        {
          "date": "2026-06-23",
          "label": "Jun 23",
          "model_id": "v10-residual-catboost-hist125-2026-06-23",
          "model_label": "Oficial: V10 CatBoost residual",
          "status": "Forecast oficial",
          "active": true,
          "eligible_lots": 1050,
          "area": 19020.55,
          "predicted_metric_tons": 2147415.1447043745,
          "p10_metric_tons": 1996312.5913089556,
          "p50_metric_tons": 2142648.299407044,
          "p90_metric_tons": 2318532.979436878,
          "predicted_area_weighted_tch": 112.89973973961713,
          "predicted_tch_mean": 110.3852369178497,
          "note": "Modelo actual en prueba real."
        }
      ],
      "walk_forward_errors": [
        {
          "zafra": "2021_2022",
          "abs_error_pct": 2.21241014231468
        },
        {
          "zafra": "2022_2023",
          "abs_error_pct": 2.6072597327545
        },
        {
          "zafra": "2023_2024",
          "abs_error_pct": 0.7865884568680301
        }
      ],
      "external_snapshot_errors": [
        {
          "snapshot_day": 180,
          "error_pct": -1.19057202585009
        },
        {
          "snapshot_day": 210,
          "error_pct": -0.93449293367205
        },
        {
          "snapshot_day": 240,
          "error_pct": -0.60649846357814
        },
        {
          "snapshot_day": 270,
          "error_pct": -0.37159446636076
        },
        {
          "snapshot_day": 300,
          "error_pct": -0.16935263689336
        },
        {
          "snapshot_day": 340,
          "error_pct": -0.16860834831746
        }
      ],
      "top_drivers": [
        {
          "label": "TCH hist\u00c3\u00b3rico anterior",
          "importance": 1.0
        },
        {
          "label": "Estrato hist\u00c3\u00b3rico/anterior",
          "importance": 0.72
        },
        {
          "label": "No. corte",
          "importance": 0.61
        },
        {
          "label": "Variedad",
          "importance": 0.55
        },
        {
          "label": "Grupo / familia de suelo",
          "importance": 0.49
        },
        {
          "label": "ZAE / humedad",
          "importance": 0.43
        },
        {
          "label": "D\u00c3\u00ada de snapshot",
          "importance": 0.35
        },
        {
          "label": "Clima / ENSO",
          "importance": 0.22
        }
      ],
      "testing_note": "Modelo promovido para uso operativo. Los dem\u00c3\u00a1s modelos se guardan como shadow para comparaci\u00c3\u00b3n real cuando llegue TCH observado.",
      "volume_trend": [
        {
          "zafra": "2021_2022",
          "label": "2021-2022",
          "kind": "actual_history_current_area",
          "metric_tons": 2014634.6830394915,
          "weighted_tch": 105.91884477785824,
          "source_area": 162314.15,
          "source_actual_metric_tons": 17192127.259099998
        },
        {
          "zafra": "2022_2023",
          "label": "2022-2023",
          "kind": "actual_history_current_area",
          "metric_tons": 1933231.4880887098,
          "weighted_tch": 101.63909498351572,
          "source_area": 163762.09999999998,
          "source_actual_metric_tons": 16644631.6366
        },
        {
          "zafra": "2023_2024",
          "label": "2023-2024",
          "kind": "actual_history_current_area",
          "metric_tons": 2008015.4441865138,
          "weighted_tch": 105.57084018004284,
          "source_area": 160948.36,
          "source_actual_metric_tons": 16991453.5908
        },
        {
          "zafra": "2024_2025",
          "label": "2024-2025",
          "kind": "actual_history_current_area",
          "metric_tons": 1992487.1793213657,
          "weighted_tch": 104.75444607655224,
          "source_area": 158629.22999999998,
          "source_actual_metric_tons": 16617117.1202
        },
        {
          "zafra": "2025_2026",
          "label": "2025-2026",
          "kind": "actual_history_current_area",
          "metric_tons": 2080982.402074981,
          "weighted_tch": 109.4070572131185,
          "source_area": 149930.2402,
          "source_actual_metric_tons": 16403426.367538
        },
        {
          "zafra": "2026_2027",
          "label": "2026-2027",
          "kind": "model_prediction",
          "metric_tons": 2147415.1447043745,
          "weighted_tch": 112.89973973961713,
          "source_area": 19020.55,
          "source_actual_metric_tons": null
        }
      ],
      "volume_trend_note": "Hist\u00c3\u00b3rico: TCH real ponderado por \u00c3\u00a1rea, convertido al \u00c3\u00a1rea elegible actual para comparar tendencia. \u00c3\u009altimo punto: predicci\u00c3\u00b3n del modelo seleccionado.",
      "uncertainty": {
        "native_asymmetric": {
          "available": true,
          "label": "P10\u00e2\u0080\u0093P90 nativo del modelo CatBoost",
          "lower_tm": 1996312.5913089556,
          "center_tm": 2142648.299407044,
          "upper_tm": 2318532.979436878,
          "coverage_note": "Auditor\u00c3\u00ada hist\u00c3\u00b3rica: subcobertura; usar como se\u00c3\u00b1al direccional, no como garant\u00c3\u00ada."
        },
        "practical_plus_minus": {
          "available": true,
          "label": "Rango pr\u00c3\u00a1ctico calibrado, agregado",
          "center_tm": 2147415.1447043745,
          "lower_tm": 2063918.819428547,
          "upper_tm": 2230911.180571453,
          "margin_tch": 4.389787917355335,
          "lot_range_note": "Lote t\u00c3\u00adpico: P50 \u00c2\u00b120 TCH para ~80% de cobertura emp\u00c3\u00adrica; colas altas/bajas siguen siendo m\u00c3\u00a1s inciertas.",
          "plus_minus_tm": 83496.32527582743
        },
        "directional": {
          "decline_5_unlikely_lots": 14,
          "increase_likely_lots": 5,
          "material_decline_very_likely_lots": 6,
          "uncertain_lots": 1025,
          "high_uncertainty_lots": 286,
          "high_uncertainty_area_pct": 30.219157700487102
        }
      }
    },
    {
      "id": "shadow-lightgbm-residual-2026-06-23",
      "label": "Shadow: LightGBM residual",
      "updated_at": "2026-06-23",
      "status": "Shadow test",
      "target_zafra": "2026_2027",
      "model": "Residual LightGBM con la misma poblaci\u00c3\u00b3n y ponderaci\u00c3\u00b3n hist\u00c3\u00b3rica TCH 1.25",
      "model_role": "Shadow test",
      "forecast": {
        "predicted_metric_tons": 2150402.498721768,
        "area_sum": 19020.55,
        "predicted_tch_mean": 109.71667899555455,
        "predicted_area_weighted_tch": 113.05679902640924
      },
      "coverage": {
        "eligible_lots": 1050,
        "pending_lots": 7614,
        "total_candidate_lots": 8664,
        "coverage_note": "Cobertura por conteo de lotes: lotes con predicci\u00c3\u00b3n actual sobre candidatos esperados. El \u00c3\u00a1rea total futura completa no est\u00c3\u00a1 en este archivo."
      },
      "history": [
        {
          "date": "2026-06-23",
          "label": "Jun 23",
          "model_id": "shadow-lightgbm-residual-2026-06-23",
          "model_label": "Shadow: LightGBM residual",
          "status": "Shadow test",
          "active": true,
          "eligible_lots": 1050,
          "area": 19020.55,
          "predicted_metric_tons": 2150402.498721768,
          "p10_metric_tons": null,
          "p50_metric_tons": null,
          "p90_metric_tons": null,
          "predicted_area_weighted_tch": 113.05679902640924,
          "predicted_tch_mean": 109.71667899555455,
          "note": "Modelo actual en prueba real."
        }
      ],
      "walk_forward_errors": [
        {
          "zafra": "2021_2022",
          "abs_error_pct": 3.49786184635602
        },
        {
          "zafra": "2022_2023",
          "abs_error_pct": 2.6724649679845203
        },
        {
          "zafra": "2023_2024",
          "abs_error_pct": 0.30132336786749
        }
      ],
      "external_snapshot_errors": [
        {
          "snapshot_day": 180,
          "error_pct": -1.19057202585009
        },
        {
          "snapshot_day": 210,
          "error_pct": -0.93449293367205
        },
        {
          "snapshot_day": 240,
          "error_pct": -0.60649846357814
        },
        {
          "snapshot_day": 270,
          "error_pct": -0.37159446636076
        },
        {
          "snapshot_day": 300,
          "error_pct": -0.16935263689336
        },
        {
          "snapshot_day": 340,
          "error_pct": -0.16860834831746
        }
      ],
      "top_drivers": [],
      "testing_note": "Challenger no promovido. Se monitorea en silencio para saber si en vida real supera al oficial.",
      "volume_trend": [
        {
          "zafra": "2021_2022",
          "label": "2021-2022",
          "kind": "actual_history_current_area",
          "metric_tons": 2014634.6830394915,
          "weighted_tch": 105.91884477785824,
          "source_area": 162314.15,
          "source_actual_metric_tons": 17192127.259099998
        },
        {
          "zafra": "2022_2023",
          "label": "2022-2023",
          "kind": "actual_history_current_area",
          "metric_tons": 1933231.4880887098,
          "weighted_tch": 101.63909498351572,
          "source_area": 163762.09999999998,
          "source_actual_metric_tons": 16644631.6366
        },
        {
          "zafra": "2023_2024",
          "label": "2023-2024",
          "kind": "actual_history_current_area",
          "metric_tons": 2008015.4441865138,
          "weighted_tch": 105.57084018004284,
          "source_area": 160948.36,
          "source_actual_metric_tons": 16991453.5908
        },
        {
          "zafra": "2024_2025",
          "label": "2024-2025",
          "kind": "actual_history_current_area",
          "metric_tons": 1992487.1793213657,
          "weighted_tch": 104.75444607655224,
          "source_area": 158629.22999999998,
          "source_actual_metric_tons": 16617117.1202
        },
        {
          "zafra": "2025_2026",
          "label": "2025-2026",
          "kind": "actual_history_current_area",
          "metric_tons": 2080982.402074981,
          "weighted_tch": 109.4070572131185,
          "source_area": 149930.2402,
          "source_actual_metric_tons": 16403426.367538
        },
        {
          "zafra": "2026_2027",
          "label": "2026-2027",
          "kind": "model_prediction",
          "metric_tons": 2150402.498721768,
          "weighted_tch": 113.05679902640924,
          "source_area": 19020.55,
          "source_actual_metric_tons": null
        }
      ],
      "volume_trend_note": "Hist\u00c3\u00b3rico: TCH real ponderado por \u00c3\u00a1rea, convertido al \u00c3\u00a1rea elegible actual para comparar tendencia. \u00c3\u009altimo punto: predicci\u00c3\u00b3n del modelo seleccionado.",
      "uncertainty": {
        "native_asymmetric": {
          "available": false,
          "label": "P10\u00e2\u0080\u0093P90 nativo del modelo CatBoost",
          "lower_tm": null,
          "center_tm": null,
          "upper_tm": null,
          "coverage_note": "No disponible para este modelo shadow."
        },
        "practical_plus_minus": {
          "available": false,
          "label": "Rango pr\u00c3\u00a1ctico calibrado, agregado",
          "center_tm": 2150402.498721768,
          "lower_tm": null,
          "upper_tm": null,
          "margin_tch": null,
          "lot_range_note": "No calibrado para este modelo shadow."
        },
        "directional": {
          "decline_5_unlikely_lots": 14,
          "increase_likely_lots": 5,
          "material_decline_very_likely_lots": 6,
          "uncertain_lots": 1025,
          "high_uncertainty_lots": 286,
          "high_uncertainty_area_pct": 30.219157700487102
        }
      }
    },
    {
      "id": "shadow-simple-average-2026-06-23",
      "label": "Shadow: promedio CatBoost + LightGBM",
      "updated_at": "2026-06-23",
      "status": "Shadow blend",
      "target_zafra": "2026_2027",
      "model": "Promedio simple 50/50 entre CatBoost oficial y LightGBM residual",
      "model_role": "Shadow blend",
      "forecast": {
        "predicted_metric_tons": 2148908.8217130713,
        "area_sum": 19020.55,
        "predicted_tch_mean": 110.05095795670213,
        "predicted_area_weighted_tch": 112.97826938301318
      },
      "coverage": {
        "eligible_lots": 1050,
        "pending_lots": 7614,
        "total_candidate_lots": 8664,
        "coverage_note": "Cobertura por conteo de lotes: lotes con predicci\u00c3\u00b3n actual sobre candidatos esperados. El \u00c3\u00a1rea total futura completa no est\u00c3\u00a1 en este archivo."
      },
      "history": [
        {
          "date": "2026-06-23",
          "label": "Jun 23",
          "model_id": "shadow-simple-average-2026-06-23",
          "model_label": "Shadow: promedio CatBoost + LightGBM",
          "status": "Shadow blend",
          "active": true,
          "eligible_lots": 1050,
          "area": 19020.55,
          "predicted_metric_tons": 2148908.8217130713,
          "p10_metric_tons": null,
          "p50_metric_tons": null,
          "p90_metric_tons": null,
          "predicted_area_weighted_tch": 112.97826938301318,
          "predicted_tch_mean": 110.05095795670213,
          "note": "Modelo actual en prueba real."
        }
      ],
      "walk_forward_errors": [
        {
          "zafra": "2021_2022",
          "abs_error_pct": 2.21241014231468
        },
        {
          "zafra": "2022_2023",
          "abs_error_pct": 2.6072597327545
        },
        {
          "zafra": "2023_2024",
          "abs_error_pct": 0.7865884568680301
        }
      ],
      "external_snapshot_errors": [
        {
          "snapshot_day": 180,
          "error_pct": -1.19057202585009
        },
        {
          "snapshot_day": 210,
          "error_pct": -0.93449293367205
        },
        {
          "snapshot_day": 240,
          "error_pct": -0.60649846357814
        },
        {
          "snapshot_day": 270,
          "error_pct": -0.37159446636076
        },
        {
          "snapshot_day": 300,
          "error_pct": -0.16935263689336
        },
        {
          "snapshot_day": 340,
          "error_pct": -0.16860834831746
        }
      ],
      "top_drivers": [],
      "testing_note": "Blend experimental. La selecci\u00c3\u00b3n hist\u00c3\u00b3rica prefiri\u00c3\u00b3 100% CatBoost; este promedio se mantiene solo como prueba de diversidad.",
      "volume_trend": [
        {
          "zafra": "2021_2022",
          "label": "2021-2022",
          "kind": "actual_history_current_area",
          "metric_tons": 2014634.6830394915,
          "weighted_tch": 105.91884477785824,
          "source_area": 162314.15,
          "source_actual_metric_tons": 17192127.259099998
        },
        {
          "zafra": "2022_2023",
          "label": "2022-2023",
          "kind": "actual_history_current_area",
          "metric_tons": 1933231.4880887098,
          "weighted_tch": 101.63909498351572,
          "source_area": 163762.09999999998,
          "source_actual_metric_tons": 16644631.6366
        },
        {
          "zafra": "2023_2024",
          "label": "2023-2024",
          "kind": "actual_history_current_area",
          "metric_tons": 2008015.4441865138,
          "weighted_tch": 105.57084018004284,
          "source_area": 160948.36,
          "source_actual_metric_tons": 16991453.5908
        },
        {
          "zafra": "2024_2025",
          "label": "2024-2025",
          "kind": "actual_history_current_area",
          "metric_tons": 1992487.1793213657,
          "weighted_tch": 104.75444607655224,
          "source_area": 158629.22999999998,
          "source_actual_metric_tons": 16617117.1202
        },
        {
          "zafra": "2025_2026",
          "label": "2025-2026",
          "kind": "actual_history_current_area",
          "metric_tons": 2080982.402074981,
          "weighted_tch": 109.4070572131185,
          "source_area": 149930.2402,
          "source_actual_metric_tons": 16403426.367538
        },
        {
          "zafra": "2026_2027",
          "label": "2026-2027",
          "kind": "model_prediction",
          "metric_tons": 2148908.8217130713,
          "weighted_tch": 112.97826938301318,
          "source_area": 19020.55,
          "source_actual_metric_tons": null
        }
      ],
      "volume_trend_note": "Hist\u00c3\u00b3rico: TCH real ponderado por \u00c3\u00a1rea, convertido al \u00c3\u00a1rea elegible actual para comparar tendencia. \u00c3\u009altimo punto: predicci\u00c3\u00b3n del modelo seleccionado.",
      "uncertainty": {
        "native_asymmetric": {
          "available": false,
          "label": "P10\u00e2\u0080\u0093P90 nativo del modelo CatBoost",
          "lower_tm": null,
          "center_tm": null,
          "upper_tm": null,
          "coverage_note": "No disponible para este modelo shadow."
        },
        "practical_plus_minus": {
          "available": false,
          "label": "Rango pr\u00c3\u00a1ctico calibrado, agregado",
          "center_tm": 2148908.8217130713,
          "lower_tm": null,
          "upper_tm": null,
          "margin_tch": null,
          "lot_range_note": "No calibrado para este modelo shadow."
        },
        "directional": {
          "decline_5_unlikely_lots": 14,
          "increase_likely_lots": 5,
          "material_decline_very_likely_lots": 6,
          "uncertain_lots": 1025,
          "high_uncertainty_lots": 286,
          "high_uncertainty_area_pct": 30.219157700487102
        }
      }
    }
  ],
  "forecast_snapshots": [
    {
      "date": "2026-06-12",
      "label": "Jun 12",
      "model_id": "archived-v9-baseline-2026-06-12",
      "model_label": "V9 l\u00c3\u00adnea base",
      "status": "Discontinuado",
      "active": false,
      "eligible_lots": 909,
      "area": 16771.559999999998,
      "predicted_metric_tons": 1803523.809989045,
      "p10_metric_tons": 1506069.9548004216,
      "p50_metric_tons": 1815709.7428473877,
      "p90_metric_tons": 2122518.8326717746,
      "predicted_area_weighted_tch": 107.53464853532081,
      "predicted_tch_mean": 104.73972292695377,
      "note": "Snapshot hist\u00c3\u00b3rico discontinuado; se conserva para auditor\u00c3\u00ada."
    },
    {
      "date": "2026-06-15",
      "label": "Jun 15",
      "model_id": "archived-v9-optuna-p05-2026-06-15",
      "model_label": "V9 Optuna 0.5",
      "status": "Discontinuado",
      "active": false,
      "eligible_lots": 909,
      "area": 16771.559999999998,
      "predicted_metric_tons": 1819670.2391174696,
      "p10_metric_tons": 1507512.7164324922,
      "p50_metric_tons": 1826769.172277932,
      "p90_metric_tons": 2101965.2697675065,
      "predicted_area_weighted_tch": 108.49737526607363,
      "predicted_tch_mean": 105.53680752890055,
      "note": "Snapshot hist\u00c3\u00b3rico discontinuado; se conserva para auditor\u00c3\u00ada."
    },
    {
      "date": "2026-06-23",
      "label": "Jun 23",
      "model_id": "v10-residual-catboost-hist125-2026-06-23",
      "model_label": "Oficial: V10 CatBoost residual",
      "status": "Forecast oficial",
      "active": true,
      "eligible_lots": 1050,
      "area": 19020.55,
      "predicted_metric_tons": 2147415.1447043745,
      "p10_metric_tons": 1996312.5913089556,
      "p50_metric_tons": 2142648.299407044,
      "p90_metric_tons": 2318532.979436878,
      "predicted_area_weighted_tch": 112.89973973961713,
      "predicted_tch_mean": 110.3852369178497,
      "note": "Modelo actual en prueba real."
    },
    {
      "date": "2026-06-23",
      "label": "Jun 23",
      "model_id": "shadow-lightgbm-residual-2026-06-23",
      "model_label": "Shadow: LightGBM residual",
      "status": "Shadow test",
      "active": true,
      "eligible_lots": 1050,
      "area": 19020.55,
      "predicted_metric_tons": 2150402.498721768,
      "p10_metric_tons": null,
      "p50_metric_tons": null,
      "p90_metric_tons": null,
      "predicted_area_weighted_tch": 113.05679902640924,
      "predicted_tch_mean": 109.71667899555455,
      "note": "Modelo actual en prueba real."
    },
    {
      "date": "2026-06-23",
      "label": "Jun 23",
      "model_id": "shadow-simple-average-2026-06-23",
      "model_label": "Shadow: promedio CatBoost + LightGBM",
      "status": "Shadow blend",
      "active": true,
      "eligible_lots": 1050,
      "area": 19020.55,
      "predicted_metric_tons": 2148908.8217130713,
      "p10_metric_tons": null,
      "p50_metric_tons": null,
      "p90_metric_tons": null,
      "predicted_area_weighted_tch": 112.97826938301318,
      "predicted_tch_mean": 110.05095795670213,
      "note": "Modelo actual en prueba real."
    }
  ],
  "dashboard_notes": {
    "language": "es",
    "v9_policy": "V9 se conserva como snapshot hist\u00c3\u00b3rico discontinuado; no aparece como modelo activo.",
    "trend_caveat": "La tendencia hist\u00c3\u00b3rica usa TCH ponderado convertido al \u00c3\u00a1rea elegible actual para evitar comparar \u00c3\u00a1reas hist\u00c3\u00b3ricas completas contra cobertura parcial actual.",
    "coverage_policy": "La cobertura se calcula como lotes elegibles con predicci\u00c3\u00b3n actual / 8,664 candidatos esperados; no como porcentaje del archivo de scoring.",
    "trend_policy": "La tendencia hist\u00c3\u00b3rica se muestra como TCH ponderado por \u00c3\u00a1rea, no como TM, para evitar comparar a\u00c3\u00b1os completos contra una predicci\u00c3\u00b3n parcial."
  }
};
