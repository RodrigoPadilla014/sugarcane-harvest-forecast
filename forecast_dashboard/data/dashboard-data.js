window.DASHBOARD_LATEST = {
  current_run_id: "v9-optuna-p05-2026-06-15",
};

window.DASHBOARD_RUNS = {
  runs: [
    {
      id: "v9-baseline-2026-06-12",
      label: "V9 línea base",
      updated_at: "2026-06-12",
      status: "Predicción parcial",
      target_zafra: "2026_2027",
      model: "CatBoost línea base, snapshots dinámicos",
      forecast: {
        predicted_aggregate_tch_sum: 95208.41,
        p10_sum: 78864.9,
        p90_sum: 112641.97,
      },
      coverage: {
        eligible_lots: 909,
        pending_lots: 7755,
        total_candidate_lots: 8664,
      },
      history: [
        {
          label: "Jun 12",
          eligible_lots: 909,
          predicted_aggregate_tch_sum: 95208.41,
          p10_sum: 78864.9,
          p90_sum: 112641.97,
        },
      ],
      walk_forward_errors: [
        { zafra: "2021_2022", abs_error_pct: 4.35 },
        { zafra: "2022_2023", abs_error_pct: 1.94 },
        { zafra: "2023_2024", abs_error_pct: 7.47 },
        { zafra: "2024_2025", abs_error_pct: 2.1 },
      ],
      external_snapshot_errors: [
        { snapshot_day: 180, error_pct: -2.1 },
        { snapshot_day: 210, error_pct: -0.94 },
        { snapshot_day: 240, error_pct: -0.53 },
        { snapshot_day: 270, error_pct: 0.34 },
        { snapshot_day: 300, error_pct: 1.01 },
        { snapshot_day: 340, error_pct: 1.59 },
      ],
      top_drivers: [
        { label: "Promedio NDRE", importance: 4.57 },
        { label: "Promedio NDVI", importance: 3.98 },
        { label: "ZAE", importance: 3.0 },
        { label: "Ingenio", importance: 2.67 },
        { label: "Pendiente NDRE", importance: 2.54 },
        { label: "No. corte", importance: 2.0 },
        { label: "Radar RVI 91-180", importance: 1.83 },
        { label: "Promedio LSWI", importance: 1.78 },
      ],
    },
    {
      id: "v9-optuna-p05-2026-06-15",
      label: "V9 Optuna 0.5",
      updated_at: "2026-06-15",
      status: "Predicción parcial",
      target_zafra: "2026_2027",
      model: "CatBoost Optuna, penalización agregada 0.5",
      forecast: {
        predicted_aggregate_tch_sum: 95932.96,
        p10_sum: 79005.99,
        p90_sum: 111394.24,
      },
      coverage: {
        eligible_lots: 909,
        pending_lots: 7755,
        total_candidate_lots: 8664,
      },
      history: [
        {
          label: "Jun 12",
          eligible_lots: 909,
          predicted_aggregate_tch_sum: 95208.41,
          p10_sum: 78864.9,
          p90_sum: 112641.97,
        },
        {
          label: "Jun 15",
          eligible_lots: 909,
          predicted_aggregate_tch_sum: 95932.96,
          p10_sum: 79005.99,
          p90_sum: 111394.24,
        },
      ],
      walk_forward_errors: [
        { zafra: "2021_2022", abs_error_pct: 1.36 },
        { zafra: "2022_2023", abs_error_pct: 1.01 },
        { zafra: "2023_2024", abs_error_pct: 5.61 },
        { zafra: "2024_2025", abs_error_pct: 1.21 },
      ],
      external_snapshot_errors: [
        { snapshot_day: 180, error_pct: -0.53 },
        { snapshot_day: 210, error_pct: -0.14 },
        { snapshot_day: 240, error_pct: 0.1 },
        { snapshot_day: 270, error_pct: 0.27 },
        { snapshot_day: 300, error_pct: 0.47 },
        { snapshot_day: 340, error_pct: 0.24 },
      ],
      top_drivers: [
        { label: "ZAE", importance: 2.9 },
        { label: "Ingenio", importance: 2.28 },
        { label: "No. corte", importance: 2.05 },
        { label: "Pico NDVI", importance: 2.0 },
        { label: "Radar RVI 91-180", importance: 1.94 },
        { label: "Variedad", importance: 1.74 },
        { label: "Familia de suelo", importance: 1.72 },
        { label: "Promedio NDRE", importance: 1.17 },
      ],
    },
  ],
};
