-- tch_radar_ablation_v4.sql
--
-- Secondary Radar/SAR feature block for later ablation tests.
--
-- Shape:
--   one row per valid cod_cg_zafra
--
-- Intent:
--   Keep plausible but lower-priority SAR signals separate from the core:
--   RVI, NRB, RFDI, last-90 recency summaries, and ASC-DESC orbit differences.
--
-- Source rules:
--   - public.tch_raw_longitudinal_v4 supplies validated cycle bounds, target,
--     model metadata, and nearest ASC/DESC radar observations already aligned
--     to the optical observation spine.
--
-- Usage:
--   Join to the core training table by cod_cg_zafra only when running ablation.

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
        count(*) AS radar_spine_obs_count
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
            ('asc', 'rvi', NULLIF(r.radar_asc_rvi_promedio::text, 'NaN')::double precision, r.radar_asc_days_delta::double precision),
            ('asc', 'nrb', NULLIF(r.radar_asc_nrb_promedio::text, 'NaN')::double precision, r.radar_asc_days_delta::double precision),
            ('asc', 'rfdi', NULLIF(r.radar_asc_rfdi_promedio::text, 'NaN')::double precision, r.radar_asc_days_delta::double precision),
            ('desc', 'rvi', NULLIF(r.radar_desc_rvi_promedio::text, 'NaN')::double precision, r.radar_desc_days_delta::double precision),
            ('desc', 'nrb', NULLIF(r.radar_desc_nrb_promedio::text, 'NaN')::double precision, r.radar_desc_days_delta::double precision),
            ('desc', 'rfdi', NULLIF(r.radar_desc_rfdi_promedio::text, 'NaN')::double precision, r.radar_desc_days_delta::double precision)
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
        avg(metric_value) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS last_090_mean,
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
orbit_diff_features AS (
    WITH pivoted AS (
        SELECT
            cod_cg_zafra,
            metric_name,
            max(full_mean) FILTER (WHERE orbit_name = 'asc') AS asc_full_mean,
            max(full_mean) FILTER (WHERE orbit_name = 'desc') AS desc_full_mean,
            max(mid_mean) FILTER (WHERE orbit_name = 'asc') AS asc_mid_mean,
            max(mid_mean) FILTER (WHERE orbit_name = 'desc') AS desc_mid_mean,
            max(last_090_mean) FILTER (WHERE orbit_name = 'asc') AS asc_last_090_mean,
            max(last_090_mean) FILTER (WHERE orbit_name = 'desc') AS desc_last_090_mean
        FROM features_with_derived
        GROUP BY cod_cg_zafra, metric_name
    )
    SELECT
        cod_cg_zafra,
        metric_name,
        asc_full_mean - desc_full_mean AS orbit_diff_full_mean,
        asc_mid_mean - desc_mid_mean AS orbit_diff_mid_mean,
        asc_last_090_mean - desc_last_090_mean AS orbit_diff_last_090_mean
    FROM pivoted
),
features_wide AS (
    SELECT
        cod_cg_zafra,

        max(obs_count) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_obs_count,
        max(mean_abs_days_delta) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_mean_abs_days_delta,
        max(full_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_full_mean,
        max(early_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_early_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_mid_mean,
        max(late_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_late_mean,
        max(last_090_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_last_090_mean,
        max(mid_minus_early_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_late_minus_mid_mean,
        max(range_value) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_cycle_slope,
        max(rise_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_rise_slope,
        max(late_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rvi') AS radar_abl_asc_rvi_late_slope,

        max(obs_count) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_obs_count,
        max(mean_abs_days_delta) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_mean_abs_days_delta,
        max(full_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_full_mean,
        max(early_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_early_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_mid_mean,
        max(late_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_late_mean,
        max(last_090_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_last_090_mean,
        max(mid_minus_early_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_late_minus_mid_mean,
        max(range_value) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_cycle_slope,
        max(rise_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_rise_slope,
        max(late_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rvi') AS radar_abl_desc_rvi_late_slope,

        max(obs_count) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'nrb') AS radar_abl_asc_nrb_obs_count,
        max(full_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'nrb') AS radar_abl_asc_nrb_full_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'nrb') AS radar_abl_asc_nrb_mid_mean,
        max(last_090_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'nrb') AS radar_abl_asc_nrb_last_090_mean,
        max(range_value) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'nrb') AS radar_abl_asc_nrb_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'nrb') AS radar_abl_asc_nrb_cycle_slope,
        max(obs_count) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'nrb') AS radar_abl_desc_nrb_obs_count,
        max(full_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'nrb') AS radar_abl_desc_nrb_full_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'nrb') AS radar_abl_desc_nrb_mid_mean,
        max(last_090_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'nrb') AS radar_abl_desc_nrb_last_090_mean,
        max(range_value) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'nrb') AS radar_abl_desc_nrb_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'nrb') AS radar_abl_desc_nrb_cycle_slope,

        max(obs_count) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rfdi') AS radar_abl_asc_rfdi_obs_count,
        max(full_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rfdi') AS radar_abl_asc_rfdi_full_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rfdi') AS radar_abl_asc_rfdi_mid_mean,
        max(last_090_mean) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rfdi') AS radar_abl_asc_rfdi_last_090_mean,
        max(range_value) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rfdi') AS radar_abl_asc_rfdi_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'asc' AND metric_name = 'rfdi') AS radar_abl_asc_rfdi_cycle_slope,
        max(obs_count) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rfdi') AS radar_abl_desc_rfdi_obs_count,
        max(full_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rfdi') AS radar_abl_desc_rfdi_full_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rfdi') AS radar_abl_desc_rfdi_mid_mean,
        max(last_090_mean) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rfdi') AS radar_abl_desc_rfdi_last_090_mean,
        max(range_value) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rfdi') AS radar_abl_desc_rfdi_range_value,
        max(cycle_slope) FILTER (WHERE orbit_name = 'desc' AND metric_name = 'rfdi') AS radar_abl_desc_rfdi_cycle_slope
    FROM features_with_derived
    GROUP BY cod_cg_zafra
),
orbit_diff_wide AS (
    SELECT
        cod_cg_zafra,
        max(orbit_diff_full_mean) FILTER (WHERE metric_name = 'rvi') AS radar_abl_rvi_orbit_diff_full_mean,
        max(orbit_diff_mid_mean) FILTER (WHERE metric_name = 'rvi') AS radar_abl_rvi_orbit_diff_mid_mean,
        max(orbit_diff_last_090_mean) FILTER (WHERE metric_name = 'rvi') AS radar_abl_rvi_orbit_diff_last_090_mean,
        max(orbit_diff_full_mean) FILTER (WHERE metric_name = 'nrb') AS radar_abl_nrb_orbit_diff_full_mean,
        max(orbit_diff_mid_mean) FILTER (WHERE metric_name = 'nrb') AS radar_abl_nrb_orbit_diff_mid_mean,
        max(orbit_diff_last_090_mean) FILTER (WHERE metric_name = 'nrb') AS radar_abl_nrb_orbit_diff_last_090_mean,
        max(orbit_diff_full_mean) FILTER (WHERE metric_name = 'rfdi') AS radar_abl_rfdi_orbit_diff_full_mean,
        max(orbit_diff_mid_mean) FILTER (WHERE metric_name = 'rfdi') AS radar_abl_rfdi_orbit_diff_mid_mean,
        max(orbit_diff_last_090_mean) FILTER (WHERE metric_name = 'rfdi') AS radar_abl_rfdi_orbit_diff_last_090_mean
    FROM orbit_diff_features
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

    f.radar_abl_asc_rvi_obs_count,
    f.radar_abl_asc_rvi_mean_abs_days_delta,
    f.radar_abl_asc_rvi_full_mean,
    f.radar_abl_asc_rvi_early_mean,
    f.radar_abl_asc_rvi_mid_mean,
    f.radar_abl_asc_rvi_late_mean,
    f.radar_abl_asc_rvi_last_090_mean,
    f.radar_abl_asc_rvi_mid_minus_early_mean,
    f.radar_abl_asc_rvi_late_minus_mid_mean,
    f.radar_abl_asc_rvi_range_value,
    f.radar_abl_asc_rvi_cycle_slope,
    f.radar_abl_asc_rvi_rise_slope,
    f.radar_abl_asc_rvi_late_slope,
    f.radar_abl_desc_rvi_obs_count,
    f.radar_abl_desc_rvi_mean_abs_days_delta,
    f.radar_abl_desc_rvi_full_mean,
    f.radar_abl_desc_rvi_early_mean,
    f.radar_abl_desc_rvi_mid_mean,
    f.radar_abl_desc_rvi_late_mean,
    f.radar_abl_desc_rvi_last_090_mean,
    f.radar_abl_desc_rvi_mid_minus_early_mean,
    f.radar_abl_desc_rvi_late_minus_mid_mean,
    f.radar_abl_desc_rvi_range_value,
    f.radar_abl_desc_rvi_cycle_slope,
    f.radar_abl_desc_rvi_rise_slope,
    f.radar_abl_desc_rvi_late_slope,

    f.radar_abl_asc_nrb_obs_count,
    f.radar_abl_asc_nrb_full_mean,
    f.radar_abl_asc_nrb_mid_mean,
    f.radar_abl_asc_nrb_last_090_mean,
    f.radar_abl_asc_nrb_range_value,
    f.radar_abl_asc_nrb_cycle_slope,
    f.radar_abl_desc_nrb_obs_count,
    f.radar_abl_desc_nrb_full_mean,
    f.radar_abl_desc_nrb_mid_mean,
    f.radar_abl_desc_nrb_last_090_mean,
    f.radar_abl_desc_nrb_range_value,
    f.radar_abl_desc_nrb_cycle_slope,

    f.radar_abl_asc_rfdi_obs_count,
    f.radar_abl_asc_rfdi_full_mean,
    f.radar_abl_asc_rfdi_mid_mean,
    f.radar_abl_asc_rfdi_last_090_mean,
    f.radar_abl_asc_rfdi_range_value,
    f.radar_abl_asc_rfdi_cycle_slope,
    f.radar_abl_desc_rfdi_obs_count,
    f.radar_abl_desc_rfdi_full_mean,
    f.radar_abl_desc_rfdi_mid_mean,
    f.radar_abl_desc_rfdi_last_090_mean,
    f.radar_abl_desc_rfdi_range_value,
    f.radar_abl_desc_rfdi_cycle_slope,

    od.radar_abl_rvi_orbit_diff_full_mean,
    od.radar_abl_rvi_orbit_diff_mid_mean,
    od.radar_abl_rvi_orbit_diff_last_090_mean,
    od.radar_abl_nrb_orbit_diff_full_mean,
    od.radar_abl_nrb_orbit_diff_mid_mean,
    od.radar_abl_nrb_orbit_diff_last_090_mean,
    od.radar_abl_rfdi_orbit_diff_full_mean,
    od.radar_abl_rfdi_orbit_diff_mid_mean,
    od.radar_abl_rfdi_orbit_diff_last_090_mean
FROM base_cycles b
LEFT JOIN features_wide f USING (cod_cg_zafra)
LEFT JOIN orbit_diff_wide od USING (cod_cg_zafra);
