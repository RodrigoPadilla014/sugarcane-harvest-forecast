-- tch_features_v3_temporal_bins_plus_compact.sql
--
-- Stronger v3 candidate:
--   v3 temporal age-bin wide features
--   + selected compact v2 phenology/stress features
--   + previous-cycle yield signal
--   + harvest-relative windows.

CREATE OR REPLACE VIEW public.tch_features_v3_temporal_bins_plus_compact AS
WITH wide AS (
    SELECT *
    FROM public.tch_features_v3_temporal_bins_wide
),
compact AS (
    SELECT
        cod_cg_zafra,
        ndre_peak_value AS compact_ndre_peak_value,
        lswi_late_mean AS compact_lswi_late_mean,
        evi2_peak_value AS compact_evi2_peak_value,
        gndvi_peak_value AS compact_gndvi_peak_value,
        lswi_mid_mean AS compact_lswi_mid_mean,
        evi2_late_mean AS compact_evi2_late_mean,
        ndvi_peak_value AS compact_ndvi_peak_value,
        lswi_auc_full AS compact_lswi_auc_full,
        lswi_auc_late AS compact_lswi_auc_late,
        ndre_late_mean AS compact_ndre_late_mean,
        lswi_auc_mid AS compact_lswi_auc_mid,
        evi2_mid_mean AS compact_evi2_mid_mean,
        evi2_auc_full AS compact_evi2_auc_full,
        gndvi_early_mean AS compact_gndvi_early_mean,
        tmean_full_mean AS compact_tmean_full_mean,
        evi2_auc_mid AS compact_evi2_auc_mid,
        ndre_mid_mean AS compact_ndre_mid_mean,
        evi2_early_mean AS compact_evi2_early_mean,
        ndre_early_mean AS compact_ndre_early_mean,
        ndvi_late_mean AS compact_ndvi_late_mean,
        water_balance_full_total AS compact_water_balance_full_total,
        evi2_auc_late AS compact_evi2_auc_late,
        water_balance_late_total AS compact_water_balance_late_total,
        ndre_duration_above_80pct_peak AS compact_ndre_duration_above_80pct_peak,
        water_ratio_full AS compact_water_ratio_full,
        prec_full_total AS compact_prec_full_total,
        tmean_late_mean AS compact_tmean_late_mean,
        gndvi_late_mean AS compact_gndvi_late_mean,
        tmin_late_mean AS compact_tmin_late_mean,
        prec_late_total AS compact_prec_late_total,
        ndvi_duration_above_80pct_peak AS compact_ndvi_duration_above_80pct_peak,
        dry_pentad_count_late AS compact_dry_pentad_count_late,
        lswi_late_minus_mid_mean AS compact_lswi_late_minus_mid_mean,
        gndvi_mid_mean AS compact_gndvi_mid_mean,
        evi2_duration_above_80pct_peak AS compact_evi2_duration_above_80pct_peak,
        gndvi_duration_above_80pct_peak AS compact_gndvi_duration_above_80pct_peak,
        dry_pentad_count_full AS compact_dry_pentad_count_full,
        heat_pentad_count_full AS compact_heat_pentad_count_full,
        lswi_rise_slope AS compact_lswi_rise_slope,
        tmax_late_mean AS compact_tmax_late_mean,
        water_ratio_late AS compact_water_ratio_late,
        heat_pentad_count_late AS compact_heat_pentad_count_late,
        evi2_rise_slope AS compact_evi2_rise_slope,
        eto_late_total AS compact_eto_late_total,
        ndvi_senescence_slope AS compact_ndvi_senescence_slope,
        lswi_auc_early AS compact_lswi_auc_early,
        lswi_peak_value AS compact_lswi_peak_value,
        lswi_senescence_slope AS compact_lswi_senescence_slope,
        lswi_mid_minus_early_mean AS compact_lswi_mid_minus_early_mean,
        gdd_full_total AS compact_gdd_full_total,
        ndre_rise_slope AS compact_ndre_rise_slope,
        lswi_duration_above_80pct_peak AS compact_lswi_duration_above_80pct_peak,
        lswi_age_at_peak AS compact_lswi_age_at_peak,
        ndre_late_minus_mid_mean AS compact_ndre_late_minus_mid_mean,
        gndvi_mid_minus_early_mean AS compact_gndvi_mid_minus_early_mean,
        ndvi_mid_minus_early_mean AS compact_ndvi_mid_minus_early_mean,
        evi2_late_minus_mid_mean AS compact_evi2_late_minus_mid_mean,
        evi2_senescence_slope AS compact_evi2_senescence_slope,
        evi2_mid_minus_early_mean AS compact_evi2_mid_minus_early_mean,
        rh_full_mean AS compact_rh_full_mean,
        mid_obs_count AS compact_mid_obs_count,
        early_obs_count AS compact_early_obs_count,
        gndvi_age_at_peak AS compact_gndvi_age_at_peak,
        evi2_age_at_peak AS compact_evi2_age_at_peak,
        ndvi_age_at_peak AS compact_ndvi_age_at_peak,
        gndvi_late_minus_mid_mean AS compact_gndvi_late_minus_mid_mean,
        late_obs_count AS compact_late_obs_count,
        ndre_age_at_peak AS compact_ndre_age_at_peak
    FROM public.tch_features_v3_core_optical_climate
    WHERE tch >= 20
      AND tch <= 150
),
history AS (
    SELECT
        cod_cg_zafra,
        lag(tch) OVER (PARTITION BY cod_cg ORDER BY fecha_inicio_ciclo, fecha_fin_ciclo) AS raw_tch_prev_cycle,
        lag(cycle_age_max) OVER (PARTITION BY cod_cg ORDER BY fecha_inicio_ciclo, fecha_fin_ciclo) AS cycle_age_prev_cycle,
        lag(fecha_fin_ciclo) OVER (PARTITION BY cod_cg ORDER BY fecha_inicio_ciclo, fecha_fin_ciclo) AS fecha_fin_prev_cycle
    FROM public.tch_features_v3_core_optical_climate
),
prev_cycle AS (
    SELECT
        cod_cg_zafra,
        CASE
            WHEN raw_tch_prev_cycle >= 20 AND raw_tch_prev_cycle <= 150 THEN raw_tch_prev_cycle
            ELSE NULL
        END AS tch_prev_cycle,
        cycle_age_prev_cycle,
        fecha_fin_prev_cycle
    FROM history
),
base_cycles AS (
    SELECT
        cod_cg_zafra,
        fecha_inicio_ciclo,
        fecha_fin_ciclo
    FROM wide
),
raw_valid AS (
    SELECT
        r.cod_cg_zafra,
        r.fecha_stac,
        r.edad_de_cultivo::double precision AS edad_de_cultivo,
        b.fecha_fin_ciclo,
        (b.fecha_fin_ciclo::date - r.fecha_stac::date)::double precision AS days_to_harvest,
        r.stac_ndvi_promedio,
        r.stac_evi2_promedio,
        r.stac_lswi_promedio,
        r.stac_gndvi_promedio,
        r.stac_ndre_promedio,
        r.stac_cire_promedio
    FROM public.tch_raw_longitudinal_v3 r
    JOIN base_cycles b ON b.cod_cg_zafra = r.cod_cg_zafra
    WHERE r.ciclo_valido = true
      AND r.edad_de_cultivo IS NOT NULL
      AND r.fecha_stac::date <= b.fecha_fin_ciclo
      AND r.fecha_stac::date >= b.fecha_fin_ciclo - INTERVAL '120 days'
),
harvest_optical AS (
    SELECT
        cod_cg_zafra,

        avg(stac_ndvi_promedio) FILTER (WHERE days_to_harvest <= 30) AS ndvi_mean_last_030,
        avg(stac_ndvi_promedio) FILTER (WHERE days_to_harvest <= 60) AS ndvi_mean_last_060,
        avg(stac_ndvi_promedio) FILTER (WHERE days_to_harvest <= 90) AS ndvi_mean_last_090,
        avg(stac_ndvi_promedio) FILTER (WHERE days_to_harvest <= 120) AS ndvi_mean_last_120,
        regr_slope(stac_ndvi_promedio, days_to_harvest) FILTER (WHERE days_to_harvest <= 90) AS ndvi_slope_last_090,

        avg(stac_evi2_promedio) FILTER (WHERE days_to_harvest <= 30) AS evi2_mean_last_030,
        avg(stac_evi2_promedio) FILTER (WHERE days_to_harvest <= 60) AS evi2_mean_last_060,
        avg(stac_evi2_promedio) FILTER (WHERE days_to_harvest <= 90) AS evi2_mean_last_090,
        avg(stac_evi2_promedio) FILTER (WHERE days_to_harvest <= 120) AS evi2_mean_last_120,
        regr_slope(stac_evi2_promedio, days_to_harvest) FILTER (WHERE days_to_harvest <= 90) AS evi2_slope_last_090,

        avg(stac_lswi_promedio) FILTER (WHERE days_to_harvest <= 30) AS lswi_mean_last_030,
        avg(stac_lswi_promedio) FILTER (WHERE days_to_harvest <= 60) AS lswi_mean_last_060,
        avg(stac_lswi_promedio) FILTER (WHERE days_to_harvest <= 90) AS lswi_mean_last_090,
        avg(stac_lswi_promedio) FILTER (WHERE days_to_harvest <= 120) AS lswi_mean_last_120,
        max(stac_lswi_promedio) FILTER (WHERE days_to_harvest <= 90) AS lswi_max_last_090,
        regr_slope(stac_lswi_promedio, days_to_harvest) FILTER (WHERE days_to_harvest <= 90) AS lswi_slope_last_090,

        avg(stac_gndvi_promedio) FILTER (WHERE days_to_harvest <= 90) AS gndvi_mean_last_090,
        regr_slope(stac_gndvi_promedio, days_to_harvest) FILTER (WHERE days_to_harvest <= 90) AS gndvi_slope_last_090,
        avg(stac_ndre_promedio) FILTER (WHERE days_to_harvest <= 90) AS ndre_mean_last_090,
        regr_slope(stac_ndre_promedio, days_to_harvest) FILTER (WHERE days_to_harvest <= 90) AS ndre_slope_last_090,
        avg(stac_cire_promedio) FILTER (WHERE days_to_harvest <= 90) AS cire_mean_last_090,
        regr_slope(stac_cire_promedio, days_to_harvest) FILTER (WHERE days_to_harvest <= 90) AS cire_slope_last_090,

        count(*) FILTER (WHERE days_to_harvest <= 30) AS optical_obs_count_last_030,
        count(*) FILTER (WHERE days_to_harvest <= 60) AS optical_obs_count_last_060,
        count(*) FILTER (WHERE days_to_harvest <= 90) AS optical_obs_count_last_090,
        count(*) FILTER (WHERE days_to_harvest <= 120) AS optical_obs_count_last_120
    FROM raw_valid
    GROUP BY cod_cg_zafra
),
harvest_climate_by_pentad AS (
    SELECT
        b.cod_cg_zafra,
        (b.fecha_fin_ciclo::date - c.fecha_inicio::date)::double precision AS days_to_harvest,
        c.precipitacion_sum,
        c.eto_sum,
        c.radiacion_sum,
        c.temperatura_mean,
        c.temperatura_max,
        c.temperatura_min,
        c.humedad_relativa,
        greatest(c.temperatura_mean - 10.0, 0.0) * 5.0 AS gdd_10c,
        c.precipitacion_sum - c.eto_sum AS water_balance,
        CASE WHEN c.precipitacion_sum < c.eto_sum THEN 1 ELSE 0 END AS dry_pentad_flag,
        CASE WHEN c.temperatura_max >= 34 THEN 1 ELSE 0 END AS heat_pentad_flag
    FROM base_cycles b
    LEFT JOIN public.clima_lote_pentada_new c
      ON c.cod_cg_zafra = b.cod_cg_zafra
     AND c.fecha_inicio::date <= b.fecha_fin_ciclo
     AND c.fecha_inicio::date >= b.fecha_fin_ciclo - INTERVAL '120 days'
),
harvest_climate AS (
    SELECT
        cod_cg_zafra,
        sum(precipitacion_sum) FILTER (WHERE days_to_harvest <= 30) AS prec_sum_last_030,
        sum(precipitacion_sum) FILTER (WHERE days_to_harvest <= 60) AS prec_sum_last_060,
        sum(precipitacion_sum) FILTER (WHERE days_to_harvest <= 90) AS prec_sum_last_090,
        sum(precipitacion_sum) FILTER (WHERE days_to_harvest <= 120) AS prec_sum_last_120,
        sum(eto_sum) FILTER (WHERE days_to_harvest <= 90) AS eto_sum_last_090,
        sum(water_balance) FILTER (WHERE days_to_harvest <= 30) AS water_balance_sum_last_030,
        sum(water_balance) FILTER (WHERE days_to_harvest <= 60) AS water_balance_sum_last_060,
        sum(water_balance) FILTER (WHERE days_to_harvest <= 90) AS water_balance_sum_last_090,
        sum(water_balance) FILTER (WHERE days_to_harvest <= 120) AS water_balance_sum_last_120,
        sum(gdd_10c) FILTER (WHERE days_to_harvest <= 90) AS gdd_10c_sum_last_090,
        sum(radiacion_sum) FILTER (WHERE days_to_harvest <= 90) AS radiacion_sum_last_090,
        avg(temperatura_mean) FILTER (WHERE days_to_harvest <= 90) AS tmean_mean_last_090,
        avg(temperatura_max) FILTER (WHERE days_to_harvest <= 90) AS tmax_mean_last_090,
        avg(temperatura_min) FILTER (WHERE days_to_harvest <= 90) AS tmin_mean_last_090,
        avg(humedad_relativa) FILTER (WHERE days_to_harvest <= 90) AS rh_mean_last_090,
        sum(dry_pentad_flag) FILTER (WHERE days_to_harvest <= 90) AS dry_pentad_count_last_090,
        sum(heat_pentad_flag) FILTER (WHERE days_to_harvest <= 90) AS heat_pentad_count_last_090,
        count(*) FILTER (WHERE days_to_harvest <= 90) AS climate_pentad_count_last_090
    FROM harvest_climate_by_pentad
    GROUP BY cod_cg_zafra
)
SELECT
    w.*,
    pc.tch_prev_cycle,
    pc.cycle_age_prev_cycle,
    pc.fecha_fin_prev_cycle,
    c.compact_ndre_peak_value,
    c.compact_lswi_late_mean,
    c.compact_evi2_peak_value,
    c.compact_gndvi_peak_value,
    c.compact_lswi_mid_mean,
    c.compact_evi2_late_mean,
    c.compact_ndvi_peak_value,
    c.compact_lswi_auc_full,
    c.compact_lswi_auc_late,
    c.compact_ndre_late_mean,
    c.compact_lswi_auc_mid,
    c.compact_evi2_mid_mean,
    c.compact_evi2_auc_full,
    c.compact_gndvi_early_mean,
    c.compact_tmean_full_mean,
    c.compact_evi2_auc_mid,
    c.compact_ndre_mid_mean,
    c.compact_evi2_early_mean,
    c.compact_ndre_early_mean,
    c.compact_ndvi_late_mean,
    c.compact_water_balance_full_total,
    c.compact_evi2_auc_late,
    c.compact_water_balance_late_total,
    c.compact_ndre_duration_above_80pct_peak,
    c.compact_water_ratio_full,
    c.compact_prec_full_total,
    c.compact_tmean_late_mean,
    c.compact_gndvi_late_mean,
    c.compact_tmin_late_mean,
    c.compact_prec_late_total,
    c.compact_ndvi_duration_above_80pct_peak,
    c.compact_dry_pentad_count_late,
    c.compact_lswi_late_minus_mid_mean,
    c.compact_gndvi_mid_mean,
    c.compact_evi2_duration_above_80pct_peak,
    c.compact_gndvi_duration_above_80pct_peak,
    c.compact_dry_pentad_count_full,
    c.compact_heat_pentad_count_full,
    c.compact_lswi_rise_slope,
    c.compact_tmax_late_mean,
    c.compact_water_ratio_late,
    c.compact_heat_pentad_count_late,
    c.compact_evi2_rise_slope,
    c.compact_eto_late_total,
    c.compact_ndvi_senescence_slope,
    c.compact_lswi_auc_early,
    c.compact_lswi_peak_value,
    c.compact_lswi_senescence_slope,
    c.compact_lswi_mid_minus_early_mean,
    c.compact_gdd_full_total,
    c.compact_ndre_rise_slope,
    c.compact_lswi_duration_above_80pct_peak,
    c.compact_lswi_age_at_peak,
    c.compact_ndre_late_minus_mid_mean,
    c.compact_gndvi_mid_minus_early_mean,
    c.compact_ndvi_mid_minus_early_mean,
    c.compact_evi2_late_minus_mid_mean,
    c.compact_evi2_senescence_slope,
    c.compact_evi2_mid_minus_early_mean,
    c.compact_rh_full_mean,
    c.compact_mid_obs_count,
    c.compact_early_obs_count,
    c.compact_gndvi_age_at_peak,
    c.compact_evi2_age_at_peak,
    c.compact_ndvi_age_at_peak,
    c.compact_gndvi_late_minus_mid_mean,
    c.compact_late_obs_count,
    c.compact_ndre_age_at_peak,
    ho.ndvi_mean_last_030,
    ho.ndvi_mean_last_060,
    ho.ndvi_mean_last_090,
    ho.ndvi_mean_last_120,
    ho.ndvi_slope_last_090,
    ho.evi2_mean_last_030,
    ho.evi2_mean_last_060,
    ho.evi2_mean_last_090,
    ho.evi2_mean_last_120,
    ho.evi2_slope_last_090,
    ho.lswi_mean_last_030,
    ho.lswi_mean_last_060,
    ho.lswi_mean_last_090,
    ho.lswi_mean_last_120,
    ho.lswi_max_last_090,
    ho.lswi_slope_last_090,
    ho.gndvi_mean_last_090,
    ho.gndvi_slope_last_090,
    ho.ndre_mean_last_090,
    ho.ndre_slope_last_090,
    ho.cire_mean_last_090,
    ho.cire_slope_last_090,
    ho.optical_obs_count_last_030,
    ho.optical_obs_count_last_060,
    ho.optical_obs_count_last_090,
    ho.optical_obs_count_last_120,
    hc.prec_sum_last_030,
    hc.prec_sum_last_060,
    hc.prec_sum_last_090,
    hc.prec_sum_last_120,
    hc.eto_sum_last_090,
    hc.water_balance_sum_last_030,
    hc.water_balance_sum_last_060,
    hc.water_balance_sum_last_090,
    hc.water_balance_sum_last_120,
    hc.gdd_10c_sum_last_090,
    hc.radiacion_sum_last_090,
    hc.tmean_mean_last_090,
    hc.tmax_mean_last_090,
    hc.tmin_mean_last_090,
    hc.rh_mean_last_090,
    hc.dry_pentad_count_last_090,
    hc.heat_pentad_count_last_090,
    hc.climate_pentad_count_last_090
FROM wide w
LEFT JOIN compact c ON c.cod_cg_zafra = w.cod_cg_zafra
LEFT JOIN prev_cycle pc ON pc.cod_cg_zafra = w.cod_cg_zafra
LEFT JOIN harvest_optical ho ON ho.cod_cg_zafra = w.cod_cg_zafra
LEFT JOIN harvest_climate hc ON hc.cod_cg_zafra = w.cod_cg_zafra;
