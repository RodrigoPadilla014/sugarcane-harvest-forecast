-- tch_radar_core_v4.sql
--
-- Radar/SAR core feature block for the pseudo-sequential/tabular TCH strategy.
--
-- Shape:
--   one row per valid cod_cg_zafra
--
-- Intent:
--   Preserve compact SAR structure/moisture signal without expanding every
--   radar derivative. Core metrics are VH, VV, and VV/VH ratio for ASC/DESC.
--
-- Source rules:
--   - public.tch_raw_longitudinal_v4 supplies validated cycle bounds, target,
--     model metadata, and nearest ASC/DESC radar observations already aligned
--     to the optical observation spine.
--
-- Usage:
--   This is a reusable feature block, not the final training table. Join later
--   to other source blocks by cod_cg_zafra.

WITH base_cycles AS (
    SELECT
        r.cod_cg_zafra,
        max(r.cod_cg) AS cod_cg,
        max(r.zafra_norm) AS zafra_norm,
        max(r.area)::double precision AS area,
        max(r.tch)::double precision AS tch,
        max(r.tc)::double precision AS tc,
        min(r.fecha_inicio_estimada)::date AS fecha_inicio_ciclo,
        max(r.fecha_fin_objetivo)::date AS fecha_fin_ciclo,
        max(r.edad_de_cultivo)::double precision AS cycle_age_max,
        count(*) AS radar_spine_obs_count,
        count(r.radar_asc_vv_promedio) AS radar_asc_vv_obs_count,
        count(r.radar_desc_vv_promedio) AS radar_desc_vv_obs_count
    FROM public.tch_raw_longitudinal_v4 r
    WHERE r.tch IS NOT NULL
      AND r.tch BETWEEN 20 AND 150
      AND r.ciclo_valido = true
      AND r.cod_cg_zafra IS NOT NULL
      AND r.edad_de_cultivo IS NOT NULL
    GROUP BY r.cod_cg_zafra
),
radar_long AS (
    SELECT
        b.cod_cg_zafra,
        b.zafra_norm,
        r.edad_de_cultivo::double precision AS age_days,
        (b.fecha_fin_ciclo - r.fecha_stac::date)::double precision AS days_to_harvest,
        CASE
            WHEN r.edad_de_cultivo BETWEEN 0 AND 120 THEN 'early'
            WHEN r.edad_de_cultivo BETWEEN 121 AND 240 THEN 'mid'
            WHEN r.edad_de_cultivo >= 241 THEN 'late'
            ELSE 'outside'
        END AS age_phase,
        v.orbit_name,
        v.metric_name,
        v.metric_value,
        v.days_delta
    FROM base_cycles b
    JOIN public.tch_raw_longitudinal_v4 r USING (cod_cg_zafra)
    CROSS JOIN LATERAL (
        VALUES
            ('asc', 'vh', NULLIF(r.radar_asc_vh_promedio::text, 'NaN')::double precision, r.radar_asc_days_delta::double precision),
            ('asc', 'vv', NULLIF(r.radar_asc_vv_promedio::text, 'NaN')::double precision, r.radar_asc_days_delta::double precision),
            ('asc', 'ratio', NULLIF(r.radar_asc_ratio_promedio::text, 'NaN')::double precision, r.radar_asc_days_delta::double precision),
            ('desc', 'vh', NULLIF(r.radar_desc_vh_promedio::text, 'NaN')::double precision, r.radar_desc_days_delta::double precision),
            ('desc', 'vv', NULLIF(r.radar_desc_vv_promedio::text, 'NaN')::double precision, r.radar_desc_days_delta::double precision),
            ('desc', 'ratio', NULLIF(r.radar_desc_ratio_promedio::text, 'NaN')::double precision, r.radar_desc_days_delta::double precision)
    ) AS v(orbit_name, metric_name, metric_value, days_delta)
    WHERE r.ciclo_valido = true
      AND r.edad_de_cultivo IS NOT NULL
),
features_long AS (
    SELECT
        cod_cg_zafra,
        orbit_name,
        metric_name,
        count(metric_value)::double precision AS obs_count,
        avg(abs(days_delta)) FILTER (WHERE metric_value IS NOT NULL) AS mean_abs_days_delta,
        avg(metric_value) AS full_mean,
        avg(metric_value) FILTER (WHERE age_phase = 'early') AS early_mean,
        avg(metric_value) FILTER (WHERE age_phase = 'mid') AS mid_mean,
        avg(metric_value) FILTER (WHERE age_phase = 'late') AS late_mean,
        max(metric_value) AS max_value,
        min(metric_value) AS min_value,
        max(metric_value) - min(metric_value) AS range_value,
        regr_slope(metric_value, age_days) AS cycle_slope,
        regr_slope(metric_value, age_days) FILTER (WHERE age_days < 240) AS rise_slope,
        regr_slope(metric_value, age_days) FILTER (WHERE age_days >= 240) AS late_slope
    FROM radar_long
    GROUP BY cod_cg_zafra, orbit_name, metric_name
),
features_with_derived AS (
    SELECT
        *,
        mid_mean - early_mean AS mid_minus_early_mean,
        late_mean - mid_mean AS late_minus_mid_mean
    FROM features_long
),
features_wide AS (
    SELECT
        cod_cg_zafra,

        max(obs_count) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_obs_count,
        max(mean_abs_days_delta) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_mean_abs_days_delta,
        max(full_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_full_mean,
        max(early_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_early_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_mid_mean,
        max(late_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_late_minus_mid_mean,
        max(range_value) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_cycle_slope,
        max(rise_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_rise_slope,
        max(late_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vh') AS radar_asc_vh_late_slope,

        max(obs_count) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_obs_count,
        max(mean_abs_days_delta) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_mean_abs_days_delta,
        max(full_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_full_mean,
        max(early_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_early_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_mid_mean,
        max(late_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_late_minus_mid_mean,
        max(range_value) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_cycle_slope,
        max(rise_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_rise_slope,
        max(late_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'vv') AS radar_asc_vv_late_slope,

        max(obs_count) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_obs_count,
        max(mean_abs_days_delta) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_mean_abs_days_delta,
        max(full_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_full_mean,
        max(early_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_early_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_mid_mean,
        max(late_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_late_minus_mid_mean,
        max(range_value) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_cycle_slope,
        max(rise_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_rise_slope,
        max(late_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'ratio') AS radar_asc_ratio_late_slope,

        max(obs_count) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_obs_count,
        max(mean_abs_days_delta) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_mean_abs_days_delta,
        max(full_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_full_mean,
        max(early_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_early_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_mid_mean,
        max(late_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_late_minus_mid_mean,
        max(range_value) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_cycle_slope,
        max(rise_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_rise_slope,
        max(late_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vh') AS radar_desc_vh_late_slope,

        max(obs_count) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_obs_count,
        max(mean_abs_days_delta) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_mean_abs_days_delta,
        max(full_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_full_mean,
        max(early_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_early_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_mid_mean,
        max(late_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_late_minus_mid_mean,
        max(range_value) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_cycle_slope,
        max(rise_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_rise_slope,
        max(late_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'vv') AS radar_desc_vv_late_slope,

        max(obs_count) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_obs_count,
        max(mean_abs_days_delta) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_mean_abs_days_delta,
        max(full_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_full_mean,
        max(early_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_early_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_mid_mean,
        max(late_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_late_minus_mid_mean,
        max(range_value) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_cycle_slope,
        max(rise_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_rise_slope,
        max(late_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'ratio') AS radar_desc_ratio_late_slope
    FROM features_with_derived
    GROUP BY cod_cg_zafra
)
SELECT
    b.cod_cg_zafra,
    b.cod_cg,
    b.zafra_norm,
    b.area,
    b.tch,
    b.tc,
    b.fecha_inicio_ciclo,
    b.fecha_fin_ciclo,
    b.cycle_age_max,
    b.radar_spine_obs_count,
    b.radar_asc_vv_obs_count AS radar_cycle_asc_vv_obs_count,
    b.radar_desc_vv_obs_count AS radar_cycle_desc_vv_obs_count,

    f.radar_asc_vh_obs_count,
    f.radar_asc_vh_mean_abs_days_delta,
    f.radar_asc_vh_full_mean,
    f.radar_asc_vh_early_mean,
    f.radar_asc_vh_mid_mean,
    f.radar_asc_vh_late_mean,
    f.radar_asc_vh_mid_minus_early_mean,
    f.radar_asc_vh_late_minus_mid_mean,
    f.radar_asc_vh_range_value,
    f.radar_asc_vh_cycle_slope,
    f.radar_asc_vh_rise_slope,
    f.radar_asc_vh_late_slope,
    f.radar_asc_vv_obs_count,
    f.radar_asc_vv_mean_abs_days_delta,
    f.radar_asc_vv_full_mean,
    f.radar_asc_vv_early_mean,
    f.radar_asc_vv_mid_mean,
    f.radar_asc_vv_late_mean,
    f.radar_asc_vv_mid_minus_early_mean,
    f.radar_asc_vv_late_minus_mid_mean,
    f.radar_asc_vv_range_value,
    f.radar_asc_vv_cycle_slope,
    f.radar_asc_vv_rise_slope,
    f.radar_asc_vv_late_slope,
    f.radar_asc_ratio_obs_count,
    f.radar_asc_ratio_mean_abs_days_delta,
    f.radar_asc_ratio_full_mean,
    f.radar_asc_ratio_early_mean,
    f.radar_asc_ratio_mid_mean,
    f.radar_asc_ratio_late_mean,
    f.radar_asc_ratio_mid_minus_early_mean,
    f.radar_asc_ratio_late_minus_mid_mean,
    f.radar_asc_ratio_range_value,
    f.radar_asc_ratio_cycle_slope,
    f.radar_asc_ratio_rise_slope,
    f.radar_asc_ratio_late_slope,

    f.radar_desc_vh_obs_count,
    f.radar_desc_vh_mean_abs_days_delta,
    f.radar_desc_vh_full_mean,
    f.radar_desc_vh_early_mean,
    f.radar_desc_vh_mid_mean,
    f.radar_desc_vh_late_mean,
    f.radar_desc_vh_mid_minus_early_mean,
    f.radar_desc_vh_late_minus_mid_mean,
    f.radar_desc_vh_range_value,
    f.radar_desc_vh_cycle_slope,
    f.radar_desc_vh_rise_slope,
    f.radar_desc_vh_late_slope,
    f.radar_desc_vv_obs_count,
    f.radar_desc_vv_mean_abs_days_delta,
    f.radar_desc_vv_full_mean,
    f.radar_desc_vv_early_mean,
    f.radar_desc_vv_mid_mean,
    f.radar_desc_vv_late_mean,
    f.radar_desc_vv_mid_minus_early_mean,
    f.radar_desc_vv_late_minus_mid_mean,
    f.radar_desc_vv_range_value,
    f.radar_desc_vv_cycle_slope,
    f.radar_desc_vv_rise_slope,
    f.radar_desc_vv_late_slope,
    f.radar_desc_ratio_obs_count,
    f.radar_desc_ratio_mean_abs_days_delta,
    f.radar_desc_ratio_full_mean,
    f.radar_desc_ratio_early_mean,
    f.radar_desc_ratio_mid_mean,
    f.radar_desc_ratio_late_mean,
    f.radar_desc_ratio_mid_minus_early_mean,
    f.radar_desc_ratio_late_minus_mid_mean,
    f.radar_desc_ratio_range_value,
    f.radar_desc_ratio_cycle_slope,
    f.radar_desc_ratio_rise_slope,
    f.radar_desc_ratio_late_slope
FROM base_cycles b
LEFT JOIN features_wide f USING (cod_cg_zafra);
