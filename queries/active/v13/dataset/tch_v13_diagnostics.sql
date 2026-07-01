-- tch_v13_diagnostics.sql
--
-- Compact pre-training diagnostics for the V13 challenger dataset.
--
-- This intentionally uses the V10 temporal spine rather than the full V13
-- feature table. These checks validate population, spatial, ENSO probability,
-- and harvest timing coverage without paying for optical/radar/climate
-- feature aggregation.

WITH
base AS (
{{ include:tch_v10_productivity_snapshot_spine }}
),
spatial_latest_year AS (
    SELECT max(shape_year)::integer AS latest_shape_year
    FROM public.spatial_lot_year_slim
),
spatial_candidates AS (
    SELECT
        b.cod_cg_zafra,
        s.shape_year::integer AS spatial_shape_year_used,
        row_number() OVER (
            PARTITION BY b.cod_cg_zafra
            ORDER BY
                CASE
                    WHEN s.shape_year::integer = split_part(b.zafra_norm, '_', 1)::integer
                    THEN 0
                    WHEN b.dataset_role = 'scoring'
                     AND s.shape_year::integer <= split_part(b.zafra_norm, '_', 1)::integer
                    THEN 1
                    ELSE 2
                END,
                s.shape_year::integer DESC
        ) AS spatial_rank
    FROM base b
    LEFT JOIN public.spatial_lot_year_slim s
      ON trim(s.productivity_lot_key::text) = b.cod_cg
     AND (
            s.shape_year::integer = split_part(b.zafra_norm, '_', 1)::integer
         OR (
                b.dataset_role = 'scoring'
            AND s.shape_year::integer <= split_part(b.zafra_norm, '_', 1)::integer
            AND s.shape_year::integer = (SELECT latest_shape_year FROM spatial_latest_year)
         )
     )
),
spatial_selected AS (
    SELECT
        b.cod_cg_zafra,
        c.spatial_shape_year_used,
        CASE WHEN c.spatial_shape_year_used IS NULL THEN 0 ELSE 1 END
            AS spatial_match_flag,
        CASE
            WHEN c.spatial_shape_year_used IS NULL THEN 'unmatched'
            WHEN c.spatial_shape_year_used = split_part(b.zafra_norm, '_', 1)::integer
            THEN 'same_year'
            WHEN b.dataset_role = 'scoring' THEN 'latest_non_future_scoring'
            ELSE 'other'
        END AS spatial_fallback_strategy
    FROM base b
    LEFT JOIN spatial_candidates c
      ON c.cod_cg_zafra = b.cod_cg_zafra
     AND c.spatial_rank = 1
),
target_season_ranked AS (
    SELECT
        b.cod_cg_zafra,
        ep.target_season,
        ep.target_season_year,
        ep.forecast_issue_date::date AS forecast_issue_date,
        row_number() OVER (
            PARTITION BY b.cod_cg_zafra, ep.target_season, ep.target_season_year
            ORDER BY ep.forecast_issue_date::date DESC
        ) AS issue_rank
    FROM base b
    LEFT JOIN public.enso_probabilities_forecast ep
      ON ep.forecast_issue_date::date <= b.snapshot_date
     AND ep.target_season_year::integer BETWEEN split_part(b.zafra_norm, '_', 1)::integer
                                           AND split_part(b.zafra_norm, '_', 2)::integer
),
enso_prob AS (
    SELECT
        cod_cg_zafra,
        count(forecast_issue_date)::double precision AS enso_prob_target_season_count
    FROM target_season_ranked
    WHERE issue_rank = 1
    GROUP BY cod_cg_zafra
),
cycle_harvest AS (
    SELECT DISTINCT
        cycle_id,
        cod_cg,
        zafra_norm,
        fecha_cierre_real,
        area,
        tch
    FROM base
    WHERE dataset_role = 'training'
      AND has_target_tch
      AND fecha_cierre_real IS NOT NULL
),
realized_harvest AS (
    SELECT
        cycle_id,
        percent_rank() OVER (
            PARTITION BY zafra_norm
            ORDER BY fecha_cierre_real, cod_cg
        ) AS realized_harvest_percentile,
        CASE
            WHEN percent_rank() OVER (
                PARTITION BY zafra_norm
                ORDER BY fecha_cierre_real, cod_cg
            ) < 0.3333333333 THEN 'early'
            WHEN percent_rank() OVER (
                PARTITION BY zafra_norm
                ORDER BY fecha_cierre_real, cod_cg
            ) < 0.6666666667 THEN 'middle'
            ELSE 'late'
        END AS realized_harvest_third
    FROM cycle_harvest
),
lagged_harvest_history AS (
    SELECT
        target.cycle_id,
        count(hist.realized_harvest_percentile)::double precision
            AS harvest_timing_history_count
    FROM (
        SELECT DISTINCT cycle_id, cod_cg, zafra_norm
        FROM base
    ) target
    LEFT JOIN cycle_harvest hist_cycle
      ON hist_cycle.cod_cg = target.cod_cg
     AND hist_cycle.zafra_norm < target.zafra_norm
    LEFT JOIN realized_harvest hist
      ON hist.cycle_id = hist_cycle.cycle_id
    GROUP BY target.cycle_id
),
diagnostic_frame AS (
    SELECT
        b.*,
        ss.spatial_match_flag,
        ss.spatial_shape_year_used,
        ss.spatial_fallback_strategy,
        COALESCE(ep.enso_prob_target_season_count, 0)
            AS enso_prob_target_season_count,
        rh.realized_harvest_third,
        CASE
            WHEN lhh.harvest_timing_history_count > 0 THEN 1
            ELSE 0
        END AS has_harvest_timing_history
    FROM base b
    LEFT JOIN spatial_selected ss USING (cod_cg_zafra)
    LEFT JOIN enso_prob ep USING (cod_cg_zafra)
    LEFT JOIN realized_harvest rh USING (cycle_id)
    LEFT JOIN lagged_harvest_history lhh USING (cycle_id)
),
metrics AS (
    SELECT
        'row_count'::text AS section,
        dataset_role::text AS bucket,
        count(*)::double precision AS value
    FROM diagnostic_frame
    GROUP BY dataset_role

    UNION ALL

    SELECT
        'spatial_match_rate' AS section,
        zafra_norm AS bucket,
        avg(spatial_match_flag::double precision) AS value
    FROM diagnostic_frame
    GROUP BY zafra_norm

    UNION ALL

    SELECT
        'spatial_match_rate_by_estrato' AS section,
        zafra_norm || '|' || COALESCE(prod_estrato::text, '<missing>') AS bucket,
        avg(spatial_match_flag::double precision) AS value
    FROM diagnostic_frame
    GROUP BY zafra_norm, prod_estrato

    UNION ALL

    SELECT
        'spatial_fallback_strategy_count' AS section,
        zafra_norm || '|' || COALESCE(spatial_fallback_strategy, '<missing>') AS bucket,
        count(*)::double precision AS value
    FROM diagnostic_frame
    GROUP BY zafra_norm, spatial_fallback_strategy

    UNION ALL

    SELECT
        'enso_probability_coverage' AS section,
        zafra_norm AS bucket,
        avg((enso_prob_target_season_count > 0)::integer::double precision) AS value
    FROM diagnostic_frame
    GROUP BY zafra_norm

    UNION ALL

    SELECT
        'lagged_harvest_timing_coverage' AS section,
        zafra_norm AS bucket,
        avg(has_harvest_timing_history::double precision) AS value
    FROM diagnostic_frame
    GROUP BY zafra_norm

    UNION ALL

    SELECT
        'realized_third_tch_mean' AS section,
        zafra_norm || '|' || COALESCE(realized_harvest_third, '<missing>') AS bucket,
        avg(tch)::double precision AS value
    FROM diagnostic_frame
    WHERE dataset_role = 'training'
      AND has_target_tch
    GROUP BY zafra_norm, realized_harvest_third

    UNION ALL

    SELECT
        'scoring_rows' AS section,
        zafra_norm AS bucket,
        count(*)::double precision AS value
    FROM diagnostic_frame
    WHERE dataset_role = 'scoring'
    GROUP BY zafra_norm
)
SELECT *
FROM metrics
ORDER BY section, bucket;
