-- tch_features_v2_feature_bank.sql
--
-- Shared feature base for the TCH v2 ablation datasets.
--
-- Unit:
--   one row per cod_cg_zafra.
--
-- Design:
--   Build one reusable, evidence-oriented base table around cycle timing,
--   compact agronomy, optical phenology, phase climate, compact ENSO, and
--   parsimonious SAR. Thin v2_* views should select from this view instead of
--   copying the feature logic.
--
-- Usage:
--   CREATE OR REPLACE VIEW public.tch_features_v2_feature_bank AS ...

CREATE OR REPLACE VIEW public.tch_features_v2_feature_bank AS
WITH raw_valid AS (
    SELECT
        cod_cg_zafra,
        cod_cg,
        zafra_norm,
        fecha_stac,
        area,
        tch,
        tc,
        cierre_ciclo,
        edad_de_cultivo::double precision AS edad_de_cultivo,
        (fecha_stac - (edad_de_cultivo * INTERVAL '1 day'))::date AS fecha_inicio_obs,

        prod_variedad,
        prod_grupo_de_suelo,
        prod_grupo_de_humedad,
        prod_codigo_zae,
        prod_finca,
        prod_familia_de_suelo,
        prod_no_corte,

        stac_ndvi_promedio,
        stac_evi2_promedio,
        stac_lswi_promedio,
        stac_gndvi_promedio,
        stac_ndre_promedio,
        stac_cire_promedio,

        enso_oni,
        enso_nino34,
        enso_soi,
        enso_mei,
        enso_pdo,

        radar_asc_vh_promedio,
        radar_asc_vv_promedio,
        radar_asc_ratio_promedio,
        radar_asc_rvi_promedio,
        radar_asc_days_delta,
        radar_desc_vh_promedio,
        radar_desc_vv_promedio,
        radar_desc_ratio_promedio,
        radar_desc_rvi_promedio,
        radar_desc_days_delta,

        CASE
            WHEN radar_asc_vh_promedio IS NULL THEN radar_desc_vh_promedio
            WHEN radar_desc_vh_promedio IS NULL THEN radar_asc_vh_promedio
            WHEN abs(radar_asc_days_delta) <= abs(radar_desc_days_delta) THEN radar_asc_vh_promedio
            ELSE radar_desc_vh_promedio
        END AS radar_any_vh_promedio,
        CASE
            WHEN radar_asc_vv_promedio IS NULL THEN radar_desc_vv_promedio
            WHEN radar_desc_vv_promedio IS NULL THEN radar_asc_vv_promedio
            WHEN abs(radar_asc_days_delta) <= abs(radar_desc_days_delta) THEN radar_asc_vv_promedio
            ELSE radar_desc_vv_promedio
        END AS radar_any_vv_promedio,
        CASE
            WHEN radar_asc_ratio_promedio IS NULL THEN radar_desc_ratio_promedio
            WHEN radar_desc_ratio_promedio IS NULL THEN radar_asc_ratio_promedio
            WHEN abs(radar_asc_days_delta) <= abs(radar_desc_days_delta) THEN radar_asc_ratio_promedio
            ELSE radar_desc_ratio_promedio
        END AS radar_any_ratio_promedio,
        CASE
            WHEN radar_asc_rvi_promedio IS NULL THEN radar_desc_rvi_promedio
            WHEN radar_desc_rvi_promedio IS NULL THEN radar_asc_rvi_promedio
            WHEN abs(radar_asc_days_delta) <= abs(radar_desc_days_delta) THEN radar_asc_rvi_promedio
            ELSE radar_desc_rvi_promedio
        END AS radar_any_rvi_promedio
    FROM public.tch_raw_longitudinal_v2
    WHERE tch IS NOT NULL
      AND cod_cg_zafra IS NOT NULL
      AND zafra_norm IS NOT NULL
      AND area IS NOT NULL
      AND ciclo_valido = true
      AND edad_de_cultivo IS NOT NULL
      AND edad_de_cultivo >= 0
),
base_cycles AS (
    SELECT
        cod_cg_zafra,
        max(cod_cg) AS cod_cg,
        max(zafra_norm) AS zafra_norm,
        max(area) AS area,
        max(tch) AS tch,
        max(tc) AS tc,
        min(fecha_inicio_obs) AS fecha_inicio_ciclo,
        max(cierre_ciclo)::date AS fecha_fin_ciclo,
        max(edad_de_cultivo) AS cycle_age_max,

        max(prod_variedad) AS prod_variedad,
        max(prod_grupo_de_suelo) AS prod_grupo_de_suelo,
        max(prod_grupo_de_humedad) AS prod_grupo_de_humedad,
        max(prod_codigo_zae) AS prod_codigo_zae,
        max(prod_finca) AS prod_finca,
        max(prod_familia_de_suelo) AS prod_familia_de_suelo,
        max(prod_no_corte) AS prod_no_corte,

        count(*) AS cycle_obs_count,
        count(*) FILTER (WHERE edad_de_cultivo < 120) AS early_obs_count,
        count(*) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS mid_obs_count,
        count(*) FILTER (WHERE edad_de_cultivo >= 240) AS late_obs_count,
        count(stac_ndvi_promedio) AS optical_obs_count,
        1.0 - (count(stac_ndvi_promedio)::double precision / nullif(count(*), 0)) AS optical_missing_rate,
        count(radar_any_vh_promedio) AS sar_obs_count,
        1.0 - (count(radar_any_vh_promedio)::double precision / nullif(count(*), 0)) AS sar_missing_rate
    FROM raw_valid
    GROUP BY cod_cg_zafra
),
optical_sequence AS (
    SELECT
        r.*,
        b.cycle_age_max,
        lag(r.edad_de_cultivo) OVER (PARTITION BY r.cod_cg_zafra ORDER BY r.edad_de_cultivo, r.fecha_stac) AS prev_age,
        lead(r.edad_de_cultivo) OVER (PARTITION BY r.cod_cg_zafra ORDER BY r.edad_de_cultivo, r.fecha_stac) AS next_age,
        max(r.stac_ndvi_promedio) OVER (PARTITION BY r.cod_cg_zafra) AS ndvi_peak,
        max(r.stac_evi2_promedio) OVER (PARTITION BY r.cod_cg_zafra) AS evi2_peak,
        max(r.stac_lswi_promedio) OVER (PARTITION BY r.cod_cg_zafra) AS lswi_peak,
        max(r.stac_gndvi_promedio) OVER (PARTITION BY r.cod_cg_zafra) AS gndvi_peak,
        max(r.stac_ndre_promedio) OVER (PARTITION BY r.cod_cg_zafra) AS ndre_peak,
        max(r.stac_cire_promedio) OVER (PARTITION BY r.cod_cg_zafra) AS cire_peak
    FROM raw_valid r
    JOIN base_cycles b ON b.cod_cg_zafra = r.cod_cg_zafra
),
optical_weighted AS (
    SELECT
        *,
        greatest(0.0, coalesce((prev_age + edad_de_cultivo) / 2.0, edad_de_cultivo - 7.5)) AS obs_start_age,
        least(cycle_age_max, coalesce((edad_de_cultivo + next_age) / 2.0, edad_de_cultivo + 7.5)) AS obs_end_age
    FROM optical_sequence
),
optical_features AS (
    SELECT
        cod_cg_zafra,

        avg(stac_ndvi_promedio) FILTER (WHERE edad_de_cultivo < 120) AS ndvi_early_mean,
        avg(stac_ndvi_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS ndvi_mid_mean,
        avg(stac_ndvi_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS ndvi_late_mean,
        sum(stac_ndvi_promedio * greatest(0.0, obs_end_age - obs_start_age)) AS ndvi_auc_full,
        sum(stac_ndvi_promedio * greatest(0.0, least(obs_end_age, 120.0) - greatest(obs_start_age, 0.0))) AS ndvi_auc_early,
        sum(stac_ndvi_promedio * greatest(0.0, least(obs_end_age, 240.0) - greatest(obs_start_age, 120.0))) AS ndvi_auc_mid,
        sum(stac_ndvi_promedio * greatest(0.0, obs_end_age - greatest(obs_start_age, 240.0))) AS ndvi_auc_late,
        max(stac_ndvi_promedio) AS ndvi_peak_value,
        (array_agg(edad_de_cultivo ORDER BY stac_ndvi_promedio DESC NULLS LAST, edad_de_cultivo) FILTER (WHERE stac_ndvi_promedio IS NOT NULL))[1] AS ndvi_age_at_peak,
        regr_slope(stac_ndvi_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo < 240) AS ndvi_rise_slope,
        regr_slope(stac_ndvi_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo >= 240) AS ndvi_senescence_slope,
        sum(greatest(0.0, obs_end_age - obs_start_age)) FILTER (WHERE stac_ndvi_promedio >= 0.8 * ndvi_peak) AS ndvi_duration_above_80pct_peak,

        avg(stac_evi2_promedio) FILTER (WHERE edad_de_cultivo < 120) AS evi2_early_mean,
        avg(stac_evi2_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS evi2_mid_mean,
        avg(stac_evi2_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS evi2_late_mean,
        sum(stac_evi2_promedio * greatest(0.0, obs_end_age - obs_start_age)) AS evi2_auc_full,
        sum(stac_evi2_promedio * greatest(0.0, least(obs_end_age, 120.0) - greatest(obs_start_age, 0.0))) AS evi2_auc_early,
        sum(stac_evi2_promedio * greatest(0.0, least(obs_end_age, 240.0) - greatest(obs_start_age, 120.0))) AS evi2_auc_mid,
        sum(stac_evi2_promedio * greatest(0.0, obs_end_age - greatest(obs_start_age, 240.0))) AS evi2_auc_late,
        max(stac_evi2_promedio) AS evi2_peak_value,
        (array_agg(edad_de_cultivo ORDER BY stac_evi2_promedio DESC NULLS LAST, edad_de_cultivo) FILTER (WHERE stac_evi2_promedio IS NOT NULL))[1] AS evi2_age_at_peak,
        regr_slope(stac_evi2_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo < 240) AS evi2_rise_slope,
        regr_slope(stac_evi2_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo >= 240) AS evi2_senescence_slope,
        sum(greatest(0.0, obs_end_age - obs_start_age)) FILTER (WHERE stac_evi2_promedio >= 0.8 * evi2_peak) AS evi2_duration_above_80pct_peak,

        avg(stac_lswi_promedio) FILTER (WHERE edad_de_cultivo < 120) AS lswi_early_mean,
        avg(stac_lswi_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS lswi_mid_mean,
        avg(stac_lswi_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS lswi_late_mean,
        sum(stac_lswi_promedio * greatest(0.0, obs_end_age - obs_start_age)) AS lswi_auc_full,
        sum(stac_lswi_promedio * greatest(0.0, least(obs_end_age, 120.0) - greatest(obs_start_age, 0.0))) AS lswi_auc_early,
        sum(stac_lswi_promedio * greatest(0.0, least(obs_end_age, 240.0) - greatest(obs_start_age, 120.0))) AS lswi_auc_mid,
        sum(stac_lswi_promedio * greatest(0.0, obs_end_age - greatest(obs_start_age, 240.0))) AS lswi_auc_late,
        max(stac_lswi_promedio) AS lswi_peak_value,
        (array_agg(edad_de_cultivo ORDER BY stac_lswi_promedio DESC NULLS LAST, edad_de_cultivo) FILTER (WHERE stac_lswi_promedio IS NOT NULL))[1] AS lswi_age_at_peak,
        regr_slope(stac_lswi_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo < 240) AS lswi_rise_slope,
        regr_slope(stac_lswi_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo >= 240) AS lswi_senescence_slope,
        sum(greatest(0.0, obs_end_age - obs_start_age)) FILTER (WHERE stac_lswi_promedio >= 0.8 * lswi_peak) AS lswi_duration_above_80pct_peak,

        avg(stac_gndvi_promedio) FILTER (WHERE edad_de_cultivo < 120) AS gndvi_early_mean,
        avg(stac_gndvi_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS gndvi_mid_mean,
        avg(stac_gndvi_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS gndvi_late_mean,
        sum(stac_gndvi_promedio * greatest(0.0, obs_end_age - obs_start_age)) AS gndvi_auc_full,
        sum(stac_gndvi_promedio * greatest(0.0, least(obs_end_age, 120.0) - greatest(obs_start_age, 0.0))) AS gndvi_auc_early,
        sum(stac_gndvi_promedio * greatest(0.0, least(obs_end_age, 240.0) - greatest(obs_start_age, 120.0))) AS gndvi_auc_mid,
        sum(stac_gndvi_promedio * greatest(0.0, obs_end_age - greatest(obs_start_age, 240.0))) AS gndvi_auc_late,
        max(stac_gndvi_promedio) AS gndvi_peak_value,
        (array_agg(edad_de_cultivo ORDER BY stac_gndvi_promedio DESC NULLS LAST, edad_de_cultivo) FILTER (WHERE stac_gndvi_promedio IS NOT NULL))[1] AS gndvi_age_at_peak,
        regr_slope(stac_gndvi_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo < 240) AS gndvi_rise_slope,
        regr_slope(stac_gndvi_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo >= 240) AS gndvi_senescence_slope,
        sum(greatest(0.0, obs_end_age - obs_start_age)) FILTER (WHERE stac_gndvi_promedio >= 0.8 * gndvi_peak) AS gndvi_duration_above_80pct_peak,

        avg(stac_ndre_promedio) FILTER (WHERE edad_de_cultivo < 120) AS ndre_early_mean,
        avg(stac_ndre_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS ndre_mid_mean,
        avg(stac_ndre_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS ndre_late_mean,
        sum(stac_ndre_promedio * greatest(0.0, obs_end_age - obs_start_age)) AS ndre_auc_full,
        sum(stac_ndre_promedio * greatest(0.0, least(obs_end_age, 120.0) - greatest(obs_start_age, 0.0))) AS ndre_auc_early,
        sum(stac_ndre_promedio * greatest(0.0, least(obs_end_age, 240.0) - greatest(obs_start_age, 120.0))) AS ndre_auc_mid,
        sum(stac_ndre_promedio * greatest(0.0, obs_end_age - greatest(obs_start_age, 240.0))) AS ndre_auc_late,
        max(stac_ndre_promedio) AS ndre_peak_value,
        (array_agg(edad_de_cultivo ORDER BY stac_ndre_promedio DESC NULLS LAST, edad_de_cultivo) FILTER (WHERE stac_ndre_promedio IS NOT NULL))[1] AS ndre_age_at_peak,
        regr_slope(stac_ndre_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo < 240) AS ndre_rise_slope,
        regr_slope(stac_ndre_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo >= 240) AS ndre_senescence_slope,
        sum(greatest(0.0, obs_end_age - obs_start_age)) FILTER (WHERE stac_ndre_promedio >= 0.8 * ndre_peak) AS ndre_duration_above_80pct_peak,

        avg(stac_cire_promedio) FILTER (WHERE edad_de_cultivo < 120) AS cire_early_mean,
        avg(stac_cire_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS cire_mid_mean,
        avg(stac_cire_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS cire_late_mean,
        sum(stac_cire_promedio * greatest(0.0, obs_end_age - obs_start_age)) AS cire_auc_full,
        sum(stac_cire_promedio * greatest(0.0, least(obs_end_age, 120.0) - greatest(obs_start_age, 0.0))) AS cire_auc_early,
        sum(stac_cire_promedio * greatest(0.0, least(obs_end_age, 240.0) - greatest(obs_start_age, 120.0))) AS cire_auc_mid,
        sum(stac_cire_promedio * greatest(0.0, obs_end_age - greatest(obs_start_age, 240.0))) AS cire_auc_late,
        max(stac_cire_promedio) AS cire_peak_value,
        (array_agg(edad_de_cultivo ORDER BY stac_cire_promedio DESC NULLS LAST, edad_de_cultivo) FILTER (WHERE stac_cire_promedio IS NOT NULL))[1] AS cire_age_at_peak,
        regr_slope(stac_cire_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo < 240) AS cire_rise_slope,
        regr_slope(stac_cire_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo >= 240) AS cire_senescence_slope,
        sum(greatest(0.0, obs_end_age - obs_start_age)) FILTER (WHERE stac_cire_promedio >= 0.8 * cire_peak) AS cire_duration_above_80pct_peak
    FROM optical_weighted
    GROUP BY cod_cg_zafra
),
climate_by_pentad AS (
    SELECT
        b.cod_cg_zafra,
        (c.fecha_inicio::date - b.fecha_inicio_ciclo::date)::double precision AS climate_age,
        c.precipitacion_sum,
        c.eto_sum,
        c.radiacion_sum,
        c.temperatura_max,
        c.temperatura_min,
        c.temperatura_mean,
        c.humedad_relativa,
        greatest(c.temperatura_mean - 10.0, 0.0) * 5.0 AS gdd_10c,
        c.precipitacion_sum - c.eto_sum AS water_balance,
        c.precipitacion_sum / nullif(c.eto_sum, 0) AS water_ratio,
        CASE WHEN c.precipitacion_sum < c.eto_sum THEN 1 ELSE 0 END AS dry_pentad_flag,
        CASE WHEN c.temperatura_max >= 34 THEN 1 ELSE 0 END AS heat_pentad_flag
    FROM base_cycles b
    LEFT JOIN public.clima_lote_pentada_new c
      ON c.cod_cg_zafra = b.cod_cg_zafra
     AND c.fecha_inicio::date >= b.fecha_inicio_ciclo
     AND c.fecha_inicio::date <= b.fecha_fin_ciclo
),
climate_features AS (
    SELECT
        cod_cg_zafra,
        count(*) FILTER (WHERE climate_age IS NOT NULL) AS climate_pentad_count,

        sum(precipitacion_sum) FILTER (WHERE climate_age < 120) AS prec_early_total,
        sum(precipitacion_sum) FILTER (WHERE climate_age >= 120 AND climate_age < 240) AS prec_mid_total,
        sum(precipitacion_sum) FILTER (WHERE climate_age >= 240) AS prec_late_total,
        sum(precipitacion_sum) AS prec_full_total,

        sum(eto_sum) FILTER (WHERE climate_age < 120) AS eto_early_total,
        sum(eto_sum) FILTER (WHERE climate_age >= 120 AND climate_age < 240) AS eto_mid_total,
        sum(eto_sum) FILTER (WHERE climate_age >= 240) AS eto_late_total,
        sum(eto_sum) AS eto_full_total,

        sum(water_balance) FILTER (WHERE climate_age < 120) AS water_balance_early_total,
        sum(water_balance) FILTER (WHERE climate_age >= 120 AND climate_age < 240) AS water_balance_mid_total,
        sum(water_balance) FILTER (WHERE climate_age >= 240) AS water_balance_late_total,
        sum(water_balance) AS water_balance_full_total,

        sum(precipitacion_sum) FILTER (WHERE climate_age < 120) / nullif(sum(eto_sum) FILTER (WHERE climate_age < 120), 0) AS water_ratio_early,
        sum(precipitacion_sum) FILTER (WHERE climate_age >= 120 AND climate_age < 240) / nullif(sum(eto_sum) FILTER (WHERE climate_age >= 120 AND climate_age < 240), 0) AS water_ratio_mid,
        sum(precipitacion_sum) FILTER (WHERE climate_age >= 240) / nullif(sum(eto_sum) FILTER (WHERE climate_age >= 240), 0) AS water_ratio_late,
        sum(precipitacion_sum) / nullif(sum(eto_sum), 0) AS water_ratio_full,

        sum(dry_pentad_flag) FILTER (WHERE climate_age < 120) AS dry_pentad_count_early,
        sum(dry_pentad_flag) FILTER (WHERE climate_age >= 120 AND climate_age < 240) AS dry_pentad_count_mid,
        sum(dry_pentad_flag) FILTER (WHERE climate_age >= 240) AS dry_pentad_count_late,
        sum(dry_pentad_flag) AS dry_pentad_count_full,

        sum(heat_pentad_flag) FILTER (WHERE climate_age < 120) AS heat_pentad_count_early,
        sum(heat_pentad_flag) FILTER (WHERE climate_age >= 120 AND climate_age < 240) AS heat_pentad_count_mid,
        sum(heat_pentad_flag) FILTER (WHERE climate_age >= 240) AS heat_pentad_count_late,
        sum(heat_pentad_flag) AS heat_pentad_count_full,

        sum(gdd_10c) FILTER (WHERE climate_age < 120) AS gdd_early_total,
        sum(gdd_10c) FILTER (WHERE climate_age >= 120 AND climate_age < 240) AS gdd_mid_total,
        sum(gdd_10c) FILTER (WHERE climate_age >= 240) AS gdd_late_total,
        sum(gdd_10c) AS gdd_full_total,

        sum(radiacion_sum) FILTER (WHERE climate_age < 120) AS rad_early_total,
        sum(radiacion_sum) FILTER (WHERE climate_age >= 120 AND climate_age < 240) AS rad_mid_total,
        sum(radiacion_sum) FILTER (WHERE climate_age >= 240) AS rad_late_total,
        sum(radiacion_sum) AS rad_full_total,

        avg(temperatura_mean) FILTER (WHERE climate_age < 120) AS tmean_early_mean,
        avg(temperatura_mean) FILTER (WHERE climate_age >= 120 AND climate_age < 240) AS tmean_mid_mean,
        avg(temperatura_mean) FILTER (WHERE climate_age >= 240) AS tmean_late_mean,
        avg(temperatura_mean) AS tmean_full_mean,
        avg(temperatura_max) FILTER (WHERE climate_age < 120) AS tmax_early_mean,
        avg(temperatura_max) FILTER (WHERE climate_age >= 120 AND climate_age < 240) AS tmax_mid_mean,
        avg(temperatura_max) FILTER (WHERE climate_age >= 240) AS tmax_late_mean,
        avg(temperatura_min) FILTER (WHERE climate_age < 120) AS tmin_early_mean,
        avg(temperatura_min) FILTER (WHERE climate_age >= 120 AND climate_age < 240) AS tmin_mid_mean,
        avg(temperatura_min) FILTER (WHERE climate_age >= 240) AS tmin_late_mean,
        avg(humedad_relativa) AS rh_full_mean
    FROM climate_by_pentad
    GROUP BY cod_cg_zafra
),
enso_by_month AS (
    SELECT
        b.cod_cg_zafra,
        e.date,
        e.oni,
        e.nino34,
        e.soi,
        e.mei,
        e.pdo,
        (e.date::date - b.fecha_inicio_ciclo::date)::double precision AS enso_day
    FROM base_cycles b
    LEFT JOIN public.enso e
      ON e.date::date >= b.fecha_inicio_ciclo - INTERVAL '180 days'
     AND e.date::date < b.fecha_inicio_ciclo + INTERVAL '180 days'
),
enso_features AS (
    SELECT
        cod_cg_zafra,
        avg(nino34) FILTER (WHERE enso_day < 0) AS nino34_precycle_mean,
        avg(nino34) FILTER (WHERE enso_day >= 0 AND enso_day < 180) AS nino34_first_180d_mean,
        max(abs(nino34)) FILTER (WHERE enso_day >= 0 AND enso_day < 180) AS nino34_abs_max_first_180d,
        avg(oni) FILTER (WHERE enso_day < 0) AS oni_precycle_mean,
        avg(oni) FILTER (WHERE enso_day >= 0 AND enso_day < 180) AS oni_first_180d_mean,
        avg(soi) FILTER (WHERE enso_day < 0) AS soi_precycle_mean,
        avg(soi) FILTER (WHERE enso_day >= 0 AND enso_day < 180) AS soi_first_180d_mean,
        avg(mei) FILTER (WHERE enso_day < 0) AS mei_precycle_mean,
        avg(pdo) FILTER (WHERE enso_day < 0) AS pdo_precycle_mean,
        CASE
            WHEN avg(oni) FILTER (WHERE enso_day < 0) >= 0.5 THEN 'el_nino'
            WHEN avg(oni) FILTER (WHERE enso_day < 0) <= -0.5 THEN 'la_nina'
            WHEN avg(oni) FILTER (WHERE enso_day < 0) IS NULL THEN NULL
            ELSE 'neutral'
        END AS enso_phase_precycle
    FROM enso_by_month
    GROUP BY cod_cg_zafra
),
sar_features AS (
    SELECT
        cod_cg_zafra,
        avg(radar_any_vh_promedio) FILTER (WHERE edad_de_cultivo < 120) AS sar_vh_early_mean,
        avg(radar_any_vh_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS sar_vh_mid_mean,
        avg(radar_any_vh_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS sar_vh_late_mean,
        regr_slope(radar_any_vh_promedio, edad_de_cultivo) AS sar_vh_slope,

        avg(radar_any_vv_promedio) FILTER (WHERE edad_de_cultivo < 120) AS sar_vv_early_mean,
        avg(radar_any_vv_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS sar_vv_mid_mean,
        avg(radar_any_vv_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS sar_vv_late_mean,
        regr_slope(radar_any_vv_promedio, edad_de_cultivo) AS sar_vv_slope,

        avg(radar_any_ratio_promedio) FILTER (WHERE edad_de_cultivo < 120) AS sar_ratio_early_mean,
        avg(radar_any_ratio_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS sar_ratio_mid_mean,
        avg(radar_any_ratio_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS sar_ratio_late_mean,
        regr_slope(radar_any_ratio_promedio, edad_de_cultivo) AS sar_ratio_slope,

        avg(radar_asc_vh_promedio) AS sar_asc_vh_mean,
        avg(radar_desc_vh_promedio) AS sar_desc_vh_mean,
        avg(radar_asc_vh_promedio) - avg(radar_desc_vh_promedio) AS sar_vh_asc_desc_diff,

        avg(radar_any_rvi_promedio) FILTER (WHERE edad_de_cultivo < 120) AS sar_rvi_early_mean,
        avg(radar_any_rvi_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS sar_rvi_mid_mean,
        avg(radar_any_rvi_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS sar_rvi_late_mean,
        regr_slope(radar_any_rvi_promedio, edad_de_cultivo) AS sar_rvi_slope
    FROM raw_valid
    GROUP BY cod_cg_zafra
)
SELECT
    b.*,
    o.ndvi_early_mean,
    o.ndvi_mid_mean,
    o.ndvi_late_mean,
    o.ndvi_mid_mean - o.ndvi_early_mean AS ndvi_mid_minus_early_mean,
    o.ndvi_late_mean - o.ndvi_mid_mean AS ndvi_late_minus_mid_mean,
    o.ndvi_auc_full,
    o.ndvi_auc_early,
    o.ndvi_auc_mid,
    o.ndvi_auc_late,
    o.ndvi_peak_value,
    o.ndvi_age_at_peak,
    o.ndvi_rise_slope,
    o.ndvi_senescence_slope,
    o.ndvi_duration_above_80pct_peak,

    o.evi2_early_mean,
    o.evi2_mid_mean,
    o.evi2_late_mean,
    o.evi2_mid_mean - o.evi2_early_mean AS evi2_mid_minus_early_mean,
    o.evi2_late_mean - o.evi2_mid_mean AS evi2_late_minus_mid_mean,
    o.evi2_auc_full,
    o.evi2_auc_early,
    o.evi2_auc_mid,
    o.evi2_auc_late,
    o.evi2_peak_value,
    o.evi2_age_at_peak,
    o.evi2_rise_slope,
    o.evi2_senescence_slope,
    o.evi2_duration_above_80pct_peak,

    o.lswi_early_mean,
    o.lswi_mid_mean,
    o.lswi_late_mean,
    o.lswi_mid_mean - o.lswi_early_mean AS lswi_mid_minus_early_mean,
    o.lswi_late_mean - o.lswi_mid_mean AS lswi_late_minus_mid_mean,
    o.lswi_auc_full,
    o.lswi_auc_early,
    o.lswi_auc_mid,
    o.lswi_auc_late,
    o.lswi_peak_value,
    o.lswi_age_at_peak,
    o.lswi_rise_slope,
    o.lswi_senescence_slope,
    o.lswi_duration_above_80pct_peak,

    o.gndvi_early_mean,
    o.gndvi_mid_mean,
    o.gndvi_late_mean,
    o.gndvi_mid_mean - o.gndvi_early_mean AS gndvi_mid_minus_early_mean,
    o.gndvi_late_mean - o.gndvi_mid_mean AS gndvi_late_minus_mid_mean,
    o.gndvi_auc_full,
    o.gndvi_auc_early,
    o.gndvi_auc_mid,
    o.gndvi_auc_late,
    o.gndvi_peak_value,
    o.gndvi_age_at_peak,
    o.gndvi_rise_slope,
    o.gndvi_senescence_slope,
    o.gndvi_duration_above_80pct_peak,

    o.ndre_early_mean,
    o.ndre_mid_mean,
    o.ndre_late_mean,
    o.ndre_mid_mean - o.ndre_early_mean AS ndre_mid_minus_early_mean,
    o.ndre_late_mean - o.ndre_mid_mean AS ndre_late_minus_mid_mean,
    o.ndre_auc_full,
    o.ndre_auc_early,
    o.ndre_auc_mid,
    o.ndre_auc_late,
    o.ndre_peak_value,
    o.ndre_age_at_peak,
    o.ndre_rise_slope,
    o.ndre_senescence_slope,
    o.ndre_duration_above_80pct_peak,

    o.cire_early_mean,
    o.cire_mid_mean,
    o.cire_late_mean,
    o.cire_mid_mean - o.cire_early_mean AS cire_mid_minus_early_mean,
    o.cire_late_mean - o.cire_mid_mean AS cire_late_minus_mid_mean,
    o.cire_auc_full,
    o.cire_auc_early,
    o.cire_auc_mid,
    o.cire_auc_late,
    o.cire_peak_value,
    o.cire_age_at_peak,
    o.cire_rise_slope,
    o.cire_senescence_slope,
    o.cire_duration_above_80pct_peak,

    c.climate_pentad_count,
    c.prec_early_total,
    c.prec_mid_total,
    c.prec_late_total,
    c.prec_full_total,
    c.eto_early_total,
    c.eto_mid_total,
    c.eto_late_total,
    c.eto_full_total,
    c.water_balance_early_total,
    c.water_balance_mid_total,
    c.water_balance_late_total,
    c.water_balance_full_total,
    c.water_ratio_early,
    c.water_ratio_mid,
    c.water_ratio_late,
    c.water_ratio_full,
    c.dry_pentad_count_early,
    c.dry_pentad_count_mid,
    c.dry_pentad_count_late,
    c.dry_pentad_count_full,
    c.heat_pentad_count_early,
    c.heat_pentad_count_mid,
    c.heat_pentad_count_late,
    c.heat_pentad_count_full,
    c.gdd_early_total,
    c.gdd_mid_total,
    c.gdd_late_total,
    c.gdd_full_total,
    c.rad_early_total,
    c.rad_mid_total,
    c.rad_late_total,
    c.rad_full_total,
    c.tmean_early_mean,
    c.tmean_mid_mean,
    c.tmean_late_mean,
    c.tmean_full_mean,
    c.tmax_early_mean,
    c.tmax_mid_mean,
    c.tmax_late_mean,
    c.tmin_early_mean,
    c.tmin_mid_mean,
    c.tmin_late_mean,
    c.rh_full_mean,
    e.nino34_precycle_mean,
    e.nino34_first_180d_mean,
    e.nino34_abs_max_first_180d,
    e.oni_precycle_mean,
    e.oni_first_180d_mean,
    e.soi_precycle_mean,
    e.soi_first_180d_mean,
    e.mei_precycle_mean,
    e.pdo_precycle_mean,
    e.enso_phase_precycle,
    s.sar_vh_early_mean,
    s.sar_vh_mid_mean,
    s.sar_vh_late_mean,
    s.sar_vh_slope,
    s.sar_vv_early_mean,
    s.sar_vv_mid_mean,
    s.sar_vv_late_mean,
    s.sar_vv_slope,
    s.sar_ratio_early_mean,
    s.sar_ratio_mid_mean,
    s.sar_ratio_late_mean,
    s.sar_ratio_slope,
    s.sar_asc_vh_mean,
    s.sar_desc_vh_mean,
    s.sar_vh_asc_desc_diff,
    s.sar_rvi_early_mean,
    s.sar_rvi_mid_mean,
    s.sar_rvi_late_mean,
    s.sar_rvi_slope
FROM base_cycles b
LEFT JOIN optical_features o ON o.cod_cg_zafra = b.cod_cg_zafra
LEFT JOIN climate_features c ON c.cod_cg_zafra = b.cod_cg_zafra
LEFT JOIN enso_features e ON e.cod_cg_zafra = b.cod_cg_zafra
LEFT JOIN sar_features s ON s.cod_cg_zafra = b.cod_cg_zafra;
