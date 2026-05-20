-- tch_climate_ablation_v4.sql
--
-- Secondary climate feature block for later ablation tests.
--
-- Shape:
--   one row per valid cod_cg_zafra
--
-- Intent:
--   Keep plausible but lower-priority climate signals separate from the core:
--   harvest windows, leaf wetness/heat-index summaries, low-radiation stress,
--   and a few short-window recency descriptors.
--
-- Source rules:
--   - public.tch_raw_longitudinal_v4 supplies validated cycle bounds, target,
--     and model metadata.
--   - public.clima_lote_pentada_new supplies the direct pentadal climate
--     sequence. Do not sample climate from the optical-date spine.
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
        max(r.edad_de_cultivo)::double precision AS cycle_age_max
    FROM public.tch_raw_longitudinal_v4 r
    WHERE r.tch IS NOT NULL
      AND r.tch BETWEEN 20 AND 150
      AND r.ciclo_valido = true
      AND r.cod_cg_zafra IS NOT NULL
    GROUP BY r.cod_cg_zafra
),
climate_seq AS (
    SELECT
        b.cod_cg_zafra,
        b.cod_cg,
        b.zafra_norm,
        b.fecha_inicio_ciclo,
        b.fecha_fin_ciclo,
        b.cycle_age_max,
        c.fecha_inicio::date AS clima_fecha_inicio,
        c.fecha_fin::date AS clima_fecha_fin,
        (c.fecha_inicio::date - b.fecha_inicio_ciclo)::double precision AS edad_dias,
        (b.fecha_fin_ciclo - c.fecha_inicio::date)::double precision AS days_to_harvest,
        CASE
            WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 0 AND 120 THEN 'early'
            WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 121 AND 240 THEN 'mid'
            WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) >= 241 THEN 'late'
            ELSE 'outside'
        END AS age_phase,

        NULLIF(c.precipitacion_sum::text, 'NaN')::double precision AS precip,
        NULLIF(c.eto_sum::text, 'NaN')::double precision AS eto,
        NULLIF(c.temperatura_max::text, 'NaN')::double precision AS tmax,
        NULLIF(c.temperatura_min::text, 'NaN')::double precision AS tmin,
        NULLIF(c.temperatura_mean::text, 'NaN')::double precision AS tmean,
        NULLIF(c.humedad_relativa::text, 'NaN')::double precision AS rh,
        NULLIF(c.radiacion_sum::text, 'NaN')::double precision AS rad,
        NULLIF(c.radiacion_mean::text, 'NaN')::double precision AS rad_mean,
        NULLIF(c.indice_calor_max::text, 'NaN')::double precision AS heat_index,
        NULLIF(c.mojadura_mean::text, 'NaN')::double precision AS mojadura,

        NULLIF(c.precipitacion_sum::text, 'NaN')::double precision
            - NULLIF(c.eto_sum::text, 'NaN')::double precision AS water_balance,
        CASE
            WHEN NULLIF(c.eto_sum::text, 'NaN')::double precision > 0
            THEN NULLIF(c.precipitacion_sum::text, 'NaN')::double precision
                / NULLIF(c.eto_sum::text, 'NaN')::double precision
            ELSE NULL
        END AS water_ratio,
        greatest(NULLIF(c.temperatura_mean::text, 'NaN')::double precision - 10.0, 0.0) * 5.0 AS gdd_10c,
        CASE
            WHEN NULLIF(c.precipitacion_sum::text, 'NaN')::double precision IS NULL
              OR NULLIF(c.eto_sum::text, 'NaN')::double precision IS NULL THEN NULL
            WHEN NULLIF(c.precipitacion_sum::text, 'NaN')::double precision
               < NULLIF(c.eto_sum::text, 'NaN')::double precision THEN 1.0
            ELSE 0.0
        END AS dry_pentad,
        CASE
            WHEN NULLIF(c.temperatura_max::text, 'NaN')::double precision IS NULL THEN NULL
            WHEN NULLIF(c.temperatura_max::text, 'NaN')::double precision >= 34.0 THEN 1.0
            ELSE 0.0
        END AS heat_pentad,
        CASE
            WHEN NULLIF(c.radiacion_sum::text, 'NaN')::double precision IS NULL THEN NULL
            WHEN NULLIF(c.radiacion_sum::text, 'NaN')::double precision <= 60.0 THEN 1.0
            ELSE 0.0
        END AS low_rad_pentad
    FROM base_cycles b
    LEFT JOIN public.clima_lote_pentada_new c
      ON c.cod_cg = b.cod_cg
     AND c.fecha_inicio::date BETWEEN b.fecha_inicio_ciclo AND b.fecha_fin_ciclo
),
ablation_features AS (
    SELECT
        cod_cg_zafra,

        count(clima_fecha_inicio) FILTER (WHERE days_to_harvest BETWEEN 0 AND 30)::double precision AS climate_pentad_count_last_030,
        count(clima_fecha_inicio) FILTER (WHERE days_to_harvest BETWEEN 0 AND 60)::double precision AS climate_pentad_count_last_060,
        count(clima_fecha_inicio) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90)::double precision AS climate_pentad_count_last_090,
        count(clima_fecha_inicio) FILTER (WHERE days_to_harvest BETWEEN 0 AND 120)::double precision AS climate_pentad_count_last_120,

        sum(precip) FILTER (WHERE days_to_harvest BETWEEN 0 AND 30) AS climate_precip_last_030_acc,
        sum(precip) FILTER (WHERE days_to_harvest BETWEEN 0 AND 60) AS climate_precip_last_060_acc,
        sum(precip) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_precip_last_090_acc,
        sum(precip) FILTER (WHERE days_to_harvest BETWEEN 0 AND 120) AS climate_precip_last_120_acc,

        sum(water_balance) FILTER (WHERE days_to_harvest BETWEEN 0 AND 30) AS climate_water_balance_last_030_acc,
        sum(water_balance) FILTER (WHERE days_to_harvest BETWEEN 0 AND 60) AS climate_water_balance_last_060_acc,
        sum(water_balance) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_water_balance_last_090_acc,
        sum(water_balance) FILTER (WHERE days_to_harvest BETWEEN 0 AND 120) AS climate_water_balance_last_120_acc,

        sum(precip) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90)
            / NULLIF(sum(eto) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90), 0) AS climate_water_ratio_last_090,
        sum(eto) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_eto_last_090_acc,
        sum(rad) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_rad_last_090_acc,
        sum(gdd_10c) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_gdd_last_090_acc,
        avg(tmean) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_tmean_last_090_mean,
        avg(tmax) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_tmax_last_090_mean,
        avg(tmin) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_tmin_last_090_mean,
        avg(rh) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_rh_last_090_mean,
        sum(dry_pentad) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_dry_pentad_last_090_count,
        sum(heat_pentad) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_heat_pentad_last_090_count,
        sum(low_rad_pentad) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS climate_low_rad_pentad_last_090_count,

        avg(heat_index) AS climate_heat_index_full_mean,
        avg(heat_index) FILTER (WHERE age_phase = 'early') AS climate_heat_index_early_mean,
        avg(heat_index) FILTER (WHERE age_phase = 'mid') AS climate_heat_index_mid_mean,
        avg(heat_index) FILTER (WHERE age_phase = 'late') AS climate_heat_index_late_mean,

        avg(mojadura) AS climate_mojadura_full_mean,
        avg(mojadura) FILTER (WHERE age_phase = 'early') AS climate_mojadura_early_mean,
        avg(mojadura) FILTER (WHERE age_phase = 'mid') AS climate_mojadura_mid_mean,
        avg(mojadura) FILTER (WHERE age_phase = 'late') AS climate_mojadura_late_mean,

        avg(rad_mean) AS climate_rad_mean_full_mean,
        avg(rad_mean) FILTER (WHERE age_phase = 'early') AS climate_rad_mean_early_mean,
        avg(rad_mean) FILTER (WHERE age_phase = 'mid') AS climate_rad_mean_mid_mean,
        avg(rad_mean) FILTER (WHERE age_phase = 'late') AS climate_rad_mean_late_mean,

        sum(low_rad_pentad) AS climate_low_rad_pentad_count_full,
        sum(low_rad_pentad) FILTER (WHERE age_phase = 'early') AS climate_low_rad_pentad_count_early,
        sum(low_rad_pentad) FILTER (WHERE age_phase = 'mid') AS climate_low_rad_pentad_count_mid,
        sum(low_rad_pentad) FILTER (WHERE age_phase = 'late') AS climate_low_rad_pentad_count_late,

        max(precip) AS climate_precip_pentad_max_full,
        max(precip) FILTER (WHERE age_phase = 'early') AS climate_precip_pentad_max_early,
        max(precip) FILTER (WHERE age_phase = 'mid') AS climate_precip_pentad_max_mid,
        max(precip) FILTER (WHERE age_phase = 'late') AS climate_precip_pentad_max_late,

        max(tmax) AS climate_tmax_pentad_max_full,
        min(tmin) AS climate_tmin_pentad_min_full,
        max(heat_index) AS climate_heat_index_pentad_max_full,
        max(water_ratio) AS climate_water_ratio_pentad_max_full
    FROM climate_seq
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

    a.climate_pentad_count_last_030,
    a.climate_pentad_count_last_060,
    a.climate_pentad_count_last_090,
    a.climate_pentad_count_last_120,
    a.climate_precip_last_030_acc,
    a.climate_precip_last_060_acc,
    a.climate_precip_last_090_acc,
    a.climate_precip_last_120_acc,
    a.climate_water_balance_last_030_acc,
    a.climate_water_balance_last_060_acc,
    a.climate_water_balance_last_090_acc,
    a.climate_water_balance_last_120_acc,
    a.climate_water_ratio_last_090,
    a.climate_eto_last_090_acc,
    a.climate_rad_last_090_acc,
    a.climate_gdd_last_090_acc,
    a.climate_tmean_last_090_mean,
    a.climate_tmax_last_090_mean,
    a.climate_tmin_last_090_mean,
    a.climate_rh_last_090_mean,
    a.climate_dry_pentad_last_090_count,
    a.climate_heat_pentad_last_090_count,
    a.climate_low_rad_pentad_last_090_count,

    a.climate_heat_index_full_mean,
    a.climate_heat_index_early_mean,
    a.climate_heat_index_mid_mean,
    a.climate_heat_index_late_mean,
    a.climate_mojadura_full_mean,
    a.climate_mojadura_early_mean,
    a.climate_mojadura_mid_mean,
    a.climate_mojadura_late_mean,
    a.climate_rad_mean_full_mean,
    a.climate_rad_mean_early_mean,
    a.climate_rad_mean_mid_mean,
    a.climate_rad_mean_late_mean,

    a.climate_low_rad_pentad_count_full,
    a.climate_low_rad_pentad_count_early,
    a.climate_low_rad_pentad_count_mid,
    a.climate_low_rad_pentad_count_late,
    a.climate_precip_pentad_max_full,
    a.climate_precip_pentad_max_early,
    a.climate_precip_pentad_max_mid,
    a.climate_precip_pentad_max_late,
    a.climate_tmax_pentad_max_full,
    a.climate_tmin_pentad_min_full,
    a.climate_heat_index_pentad_max_full,
    a.climate_water_ratio_pentad_max_full
FROM base_cycles b
LEFT JOIN ablation_features a USING (cod_cg_zafra);
