-- tch_aggregated_features_v1.sql
--
-- One-row-per-lot-zafra feature table for TCH prediction.
--
-- Source:
--   tch_raw_longitudinal, which already applies the cycle logic
--   (cierre_ciclo, edad_de_cultivo, gap_in_data, ciclo_valido).
--
-- Unit:
--   one row per cod_cg_zafra.
--
-- Target:
--   tch, kept as plain TCH. area is retained for metadata/reporting and
--   downstream production estimates, not to transform the target.
--
-- Feature families:
--   productividad static descriptors, STAC optical indices, climate pentads,
--   ENSO, and radar ASC/DESC/ANY.

WITH base AS (
    SELECT
        cod_cg_zafra,
        cod_cg,
        zafra_norm,
        fecha_stac,
        area,
        tch,
        tc,
        cierre_ciclo,
        edad_de_cultivo,

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

        clima_precipitacion_sum,
        clima_eto_sum,
        clima_temperatura_max,
        clima_temperatura_min,
        clima_temperatura_mean,
        clima_humedad_relativa,
        clima_radiacion_sum,
        clima_indice_calor_max,

        enso_oni,
        enso_nino34,
        enso_soi,
        enso_mei,
        enso_pdo,

        radar_asc_rvi_promedio,
        radar_asc_ratio_promedio,
        radar_asc_nrb_promedio,
        radar_asc_rfdi_promedio,
        radar_asc_vh_promedio,
        radar_asc_vv_promedio,
        radar_desc_rvi_promedio,
        radar_desc_ratio_promedio,
        radar_desc_nrb_promedio,
        radar_desc_rfdi_promedio,
        radar_desc_vh_promedio,
        radar_desc_vv_promedio,

        CASE
            WHEN radar_asc_rvi_promedio IS NULL THEN radar_desc_rvi_promedio
            WHEN radar_desc_rvi_promedio IS NULL THEN radar_asc_rvi_promedio
            WHEN abs(radar_asc_days_delta) <= abs(radar_desc_days_delta) THEN radar_asc_rvi_promedio
            ELSE radar_desc_rvi_promedio
        END AS radar_any_rvi_promedio,
        CASE
            WHEN radar_asc_ratio_promedio IS NULL THEN radar_desc_ratio_promedio
            WHEN radar_desc_ratio_promedio IS NULL THEN radar_asc_ratio_promedio
            WHEN abs(radar_asc_days_delta) <= abs(radar_desc_days_delta) THEN radar_asc_ratio_promedio
            ELSE radar_desc_ratio_promedio
        END AS radar_any_ratio_promedio,
        CASE
            WHEN radar_asc_nrb_promedio IS NULL THEN radar_desc_nrb_promedio
            WHEN radar_desc_nrb_promedio IS NULL THEN radar_asc_nrb_promedio
            WHEN abs(radar_asc_days_delta) <= abs(radar_desc_days_delta) THEN radar_asc_nrb_promedio
            ELSE radar_desc_nrb_promedio
        END AS radar_any_nrb_promedio,
        CASE
            WHEN radar_asc_rfdi_promedio IS NULL THEN radar_desc_rfdi_promedio
            WHEN radar_desc_rfdi_promedio IS NULL THEN radar_asc_rfdi_promedio
            WHEN abs(radar_asc_days_delta) <= abs(radar_desc_days_delta) THEN radar_asc_rfdi_promedio
            ELSE radar_desc_rfdi_promedio
        END AS radar_any_rfdi_promedio,
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
        END AS radar_any_vv_promedio
    FROM tch_raw_longitudinal
    WHERE tch IS NOT NULL
      AND cod_cg_zafra IS NOT NULL
      AND zafra_norm IS NOT NULL
      AND area IS NOT NULL
      AND ciclo_valido = true
),
aggregated AS (
    SELECT
        cod_cg_zafra,
        max(cod_cg) AS cod_cg,
        max(zafra_norm) AS zafra_norm,
        max(area) AS area,
        max(tch) AS tch,
        max(tc) AS tc,
        min((fecha_stac - (edad_de_cultivo * INTERVAL '1 day'))::date) AS fecha_inicio_ciclo,
        max(cierre_ciclo)::date AS fecha_fin_ciclo,

        max(prod_variedad) AS prod_variedad,
        max(prod_grupo_de_suelo) AS prod_grupo_de_suelo,
        max(prod_grupo_de_humedad) AS prod_grupo_de_humedad,
        max(prod_codigo_zae) AS prod_codigo_zae,
        max(prod_finca) AS prod_finca,
        max(prod_familia_de_suelo) AS prod_familia_de_suelo,
        max(prod_no_corte) AS prod_no_corte,

        count(*) AS cycle_obs_count,
        count(*) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS early_obs_count,
        count(*) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS mid_obs_count,
        count(*) FILTER (WHERE edad_de_cultivo >= 241) AS late_obs_count,

        count(stac_ndvi_promedio) AS stac_obs_count,
        1.0 - (count(stac_ndvi_promedio)::double precision / nullif(count(*), 0)) AS stac_missing_rate,
        count(clima_precipitacion_sum) AS clima_obs_count,
        1.0 - (count(clima_precipitacion_sum)::double precision / nullif(count(*), 0)) AS clima_missing_rate,
        count(enso_oni) AS enso_obs_count,
        1.0 - (count(enso_oni)::double precision / nullif(count(*), 0)) AS enso_missing_rate,
        count(radar_asc_rvi_promedio) AS radar_asc_obs_count,
        1.0 - (count(radar_asc_rvi_promedio)::double precision / nullif(count(*), 0)) AS radar_asc_missing_rate,
        count(radar_desc_rvi_promedio) AS radar_desc_obs_count,
        1.0 - (count(radar_desc_rvi_promedio)::double precision / nullif(count(*), 0)) AS radar_desc_missing_rate,
        count(radar_any_rvi_promedio) AS radar_any_obs_count,
        1.0 - (count(radar_any_rvi_promedio)::double precision / nullif(count(*), 0)) AS radar_any_missing_rate,

        avg(stac_ndvi_promedio) AS stac_ndvi_promedio_mean,
        max(stac_ndvi_promedio) AS stac_ndvi_promedio_max,
        min(stac_ndvi_promedio) AS stac_ndvi_promedio_min,
        stddev_samp(stac_ndvi_promedio) AS stac_ndvi_promedio_std,
        (array_agg(stac_ndvi_promedio ORDER BY fecha_stac) FILTER (WHERE stac_ndvi_promedio IS NOT NULL))[1] AS stac_ndvi_promedio_first,
        (array_agg(stac_ndvi_promedio ORDER BY fecha_stac DESC) FILTER (WHERE stac_ndvi_promedio IS NOT NULL))[1] AS stac_ndvi_promedio_last,
        regr_slope(stac_ndvi_promedio, edad_de_cultivo) AS stac_ndvi_promedio_slope,
        avg(stac_ndvi_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS stac_ndvi_promedio_early_mean,
        avg(stac_ndvi_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS stac_ndvi_promedio_mid_mean,
        avg(stac_ndvi_promedio) FILTER (WHERE edad_de_cultivo >= 241) AS stac_ndvi_promedio_late_mean,

        avg(stac_evi2_promedio) AS stac_evi2_promedio_mean,
        max(stac_evi2_promedio) AS stac_evi2_promedio_max,
        min(stac_evi2_promedio) AS stac_evi2_promedio_min,
        stddev_samp(stac_evi2_promedio) AS stac_evi2_promedio_std,
        (array_agg(stac_evi2_promedio ORDER BY fecha_stac) FILTER (WHERE stac_evi2_promedio IS NOT NULL))[1] AS stac_evi2_promedio_first,
        (array_agg(stac_evi2_promedio ORDER BY fecha_stac DESC) FILTER (WHERE stac_evi2_promedio IS NOT NULL))[1] AS stac_evi2_promedio_last,
        regr_slope(stac_evi2_promedio, edad_de_cultivo) AS stac_evi2_promedio_slope,
        avg(stac_evi2_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS stac_evi2_promedio_early_mean,
        avg(stac_evi2_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS stac_evi2_promedio_mid_mean,
        avg(stac_evi2_promedio) FILTER (WHERE edad_de_cultivo >= 241) AS stac_evi2_promedio_late_mean,

        avg(stac_lswi_promedio) AS stac_lswi_promedio_mean,
        max(stac_lswi_promedio) AS stac_lswi_promedio_max,
        min(stac_lswi_promedio) AS stac_lswi_promedio_min,
        stddev_samp(stac_lswi_promedio) AS stac_lswi_promedio_std,
        (array_agg(stac_lswi_promedio ORDER BY fecha_stac) FILTER (WHERE stac_lswi_promedio IS NOT NULL))[1] AS stac_lswi_promedio_first,
        (array_agg(stac_lswi_promedio ORDER BY fecha_stac DESC) FILTER (WHERE stac_lswi_promedio IS NOT NULL))[1] AS stac_lswi_promedio_last,
        regr_slope(stac_lswi_promedio, edad_de_cultivo) AS stac_lswi_promedio_slope,
        avg(stac_lswi_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS stac_lswi_promedio_early_mean,
        avg(stac_lswi_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS stac_lswi_promedio_mid_mean,
        avg(stac_lswi_promedio) FILTER (WHERE edad_de_cultivo >= 241) AS stac_lswi_promedio_late_mean,

        avg(stac_gndvi_promedio) AS stac_gndvi_promedio_mean,
        max(stac_gndvi_promedio) AS stac_gndvi_promedio_max,
        min(stac_gndvi_promedio) AS stac_gndvi_promedio_min,
        stddev_samp(stac_gndvi_promedio) AS stac_gndvi_promedio_std,
        (array_agg(stac_gndvi_promedio ORDER BY fecha_stac) FILTER (WHERE stac_gndvi_promedio IS NOT NULL))[1] AS stac_gndvi_promedio_first,
        (array_agg(stac_gndvi_promedio ORDER BY fecha_stac DESC) FILTER (WHERE stac_gndvi_promedio IS NOT NULL))[1] AS stac_gndvi_promedio_last,
        regr_slope(stac_gndvi_promedio, edad_de_cultivo) AS stac_gndvi_promedio_slope,
        avg(stac_gndvi_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS stac_gndvi_promedio_early_mean,
        avg(stac_gndvi_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS stac_gndvi_promedio_mid_mean,
        avg(stac_gndvi_promedio) FILTER (WHERE edad_de_cultivo >= 241) AS stac_gndvi_promedio_late_mean,

        avg(stac_ndre_promedio) AS stac_ndre_promedio_mean,
        max(stac_ndre_promedio) AS stac_ndre_promedio_max,
        min(stac_ndre_promedio) AS stac_ndre_promedio_min,
        stddev_samp(stac_ndre_promedio) AS stac_ndre_promedio_std,
        (array_agg(stac_ndre_promedio ORDER BY fecha_stac) FILTER (WHERE stac_ndre_promedio IS NOT NULL))[1] AS stac_ndre_promedio_first,
        (array_agg(stac_ndre_promedio ORDER BY fecha_stac DESC) FILTER (WHERE stac_ndre_promedio IS NOT NULL))[1] AS stac_ndre_promedio_last,
        regr_slope(stac_ndre_promedio, edad_de_cultivo) AS stac_ndre_promedio_slope,
        avg(stac_ndre_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS stac_ndre_promedio_early_mean,
        avg(stac_ndre_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS stac_ndre_promedio_mid_mean,
        avg(stac_ndre_promedio) FILTER (WHERE edad_de_cultivo >= 241) AS stac_ndre_promedio_late_mean,

        avg(stac_cire_promedio) AS stac_cire_promedio_mean,
        max(stac_cire_promedio) AS stac_cire_promedio_max,
        min(stac_cire_promedio) AS stac_cire_promedio_min,
        stddev_samp(stac_cire_promedio) AS stac_cire_promedio_std,
        (array_agg(stac_cire_promedio ORDER BY fecha_stac) FILTER (WHERE stac_cire_promedio IS NOT NULL))[1] AS stac_cire_promedio_first,
        (array_agg(stac_cire_promedio ORDER BY fecha_stac DESC) FILTER (WHERE stac_cire_promedio IS NOT NULL))[1] AS stac_cire_promedio_last,
        regr_slope(stac_cire_promedio, edad_de_cultivo) AS stac_cire_promedio_slope,
        avg(stac_cire_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS stac_cire_promedio_early_mean,
        avg(stac_cire_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS stac_cire_promedio_mid_mean,
        avg(stac_cire_promedio) FILTER (WHERE edad_de_cultivo >= 241) AS stac_cire_promedio_late_mean,

        avg(clima_precipitacion_sum) AS clima_precipitacion_sum_mean,
        sum(clima_precipitacion_sum) AS clima_precipitacion_sum_total,
        max(clima_precipitacion_sum) AS clima_precipitacion_sum_max,
        min(clima_precipitacion_sum) AS clima_precipitacion_sum_min,
        stddev_samp(clima_precipitacion_sum) AS clima_precipitacion_sum_std,
        (array_agg(clima_precipitacion_sum ORDER BY fecha_stac) FILTER (WHERE clima_precipitacion_sum IS NOT NULL))[1] AS clima_precipitacion_sum_first,
        (array_agg(clima_precipitacion_sum ORDER BY fecha_stac DESC) FILTER (WHERE clima_precipitacion_sum IS NOT NULL))[1] AS clima_precipitacion_sum_last,
        regr_slope(clima_precipitacion_sum, edad_de_cultivo) AS clima_precipitacion_sum_slope,
        avg(clima_precipitacion_sum) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS clima_precipitacion_sum_early_mean,
        avg(clima_precipitacion_sum) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS clima_precipitacion_sum_mid_mean,
        avg(clima_precipitacion_sum) FILTER (WHERE edad_de_cultivo >= 241) AS clima_precipitacion_sum_late_mean,
        sum(clima_precipitacion_sum) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS clima_precipitacion_sum_early_total,
        sum(clima_precipitacion_sum) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS clima_precipitacion_sum_mid_total,
        sum(clima_precipitacion_sum) FILTER (WHERE edad_de_cultivo >= 241) AS clima_precipitacion_sum_late_total,

        avg(clima_eto_sum) AS clima_eto_sum_mean,
        sum(clima_eto_sum) AS clima_eto_sum_total,
        max(clima_eto_sum) AS clima_eto_sum_max,
        min(clima_eto_sum) AS clima_eto_sum_min,
        stddev_samp(clima_eto_sum) AS clima_eto_sum_std,
        regr_slope(clima_eto_sum, edad_de_cultivo) AS clima_eto_sum_slope,
        avg(clima_eto_sum) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS clima_eto_sum_early_mean,
        avg(clima_eto_sum) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS clima_eto_sum_mid_mean,
        avg(clima_eto_sum) FILTER (WHERE edad_de_cultivo >= 241) AS clima_eto_sum_late_mean,
        sum(clima_eto_sum) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS clima_eto_sum_early_total,
        sum(clima_eto_sum) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS clima_eto_sum_mid_total,
        sum(clima_eto_sum) FILTER (WHERE edad_de_cultivo >= 241) AS clima_eto_sum_late_total,

        avg(clima_radiacion_sum) AS clima_radiacion_sum_mean,
        sum(clima_radiacion_sum) AS clima_radiacion_sum_total,
        max(clima_radiacion_sum) AS clima_radiacion_sum_max,
        min(clima_radiacion_sum) AS clima_radiacion_sum_min,
        stddev_samp(clima_radiacion_sum) AS clima_radiacion_sum_std,
        regr_slope(clima_radiacion_sum, edad_de_cultivo) AS clima_radiacion_sum_slope,
        avg(clima_radiacion_sum) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS clima_radiacion_sum_early_mean,
        avg(clima_radiacion_sum) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS clima_radiacion_sum_mid_mean,
        avg(clima_radiacion_sum) FILTER (WHERE edad_de_cultivo >= 241) AS clima_radiacion_sum_late_mean,
        sum(clima_radiacion_sum) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS clima_radiacion_sum_early_total,
        sum(clima_radiacion_sum) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS clima_radiacion_sum_mid_total,
        sum(clima_radiacion_sum) FILTER (WHERE edad_de_cultivo >= 241) AS clima_radiacion_sum_late_total,

        avg(clima_temperatura_mean) AS clima_temperatura_mean_mean,
        max(clima_temperatura_max) AS clima_temperatura_max_max,
        min(clima_temperatura_min) AS clima_temperatura_min_min,
        stddev_samp(clima_temperatura_mean) AS clima_temperatura_mean_std,
        regr_slope(clima_temperatura_mean, edad_de_cultivo) AS clima_temperatura_mean_slope,
        avg(clima_temperatura_mean) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS clima_temperatura_mean_early_mean,
        avg(clima_temperatura_mean) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS clima_temperatura_mean_mid_mean,
        avg(clima_temperatura_mean) FILTER (WHERE edad_de_cultivo >= 241) AS clima_temperatura_mean_late_mean,
        avg(clima_humedad_relativa) AS clima_humedad_relativa_mean,
        stddev_samp(clima_humedad_relativa) AS clima_humedad_relativa_std,
        avg(clima_indice_calor_max) AS clima_indice_calor_max_mean,
        max(clima_indice_calor_max) AS clima_indice_calor_max_max,

        avg(enso_oni) AS enso_oni_mean,
        max(enso_oni) AS enso_oni_max,
        min(enso_oni) AS enso_oni_min,
        stddev_samp(enso_oni) AS enso_oni_std,
        (array_agg(enso_oni ORDER BY fecha_stac) FILTER (WHERE enso_oni IS NOT NULL))[1] AS enso_oni_first,
        (array_agg(enso_oni ORDER BY fecha_stac DESC) FILTER (WHERE enso_oni IS NOT NULL))[1] AS enso_oni_last,
        regr_slope(enso_oni, edad_de_cultivo) AS enso_oni_slope,
        avg(enso_oni) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS enso_oni_early_mean,
        avg(enso_oni) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS enso_oni_mid_mean,
        avg(enso_oni) FILTER (WHERE edad_de_cultivo >= 241) AS enso_oni_late_mean,

        avg(enso_nino34) AS enso_nino34_mean,
        max(enso_nino34) AS enso_nino34_max,
        min(enso_nino34) AS enso_nino34_min,
        stddev_samp(enso_nino34) AS enso_nino34_std,
        regr_slope(enso_nino34, edad_de_cultivo) AS enso_nino34_slope,
        avg(enso_nino34) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS enso_nino34_early_mean,
        avg(enso_nino34) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS enso_nino34_mid_mean,
        avg(enso_nino34) FILTER (WHERE edad_de_cultivo >= 241) AS enso_nino34_late_mean,
        avg(enso_soi) AS enso_soi_mean,
        regr_slope(enso_soi, edad_de_cultivo) AS enso_soi_slope,
        avg(enso_mei) AS enso_mei_mean,
        regr_slope(enso_mei, edad_de_cultivo) AS enso_mei_slope,
        avg(enso_pdo) AS enso_pdo_mean,
        regr_slope(enso_pdo, edad_de_cultivo) AS enso_pdo_slope,

        avg(radar_any_rvi_promedio) AS radar_any_rvi_promedio_mean,
        max(radar_any_rvi_promedio) AS radar_any_rvi_promedio_max,
        min(radar_any_rvi_promedio) AS radar_any_rvi_promedio_min,
        stddev_samp(radar_any_rvi_promedio) AS radar_any_rvi_promedio_std,
        (array_agg(radar_any_rvi_promedio ORDER BY fecha_stac) FILTER (WHERE radar_any_rvi_promedio IS NOT NULL))[1] AS radar_any_rvi_promedio_first,
        (array_agg(radar_any_rvi_promedio ORDER BY fecha_stac DESC) FILTER (WHERE radar_any_rvi_promedio IS NOT NULL))[1] AS radar_any_rvi_promedio_last,
        regr_slope(radar_any_rvi_promedio, edad_de_cultivo) AS radar_any_rvi_promedio_slope,
        avg(radar_any_rvi_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 0 AND 120) AS radar_any_rvi_promedio_early_mean,
        avg(radar_any_rvi_promedio) FILTER (WHERE edad_de_cultivo BETWEEN 121 AND 240) AS radar_any_rvi_promedio_mid_mean,
        avg(radar_any_rvi_promedio) FILTER (WHERE edad_de_cultivo >= 241) AS radar_any_rvi_promedio_late_mean,

        avg(radar_any_ratio_promedio) AS radar_any_ratio_promedio_mean,
        avg(radar_any_nrb_promedio) AS radar_any_nrb_promedio_mean,
        avg(radar_any_rfdi_promedio) AS radar_any_rfdi_promedio_mean,
        avg(radar_any_vh_promedio) AS radar_any_vh_promedio_mean,
        avg(radar_any_vv_promedio) AS radar_any_vv_promedio_mean,
        regr_slope(radar_any_ratio_promedio, edad_de_cultivo) AS radar_any_ratio_promedio_slope,
        regr_slope(radar_any_nrb_promedio, edad_de_cultivo) AS radar_any_nrb_promedio_slope,
        regr_slope(radar_any_rfdi_promedio, edad_de_cultivo) AS radar_any_rfdi_promedio_slope,
        regr_slope(radar_any_vh_promedio, edad_de_cultivo) AS radar_any_vh_promedio_slope,
        regr_slope(radar_any_vv_promedio, edad_de_cultivo) AS radar_any_vv_promedio_slope,

        avg(radar_asc_rvi_promedio) AS radar_asc_rvi_promedio_mean,
        avg(radar_asc_ratio_promedio) AS radar_asc_ratio_promedio_mean,
        avg(radar_asc_nrb_promedio) AS radar_asc_nrb_promedio_mean,
        avg(radar_asc_rfdi_promedio) AS radar_asc_rfdi_promedio_mean,
        avg(radar_asc_vh_promedio) AS radar_asc_vh_promedio_mean,
        avg(radar_asc_vv_promedio) AS radar_asc_vv_promedio_mean,
        regr_slope(radar_asc_rvi_promedio, edad_de_cultivo) AS radar_asc_rvi_promedio_slope,
        regr_slope(radar_asc_ratio_promedio, edad_de_cultivo) AS radar_asc_ratio_promedio_slope,
        regr_slope(radar_asc_nrb_promedio, edad_de_cultivo) AS radar_asc_nrb_promedio_slope,
        regr_slope(radar_asc_rfdi_promedio, edad_de_cultivo) AS radar_asc_rfdi_promedio_slope,
        regr_slope(radar_asc_vh_promedio, edad_de_cultivo) AS radar_asc_vh_promedio_slope,
        regr_slope(radar_asc_vv_promedio, edad_de_cultivo) AS radar_asc_vv_promedio_slope,

        avg(radar_desc_rvi_promedio) AS radar_desc_rvi_promedio_mean,
        avg(radar_desc_ratio_promedio) AS radar_desc_ratio_promedio_mean,
        avg(radar_desc_nrb_promedio) AS radar_desc_nrb_promedio_mean,
        avg(radar_desc_rfdi_promedio) AS radar_desc_rfdi_promedio_mean,
        avg(radar_desc_vh_promedio) AS radar_desc_vh_promedio_mean,
        avg(radar_desc_vv_promedio) AS radar_desc_vv_promedio_mean,
        regr_slope(radar_desc_rvi_promedio, edad_de_cultivo) AS radar_desc_rvi_promedio_slope,
        regr_slope(radar_desc_ratio_promedio, edad_de_cultivo) AS radar_desc_ratio_promedio_slope,
        regr_slope(radar_desc_nrb_promedio, edad_de_cultivo) AS radar_desc_nrb_promedio_slope,
        regr_slope(radar_desc_rfdi_promedio, edad_de_cultivo) AS radar_desc_rfdi_promedio_slope,
        regr_slope(radar_desc_vh_promedio, edad_de_cultivo) AS radar_desc_vh_promedio_slope,
        regr_slope(radar_desc_vv_promedio, edad_de_cultivo) AS radar_desc_vv_promedio_slope
    FROM base
    GROUP BY cod_cg_zafra
)
SELECT
    aggregated.*,
    stac_ndvi_promedio_last - stac_ndvi_promedio_first AS stac_ndvi_promedio_delta_last_first,
    stac_evi2_promedio_last - stac_evi2_promedio_first AS stac_evi2_promedio_delta_last_first,
    stac_lswi_promedio_last - stac_lswi_promedio_first AS stac_lswi_promedio_delta_last_first,
    stac_gndvi_promedio_last - stac_gndvi_promedio_first AS stac_gndvi_promedio_delta_last_first,
    stac_ndre_promedio_last - stac_ndre_promedio_first AS stac_ndre_promedio_delta_last_first,
    stac_cire_promedio_last - stac_cire_promedio_first AS stac_cire_promedio_delta_last_first,
    clima_precipitacion_sum_last - clima_precipitacion_sum_first AS clima_precipitacion_sum_delta_last_first,
    enso_oni_last - enso_oni_first AS enso_oni_delta_last_first,
    radar_any_rvi_promedio_last - radar_any_rvi_promedio_first AS radar_any_rvi_promedio_delta_last_first
FROM aggregated;
