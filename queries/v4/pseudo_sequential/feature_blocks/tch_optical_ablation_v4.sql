-- tch_optical_ablation_v4.sql
--
-- Secondary optical STAC feature block for later ablation tests.
--
-- Shape:
--   one row per valid cod_cg_zafra
--
-- Intent:
--   Keep plausible but lower-priority optical signals separate from the core:
--   secondary moisture/red-edge variants, last-90 recency features, variability,
--   and simple extremes.
--
-- Source rules:
--   - public.tch_raw_longitudinal_v4 supplies validated cycle bounds, target,
--     model metadata, and in-window STAC observations.
--   - Ablation indices are NDWI11, MSI11, NDVIRE, and CIRE.
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
        count(*) AS optical_raw_obs_count
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
            ('ndwi11', NULLIF(r.stac_ndwi11_promedio::text, 'NaN')::double precision),
            ('msi11', NULLIF(r.stac_msi11_promedio::text, 'NaN')::double precision),
            ('ndvire', NULLIF(r.stac_ndvire_promedio::text, 'NaN')::double precision),
            ('cire', NULLIF(r.stac_cire_promedio::text, 'NaN')::double precision)
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
        ) AS next_age
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
        avg(index_value) AS full_mean,
        avg(index_value) FILTER (WHERE age_phase = 'early') AS early_mean,
        avg(index_value) FILTER (WHERE age_phase = 'mid') AS mid_mean,
        avg(index_value) FILTER (WHERE age_phase = 'late') AS late_mean,
        stddev_samp(index_value) AS full_std,
        max(index_value) AS max_value,
        min(index_value) AS min_value,
        max(index_value) - min(index_value) AS amplitude,
        (array_agg(age_days ORDER BY index_value DESC NULLS LAST, age_days)
            FILTER (WHERE index_value IS NOT NULL))[1] AS age_at_peak,
        sum(index_value * greatest(0.0, obs_end_age - obs_start_age)) AS auc_full,
        sum(index_value * greatest(0.0, least(obs_end_age, 120.0) - greatest(obs_start_age, 0.0))) AS auc_early,
        sum(index_value * greatest(0.0, least(obs_end_age, 240.0) - greatest(obs_start_age, 120.0))) AS auc_mid,
        sum(index_value * greatest(0.0, obs_end_age - greatest(obs_start_age, 240.0))) AS auc_late,
        avg(index_value) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS last_090_mean,
        regr_slope(index_value, days_to_harvest) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS last_090_slope,
        regr_slope(index_value, age_days) AS cycle_slope
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

        max(obs_count) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_obs_count,
        max(full_mean) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_full_mean,
        max(early_mean) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_early_mean,
        max(mid_mean) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_mid_mean,
        max(late_mean) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_late_minus_mid_mean,
        max(full_std) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_full_std,
        max(max_value) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_max_value,
        max(min_value) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_min_value,
        max(amplitude) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_amplitude,
        max(age_at_peak) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_age_at_peak,
        max(rel_age_at_peak) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_rel_age_at_peak,
        max(auc_full) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_auc_full,
        max(auc_early) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_auc_early,
        max(auc_mid) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_auc_mid,
        max(auc_late) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_auc_late,
        max(last_090_mean) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_last_090_mean,
        max(last_090_slope) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_last_090_slope,
        max(cycle_slope) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_cycle_slope,

        max(obs_count) FILTER (WHERE index_name = 'msi11') AS optical_msi11_obs_count,
        max(full_mean) FILTER (WHERE index_name = 'msi11') AS optical_msi11_full_mean,
        max(early_mean) FILTER (WHERE index_name = 'msi11') AS optical_msi11_early_mean,
        max(mid_mean) FILTER (WHERE index_name = 'msi11') AS optical_msi11_mid_mean,
        max(late_mean) FILTER (WHERE index_name = 'msi11') AS optical_msi11_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE index_name = 'msi11') AS optical_msi11_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE index_name = 'msi11') AS optical_msi11_late_minus_mid_mean,
        max(full_std) FILTER (WHERE index_name = 'msi11') AS optical_msi11_full_std,
        max(max_value) FILTER (WHERE index_name = 'msi11') AS optical_msi11_max_value,
        max(min_value) FILTER (WHERE index_name = 'msi11') AS optical_msi11_min_value,
        max(amplitude) FILTER (WHERE index_name = 'msi11') AS optical_msi11_amplitude,
        max(age_at_peak) FILTER (WHERE index_name = 'msi11') AS optical_msi11_age_at_peak,
        max(rel_age_at_peak) FILTER (WHERE index_name = 'msi11') AS optical_msi11_rel_age_at_peak,
        max(auc_full) FILTER (WHERE index_name = 'msi11') AS optical_msi11_auc_full,
        max(auc_early) FILTER (WHERE index_name = 'msi11') AS optical_msi11_auc_early,
        max(auc_mid) FILTER (WHERE index_name = 'msi11') AS optical_msi11_auc_mid,
        max(auc_late) FILTER (WHERE index_name = 'msi11') AS optical_msi11_auc_late,
        max(last_090_mean) FILTER (WHERE index_name = 'msi11') AS optical_msi11_last_090_mean,
        max(last_090_slope) FILTER (WHERE index_name = 'msi11') AS optical_msi11_last_090_slope,
        max(cycle_slope) FILTER (WHERE index_name = 'msi11') AS optical_msi11_cycle_slope,

        max(obs_count) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_obs_count,
        max(full_mean) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_full_mean,
        max(early_mean) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_early_mean,
        max(mid_mean) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_mid_mean,
        max(late_mean) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_late_minus_mid_mean,
        max(full_std) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_full_std,
        max(max_value) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_max_value,
        max(min_value) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_min_value,
        max(amplitude) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_amplitude,
        max(age_at_peak) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_age_at_peak,
        max(rel_age_at_peak) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_rel_age_at_peak,
        max(auc_full) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_auc_full,
        max(auc_early) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_auc_early,
        max(auc_mid) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_auc_mid,
        max(auc_late) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_auc_late,
        max(last_090_mean) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_last_090_mean,
        max(last_090_slope) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_last_090_slope,
        max(cycle_slope) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_cycle_slope,

        max(obs_count) FILTER (WHERE index_name = 'cire') AS optical_cire_obs_count,
        max(full_mean) FILTER (WHERE index_name = 'cire') AS optical_cire_full_mean,
        max(early_mean) FILTER (WHERE index_name = 'cire') AS optical_cire_early_mean,
        max(mid_mean) FILTER (WHERE index_name = 'cire') AS optical_cire_mid_mean,
        max(late_mean) FILTER (WHERE index_name = 'cire') AS optical_cire_late_mean,
        max(mid_minus_early_mean) FILTER (WHERE index_name = 'cire') AS optical_cire_mid_minus_early_mean,
        max(late_minus_mid_mean) FILTER (WHERE index_name = 'cire') AS optical_cire_late_minus_mid_mean,
        max(full_std) FILTER (WHERE index_name = 'cire') AS optical_cire_full_std,
        max(max_value) FILTER (WHERE index_name = 'cire') AS optical_cire_max_value,
        max(min_value) FILTER (WHERE index_name = 'cire') AS optical_cire_min_value,
        max(amplitude) FILTER (WHERE index_name = 'cire') AS optical_cire_amplitude,
        max(age_at_peak) FILTER (WHERE index_name = 'cire') AS optical_cire_age_at_peak,
        max(rel_age_at_peak) FILTER (WHERE index_name = 'cire') AS optical_cire_rel_age_at_peak,
        max(auc_full) FILTER (WHERE index_name = 'cire') AS optical_cire_auc_full,
        max(auc_early) FILTER (WHERE index_name = 'cire') AS optical_cire_auc_early,
        max(auc_mid) FILTER (WHERE index_name = 'cire') AS optical_cire_auc_mid,
        max(auc_late) FILTER (WHERE index_name = 'cire') AS optical_cire_auc_late,
        max(last_090_mean) FILTER (WHERE index_name = 'cire') AS optical_cire_last_090_mean,
        max(last_090_slope) FILTER (WHERE index_name = 'cire') AS optical_cire_last_090_slope,
        max(cycle_slope) FILTER (WHERE index_name = 'cire') AS optical_cire_cycle_slope
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

    f.optical_ndwi11_obs_count,
    f.optical_ndwi11_full_mean,
    f.optical_ndwi11_early_mean,
    f.optical_ndwi11_mid_mean,
    f.optical_ndwi11_late_mean,
    f.optical_ndwi11_mid_minus_early_mean,
    f.optical_ndwi11_late_minus_mid_mean,
    f.optical_ndwi11_full_std,
    f.optical_ndwi11_max_value,
    f.optical_ndwi11_min_value,
    f.optical_ndwi11_amplitude,
    f.optical_ndwi11_age_at_peak,
    f.optical_ndwi11_rel_age_at_peak,
    f.optical_ndwi11_auc_full,
    f.optical_ndwi11_auc_early,
    f.optical_ndwi11_auc_mid,
    f.optical_ndwi11_auc_late,
    f.optical_ndwi11_last_090_mean,
    f.optical_ndwi11_last_090_slope,
    f.optical_ndwi11_cycle_slope,

    f.optical_msi11_obs_count,
    f.optical_msi11_full_mean,
    f.optical_msi11_early_mean,
    f.optical_msi11_mid_mean,
    f.optical_msi11_late_mean,
    f.optical_msi11_mid_minus_early_mean,
    f.optical_msi11_late_minus_mid_mean,
    f.optical_msi11_full_std,
    f.optical_msi11_max_value,
    f.optical_msi11_min_value,
    f.optical_msi11_amplitude,
    f.optical_msi11_age_at_peak,
    f.optical_msi11_rel_age_at_peak,
    f.optical_msi11_auc_full,
    f.optical_msi11_auc_early,
    f.optical_msi11_auc_mid,
    f.optical_msi11_auc_late,
    f.optical_msi11_last_090_mean,
    f.optical_msi11_last_090_slope,
    f.optical_msi11_cycle_slope,

    f.optical_ndvire_obs_count,
    f.optical_ndvire_full_mean,
    f.optical_ndvire_early_mean,
    f.optical_ndvire_mid_mean,
    f.optical_ndvire_late_mean,
    f.optical_ndvire_mid_minus_early_mean,
    f.optical_ndvire_late_minus_mid_mean,
    f.optical_ndvire_full_std,
    f.optical_ndvire_max_value,
    f.optical_ndvire_min_value,
    f.optical_ndvire_amplitude,
    f.optical_ndvire_age_at_peak,
    f.optical_ndvire_rel_age_at_peak,
    f.optical_ndvire_auc_full,
    f.optical_ndvire_auc_early,
    f.optical_ndvire_auc_mid,
    f.optical_ndvire_auc_late,
    f.optical_ndvire_last_090_mean,
    f.optical_ndvire_last_090_slope,
    f.optical_ndvire_cycle_slope,

    f.optical_cire_obs_count,
    f.optical_cire_full_mean,
    f.optical_cire_early_mean,
    f.optical_cire_mid_mean,
    f.optical_cire_late_mean,
    f.optical_cire_mid_minus_early_mean,
    f.optical_cire_late_minus_mid_mean,
    f.optical_cire_full_std,
    f.optical_cire_max_value,
    f.optical_cire_min_value,
    f.optical_cire_amplitude,
    f.optical_cire_age_at_peak,
    f.optical_cire_rel_age_at_peak,
    f.optical_cire_auc_full,
    f.optical_cire_auc_early,
    f.optical_cire_auc_mid,
    f.optical_cire_auc_late,
    f.optical_cire_last_090_mean,
    f.optical_cire_last_090_slope,
    f.optical_cire_cycle_slope
FROM base_cycles b
LEFT JOIN features_wide f USING (cod_cg_zafra);
