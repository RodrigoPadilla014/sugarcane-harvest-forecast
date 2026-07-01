-- tch_features_v13_spatial_enso_harvest.sql
--
-- V13 challenger feature table.
--
-- The V13 dataset starts from the V10 production feature table and adds:
--   * compact lot/year spatial features;
--   * leakage-safe ENSO probability forecast features;
--   * lagged expected harvest timing features;
--   * realized harvest timing fields for diagnostics only.
--
-- Do not use realized current-zafra harvest timing as model input.

WITH
base AS (
{{ include:tch_features_v10_productivity_history_snapshots }}
),
spatial_latest_year AS (
    SELECT max(shape_year)::integer AS latest_shape_year
    FROM public.spatial_lot_year_slim
),
spatial_candidates AS (
    SELECT
        b.cod_cg_zafra,
        s.shape_year::integer AS spatial_shape_year_used,
        s.centroid_lon::double precision AS centroid_lon,
        s.centroid_lat::double precision AS centroid_lat,
        s.area_ha::double precision AS spatial_area_ha,
        s.area_ha_dissolved::double precision AS spatial_area_ha_dissolved,
        s.perimeter_m::double precision AS spatial_perimeter_m,
        s.perimeter_m_dissolved::double precision AS spatial_perimeter_m_dissolved,
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
        c.centroid_lon,
        c.centroid_lat,
        c.spatial_area_ha,
        c.spatial_area_ha_dissolved,
        c.spatial_perimeter_m,
        c.spatial_perimeter_m_dissolved,
        CASE WHEN c.spatial_shape_year_used IS NULL THEN 0 ELSE 1 END
            AS spatial_match_flag,
        CASE
            WHEN c.spatial_shape_year_used IS NULL THEN NULL
            ELSE c.spatial_shape_year_used - split_part(b.zafra_norm, '_', 1)::integer
        END AS spatial_year_gap,
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
spatial_previous AS (
    SELECT
        ss.cod_cg_zafra,
        p.shape_year::integer AS spatial_previous_shape_year,
        p.area_ha_dissolved::double precision AS spatial_previous_area_ha_dissolved,
        p.centroid_lon::double precision AS spatial_previous_centroid_lon,
        p.centroid_lat::double precision AS spatial_previous_centroid_lat,
        row_number() OVER (
            PARTITION BY ss.cod_cg_zafra
            ORDER BY p.shape_year::integer DESC
        ) AS previous_rank
    FROM spatial_selected ss
    JOIN base b
      ON b.cod_cg_zafra = ss.cod_cg_zafra
    LEFT JOIN public.spatial_lot_year_slim p
      ON trim(p.productivity_lot_key::text) = b.cod_cg
     AND p.shape_year::integer < ss.spatial_shape_year_used
),
spatial_features AS (
    SELECT
        ss.*,
        CASE
            WHEN ss.spatial_area_ha_dissolved > 0
             AND ss.spatial_perimeter_m_dissolved > 0
            THEN
                4.0 * pi() * (ss.spatial_area_ha_dissolved * 10000.0)
                / (ss.spatial_perimeter_m_dissolved * ss.spatial_perimeter_m_dissolved)
        END AS spatial_compactness,
        CASE
            WHEN ss.spatial_area_ha_dissolved > 0
            THEN ss.spatial_perimeter_m_dissolved / ss.spatial_area_ha_dissolved
        END AS spatial_perimeter_area_ratio,
        ln(NULLIF(ss.spatial_area_ha_dissolved, 0)) AS spatial_area_log,
        ss.spatial_area_ha_dissolved - p.spatial_previous_area_ha_dissolved
            AS spatial_area_change_prev_available,
        ss.spatial_area_ha_dissolved / NULLIF(p.spatial_previous_area_ha_dissolved, 0)
            AS spatial_area_ratio_prev_available,
        sqrt(
            power((ss.centroid_lon - p.spatial_previous_centroid_lon) * 111320.0, 2)
            + power((ss.centroid_lat - p.spatial_previous_centroid_lat) * 110540.0, 2)
        ) AS spatial_centroid_shift_prev_available,
        CASE WHEN p.spatial_previous_shape_year IS NULL THEN 0 ELSE 1 END
            AS spatial_has_previous_shape
    FROM spatial_selected ss
    LEFT JOIN spatial_previous p
      ON p.cod_cg_zafra = ss.cod_cg_zafra
     AND p.previous_rank = 1
),
target_season_ranked AS (
    SELECT
        b.cod_cg_zafra,
        ep.target_season,
        ep.target_season_year,
        ep.la_nina_pct::double precision AS la_nina_pct,
        ep.neutral_pct::double precision AS neutral_pct,
        ep.el_nino_pct::double precision AS el_nino_pct,
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
        count(forecast_issue_date)::double precision AS enso_prob_target_season_count,
        max(forecast_issue_date) AS enso_prob_latest_issue_date,
        avg(la_nina_pct) AS enso_prob_la_nina_mean,
        avg(neutral_pct) AS enso_prob_neutral_mean,
        avg(el_nino_pct) AS enso_prob_el_nino_mean,
        max(greatest(la_nina_pct, neutral_pct, el_nino_pct))
            AS enso_prob_max_class_probability,
        avg(
            CASE
                WHEN la_nina_pct > 0 THEN -(la_nina_pct / 100.0) * ln(la_nina_pct / 100.0)
                ELSE 0
            END
            + CASE
                WHEN neutral_pct > 0 THEN -(neutral_pct / 100.0) * ln(neutral_pct / 100.0)
                ELSE 0
            END
            + CASE
                WHEN el_nino_pct > 0 THEN -(el_nino_pct / 100.0) * ln(el_nino_pct / 100.0)
                ELSE 0
            END
        ) AS enso_prob_entropy_mean,
        avg(el_nino_pct) FILTER (
            WHERE target_season IN ('MAM', 'AMJ', 'MJJ', 'JJA')
        ) AS enso_prob_el_nino_early_mid_mean,
        avg(la_nina_pct) FILTER (
            WHERE target_season IN ('MAM', 'AMJ', 'MJJ', 'JJA')
        ) AS enso_prob_la_nina_early_mid_mean
    FROM target_season_ranked
    WHERE issue_rank = 1
    GROUP BY cod_cg_zafra
),
enso_prob_class AS (
    SELECT
        *,
        CASE
            WHEN enso_prob_el_nino_mean >= enso_prob_neutral_mean
             AND enso_prob_el_nino_mean >= enso_prob_la_nina_mean THEN 'nino'
            WHEN enso_prob_la_nina_mean >= enso_prob_neutral_mean
             AND enso_prob_la_nina_mean >= enso_prob_el_nino_mean THEN 'nina'
            WHEN enso_prob_neutral_mean IS NOT NULL THEN 'neutral'
            ELSE 'missing'
        END AS enso_prob_most_likely_class
    FROM enso_prob
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
        avg(hist.realized_harvest_percentile) AS expected_harvest_percentile_lagged,
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
harvest_features AS (
    SELECT
        b.cod_cg_zafra,
        r.realized_harvest_percentile,
        r.realized_harvest_third,
        h.expected_harvest_percentile_lagged,
        CASE
            WHEN h.expected_harvest_percentile_lagged IS NULL THEN 'missing'
            WHEN h.expected_harvest_percentile_lagged < 0.3333333333 THEN 'early'
            WHEN h.expected_harvest_percentile_lagged < 0.6666666667 THEN 'middle'
            ELSE 'late'
        END AS expected_harvest_third_lagged,
        CASE WHEN h.harvest_timing_history_count > 0 THEN 1 ELSE 0 END
            AS has_harvest_timing_history,
        h.harvest_timing_history_count
    FROM base b
    LEFT JOIN realized_harvest r
      ON r.cycle_id = b.cycle_id
    LEFT JOIN lagged_harvest_history h
      ON h.cycle_id = b.cycle_id
)
SELECT
    b.*,
    sf.spatial_match_flag,
    sf.spatial_shape_year_used,
    sf.spatial_year_gap,
    sf.spatial_fallback_strategy,
    sf.centroid_lon,
    sf.centroid_lat,
    sf.spatial_area_ha,
    sf.spatial_area_ha_dissolved,
    sf.spatial_perimeter_m,
    sf.spatial_perimeter_m_dissolved,
    sf.spatial_compactness,
    sf.spatial_perimeter_area_ratio,
    sf.spatial_area_log,
    sf.spatial_area_change_prev_available,
    sf.spatial_area_ratio_prev_available,
    sf.spatial_centroid_shift_prev_available,
    sf.spatial_has_previous_shape,
    ep.enso_prob_target_season_count,
    ep.enso_prob_latest_issue_date,
    ep.enso_prob_la_nina_mean,
    ep.enso_prob_neutral_mean,
    ep.enso_prob_el_nino_mean,
    ep.enso_prob_max_class_probability,
    ep.enso_prob_entropy_mean,
    ep.enso_prob_el_nino_early_mid_mean,
    ep.enso_prob_la_nina_early_mid_mean,
    ep.enso_prob_most_likely_class,
    hf.realized_harvest_percentile,
    hf.realized_harvest_third,
    hf.expected_harvest_percentile_lagged,
    hf.expected_harvest_third_lagged,
    hf.has_harvest_timing_history,
    hf.harvest_timing_history_count
FROM base b
LEFT JOIN spatial_features sf USING (cod_cg_zafra)
LEFT JOIN enso_prob_class ep USING (cod_cg_zafra)
LEFT JOIN harvest_features hf USING (cod_cg_zafra);
