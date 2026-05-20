-- tch_optical_core_v4.sql
--
-- Optical STAC core feature block for the pseudo-sequential/tabular TCH strategy.
--
-- Shape:
--   one row per valid cod_cg_zafra
--
-- Intent:
--   Preserve crop-response temporal structure with compact phenology and
--   trajectory features instead of raw temporal bins or blind statistics.
--
-- Source rules:
--   - public.tch_raw_longitudinal_v4 supplies validated cycle bounds, target,
--     model metadata, and in-window STAC observations.
--   - Core optical indices are NDVI, EVI2, GNDVI, NDRE, and LSWI.
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
        count(*) AS optical_raw_obs_count,
        count(r.stac_ndvi_promedio) AS optical_ndvi_obs_count
    FROM public.tch_raw_longitudinal_v4 r
    WHERE r.tch IS NOT NULL
      AND r.tch BETWEEN 20 AND 150
      AND r.ciclo_valido = true
      AND r.cod_cg_zafra IS NOT NULL
      AND r.edad_de_cultivo IS NOT NULL
    GROUP BY r.cod_cg_zafra
),
optical_long AS (
    SELECT
        b.cod_cg_zafra,
        b.zafra_norm,
        b.cycle_age_max,
        r.fecha_stac::date AS fecha_obs,
        r.edad_de_cultivo::double precision AS age_days,
        (b.fecha_fin_ciclo - r.fecha_stac::date)::double precision AS days_to_harvest,
        CASE
            WHEN r.edad_de_cultivo BETWEEN 0 AND 120 THEN 'early'
            WHEN r.edad_de_cultivo BETWEEN 121 AND 240 THEN 'mid'
            WHEN r.edad_de_cultivo >= 241 THEN 'late'
            ELSE 'outside'
        END AS age_phase,
        v.index_name,
        v.index_value
    FROM base_cycles b
    JOIN public.tch_raw_longitudinal_v4 r USING (cod_cg_zafra)
    CROSS JOIN LATERAL (
        VALUES
            ('ndvi', NULLIF(r.stac_ndvi_promedio::text, 'NaN')::double precision),
            ('evi2', NULLIF(r.stac_evi2_promedio::text, 'NaN')::double precision),
            ('gndvi', NULLIF(r.stac_gndvi_promedio::text, 'NaN')::double precision),
            ('ndre', NULLIF(r.stac_ndre_promedio::text, 'NaN')::double precision),
            ('lswi', NULLIF(r.stac_lswi_promedio::text, 'NaN')::double precision)
    ) AS v(index_name, index_value)
    WHERE r.ciclo_valido = true
      AND r.edad_de_cultivo IS NOT NULL
),
optical_weighted AS (
    SELECT
        *,
        lag(age_days) OVER (
            PARTITION BY cod_cg_zafra, index_name
            ORDER BY age_days, fecha_obs
        ) AS prev_age,
        lead(age_days) OVER (
            PARTITION BY cod_cg_zafra, index_name
            ORDER BY age_days, fecha_obs
        ) AS next_age,
        max(index_value) OVER (
            PARTITION BY cod_cg_zafra, index_name
        ) AS peak_value_window
    FROM optical_long
),
prepared AS (
    SELECT
        *,
        greatest(0.0, coalesce((prev_age + age_days) / 2.0, age_days - 7.5)) AS obs_start_age,
        least(cycle_age_max, coalesce((age_days + next_age) / 2.0, age_days + 7.5)) AS obs_end_age
    FROM optical_weighted
),
features_long AS (
    SELECT
        cod_cg_zafra,
        index_name,

        count(index_value)::double precision AS obs_count,
        min(age_days) FILTER (WHERE index_value IS NOT NULL) AS first_obs_age,
        max(age_days) FILTER (WHERE index_value IS NOT NULL) AS last_obs_age,
        max(age_days) FILTER (WHERE index_value IS NOT NULL)
            - min(age_days) FILTER (WHERE index_value IS NOT NULL) AS observed_age_span,
        max(age_days - prev_age) FILTER (WHERE index_value IS NOT NULL) AS max_gap_days,

        avg(index_value) AS full_mean,
        avg(index_value) FILTER (WHERE age_phase = 'early') AS early_mean,
        avg(index_value) FILTER (WHERE age_phase = 'mid') AS mid_mean,
        avg(index_value) FILTER (WHERE age_phase = 'late') AS late_mean,
        max(index_value) AS peak_value,
        min(index_value) AS min_value,
        max(index_value) - min(index_value) AS amplitude,
        (array_agg(age_days ORDER BY index_value DESC NULLS LAST, age_days)
            FILTER (WHERE index_value IS NOT NULL))[1] AS age_at_peak,

        sum(index_value * greatest(0.0, obs_end_age - obs_start_age)) AS auc_full,
        sum(index_value * greatest(0.0, least(obs_end_age, 120.0) - greatest(obs_start_age, 0.0))) AS auc_early,
        sum(index_value * greatest(0.0, least(obs_end_age, 240.0) - greatest(obs_start_age, 120.0))) AS auc_mid,
        sum(index_value * greatest(0.0, obs_end_age - greatest(obs_start_age, 240.0))) AS auc_late,

        regr_slope(index_value, age_days) FILTER (WHERE age_days < 240) AS rise_slope,
        regr_slope(index_value, age_days) FILTER (WHERE age_days >= 240) AS late_slope,
        sum(greatest(0.0, obs_end_age - obs_start_age))
            FILTER (WHERE index_value >= 0.8 * peak_value_window) AS duration_above_80pct_peak
    FROM prepared
    GROUP BY cod_cg_zafra, index_name
),
features_with_derived AS (
    SELECT
        f.*,
        f.mid_mean - f.early_mean AS mid_minus_early_mean,
        f.late_mean - f.mid_mean AS late_minus_mid_mean,
        CASE
            WHEN b.cycle_age_max > 0 THEN f.age_at_peak / b.cycle_age_max
            ELSE NULL
        END AS rel_age_at_peak
    FROM features_long f
    JOIN base_cycles b USING (cod_cg_zafra)
),
features_wide AS (
    SELECT
        cod_cg_zafra,

        max(obs_count) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_obs_count,
        max(first_obs_age) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_first_obs_age,
        max(last_obs_age) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_last_obs_age,
        max(observed_age_span) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_observed_age_span,
        max(max_gap_days) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_max_gap_days,
        max(full_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_full_mean,
        max(early_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_early_mean,
        max(mid_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mid_mean,
        max(late_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_late_minus_mid_mean,
        max(peak_value) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_peak_value,
        max(min_value) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_min_value,
        max(amplitude) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_amplitude,
        max(age_at_peak) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_age_at_peak,
        max(rel_age_at_peak) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_rel_age_at_peak,
        max(auc_full) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_auc_full,
        max(auc_early) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_auc_early,
        max(auc_mid) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_auc_mid,
        max(auc_late) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_auc_late,
        max(rise_slope) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_rise_slope,
        max(late_slope) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_late_slope,
        max(duration_above_80pct_peak) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_duration_above_80pct_peak,

        max(obs_count) FILTER (WHERE index_name = 'evi2') AS optical_evi2_obs_count,
        max(full_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_full_mean,
        max(early_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_early_mean,
        max(mid_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_mid_mean,
        max(late_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_late_minus_mid_mean,
        max(peak_value) FILTER (WHERE index_name = 'evi2') AS optical_evi2_peak_value,
        max(min_value) FILTER (WHERE index_name = 'evi2') AS optical_evi2_min_value,
        max(amplitude) FILTER (WHERE index_name = 'evi2') AS optical_evi2_amplitude,
        max(age_at_peak) FILTER (WHERE index_name = 'evi2') AS optical_evi2_age_at_peak,
        max(rel_age_at_peak) FILTER (WHERE index_name = 'evi2') AS optical_evi2_rel_age_at_peak,
        max(auc_full) FILTER (WHERE index_name = 'evi2') AS optical_evi2_auc_full,
        max(auc_early) FILTER (WHERE index_name = 'evi2') AS optical_evi2_auc_early,
        max(auc_mid) FILTER (WHERE index_name = 'evi2') AS optical_evi2_auc_mid,
        max(auc_late) FILTER (WHERE index_name = 'evi2') AS optical_evi2_auc_late,
        max(rise_slope) FILTER (WHERE index_name = 'evi2') AS optical_evi2_rise_slope,
        max(late_slope) FILTER (WHERE index_name = 'evi2') AS optical_evi2_late_slope,
        max(duration_above_80pct_peak) FILTER (WHERE index_name = 'evi2') AS optical_evi2_duration_above_80pct_peak,

        max(obs_count) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_obs_count,
        max(full_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_full_mean,
        max(early_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_early_mean,
        max(mid_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_mid_mean,
        max(late_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_late_minus_mid_mean,
        max(peak_value) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_peak_value,
        max(min_value) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_min_value,
        max(amplitude) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_amplitude,
        max(age_at_peak) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_age_at_peak,
        max(rel_age_at_peak) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_rel_age_at_peak,
        max(auc_full) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_auc_full,
        max(auc_early) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_auc_early,
        max(auc_mid) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_auc_mid,
        max(auc_late) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_auc_late,
        max(rise_slope) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_rise_slope,
        max(late_slope) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_late_slope,
        max(duration_above_80pct_peak) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_duration_above_80pct_peak,

        max(obs_count) FILTER (WHERE index_name = 'ndre') AS optical_ndre_obs_count,
        max(full_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_full_mean,
        max(early_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_early_mean,
        max(mid_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_mid_mean,
        max(late_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_late_minus_mid_mean,
        max(peak_value) FILTER (WHERE index_name = 'ndre') AS optical_ndre_peak_value,
        max(min_value) FILTER (WHERE index_name = 'ndre') AS optical_ndre_min_value,
        max(amplitude) FILTER (WHERE index_name = 'ndre') AS optical_ndre_amplitude,
        max(age_at_peak) FILTER (WHERE index_name = 'ndre') AS optical_ndre_age_at_peak,
        max(rel_age_at_peak) FILTER (WHERE index_name = 'ndre') AS optical_ndre_rel_age_at_peak,
        max(auc_full) FILTER (WHERE index_name = 'ndre') AS optical_ndre_auc_full,
        max(auc_early) FILTER (WHERE index_name = 'ndre') AS optical_ndre_auc_early,
        max(auc_mid) FILTER (WHERE index_name = 'ndre') AS optical_ndre_auc_mid,
        max(auc_late) FILTER (WHERE index_name = 'ndre') AS optical_ndre_auc_late,
        max(rise_slope) FILTER (WHERE index_name = 'ndre') AS optical_ndre_rise_slope,
        max(late_slope) FILTER (WHERE index_name = 'ndre') AS optical_ndre_late_slope,
        max(duration_above_80pct_peak) FILTER (WHERE index_name = 'ndre') AS optical_ndre_duration_above_80pct_peak,

        max(obs_count) FILTER (WHERE index_name = 'lswi') AS optical_lswi_obs_count,
        max(full_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_full_mean,
        max(early_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_early_mean,
        max(mid_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_mid_mean,
        max(late_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_late_minus_mid_mean,
        max(peak_value) FILTER (WHERE index_name = 'lswi') AS optical_lswi_peak_value,
        max(min_value) FILTER (WHERE index_name = 'lswi') AS optical_lswi_min_value,
        max(amplitude) FILTER (WHERE index_name = 'lswi') AS optical_lswi_amplitude,
        max(age_at_peak) FILTER (WHERE index_name = 'lswi') AS optical_lswi_age_at_peak,
        max(rel_age_at_peak) FILTER (WHERE index_name = 'lswi') AS optical_lswi_rel_age_at_peak,
        max(auc_full) FILTER (WHERE index_name = 'lswi') AS optical_lswi_auc_full,
        max(auc_early) FILTER (WHERE index_name = 'lswi') AS optical_lswi_auc_early,
        max(auc_mid) FILTER (WHERE index_name = 'lswi') AS optical_lswi_auc_mid,
        max(auc_late) FILTER (WHERE index_name = 'lswi') AS optical_lswi_auc_late,
        max(rise_slope) FILTER (WHERE index_name = 'lswi') AS optical_lswi_rise_slope,
        max(late_slope) FILTER (WHERE index_name = 'lswi') AS optical_lswi_late_slope,
        max(duration_above_80pct_peak) FILTER (WHERE index_name = 'lswi') AS optical_lswi_duration_above_80pct_peak
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
    b.optical_raw_obs_count,
    b.optical_ndvi_obs_count AS optical_cycle_ndvi_obs_count,
    f.optical_ndvi_obs_count,
    f.optical_ndvi_first_obs_age,
    f.optical_ndvi_last_obs_age,
    f.optical_ndvi_observed_age_span,
    f.optical_ndvi_max_gap_days,
    f.optical_ndvi_full_mean,
    f.optical_ndvi_early_mean,
    f.optical_ndvi_mid_mean,
    f.optical_ndvi_late_mean,
    f.optical_ndvi_mid_minus_early_mean,
    f.optical_ndvi_late_minus_mid_mean,
    f.optical_ndvi_peak_value,
    f.optical_ndvi_min_value,
    f.optical_ndvi_amplitude,
    f.optical_ndvi_age_at_peak,
    f.optical_ndvi_rel_age_at_peak,
    f.optical_ndvi_auc_full,
    f.optical_ndvi_auc_early,
    f.optical_ndvi_auc_mid,
    f.optical_ndvi_auc_late,
    f.optical_ndvi_rise_slope,
    f.optical_ndvi_late_slope,
    f.optical_ndvi_duration_above_80pct_peak,
    f.optical_evi2_obs_count,
    f.optical_evi2_full_mean,
    f.optical_evi2_early_mean,
    f.optical_evi2_mid_mean,
    f.optical_evi2_late_mean,
    f.optical_evi2_mid_minus_early_mean,
    f.optical_evi2_late_minus_mid_mean,
    f.optical_evi2_peak_value,
    f.optical_evi2_min_value,
    f.optical_evi2_amplitude,
    f.optical_evi2_age_at_peak,
    f.optical_evi2_rel_age_at_peak,
    f.optical_evi2_auc_full,
    f.optical_evi2_auc_early,
    f.optical_evi2_auc_mid,
    f.optical_evi2_auc_late,
    f.optical_evi2_rise_slope,
    f.optical_evi2_late_slope,
    f.optical_evi2_duration_above_80pct_peak,
    f.optical_gndvi_obs_count,
    f.optical_gndvi_full_mean,
    f.optical_gndvi_early_mean,
    f.optical_gndvi_mid_mean,
    f.optical_gndvi_late_mean,
    f.optical_gndvi_mid_minus_early_mean,
    f.optical_gndvi_late_minus_mid_mean,
    f.optical_gndvi_peak_value,
    f.optical_gndvi_min_value,
    f.optical_gndvi_amplitude,
    f.optical_gndvi_age_at_peak,
    f.optical_gndvi_rel_age_at_peak,
    f.optical_gndvi_auc_full,
    f.optical_gndvi_auc_early,
    f.optical_gndvi_auc_mid,
    f.optical_gndvi_auc_late,
    f.optical_gndvi_rise_slope,
    f.optical_gndvi_late_slope,
    f.optical_gndvi_duration_above_80pct_peak,
    f.optical_ndre_obs_count,
    f.optical_ndre_full_mean,
    f.optical_ndre_early_mean,
    f.optical_ndre_mid_mean,
    f.optical_ndre_late_mean,
    f.optical_ndre_mid_minus_early_mean,
    f.optical_ndre_late_minus_mid_mean,
    f.optical_ndre_peak_value,
    f.optical_ndre_min_value,
    f.optical_ndre_amplitude,
    f.optical_ndre_age_at_peak,
    f.optical_ndre_rel_age_at_peak,
    f.optical_ndre_auc_full,
    f.optical_ndre_auc_early,
    f.optical_ndre_auc_mid,
    f.optical_ndre_auc_late,
    f.optical_ndre_rise_slope,
    f.optical_ndre_late_slope,
    f.optical_ndre_duration_above_80pct_peak,
    f.optical_lswi_obs_count,
    f.optical_lswi_full_mean,
    f.optical_lswi_early_mean,
    f.optical_lswi_mid_mean,
    f.optical_lswi_late_mean,
    f.optical_lswi_mid_minus_early_mean,
    f.optical_lswi_late_minus_mid_mean,
    f.optical_lswi_peak_value,
    f.optical_lswi_min_value,
    f.optical_lswi_amplitude,
    f.optical_lswi_age_at_peak,
    f.optical_lswi_rel_age_at_peak,
    f.optical_lswi_auc_full,
    f.optical_lswi_auc_early,
    f.optical_lswi_auc_mid,
    f.optical_lswi_auc_late,
    f.optical_lswi_rise_slope,
    f.optical_lswi_late_slope,
    f.optical_lswi_duration_above_80pct_peak
FROM base_cycles b
LEFT JOIN features_wide f USING (cod_cg_zafra);
