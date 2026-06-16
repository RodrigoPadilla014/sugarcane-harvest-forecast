-- tch_features_v9_productivity_snapshots.sql
--
-- Snapshot-aware v9 feature table. Productividad defines historical validity;
-- observations are aligned only by lot and date.

WITH
spine AS (
{{ include:tch_v9_productivity_snapshot_spine }}
),
optical_long AS (
    SELECT
        s.cod_cg_zafra,
        s.snapshot_day,
        st.fecha::date AS obs_date,
        (st.fecha::date - s.fecha_inicio_administrativa)::double precision AS age_days,
        NULLIF(st.ndvi_promedio::text, 'NaN')::double precision AS ndvi,
        NULLIF(st.evi2_promedio::text, 'NaN')::double precision AS evi2,
        NULLIF(st.gndvi_promedio::text, 'NaN')::double precision AS gndvi,
        NULLIF(st.ndre_promedio::text, 'NaN')::double precision AS ndre,
        NULLIF(st.lswi_promedio::text, 'NaN')::double precision AS lswi,
        NULLIF(st.ndwi11_promedio::text, 'NaN')::double precision AS ndwi11,
        NULLIF(st.msi11_promedio::text, 'NaN')::double precision AS msi11
    FROM spine s
    JOIN public.stac_indices st
      ON trim(st.lote::text) = s.cod_cg
     AND st.fecha::date BETWEEN s.fecha_inicio_administrativa
                            AND s.snapshot_date
),
optical AS (
    SELECT
        cod_cg_zafra,
        count(ndvi)::double precision AS optical_obs_count_0_snapshot,
        count(ndvi) FILTER (WHERE age_days <= 180)::double precision
            AS optical_obs_count_0_180,
        max(age_days) - min(age_days) AS optical_observed_span_days,
        avg(ndvi) AS optical_ndvi_mean_0_snapshot,
        avg(ndvi) FILTER (WHERE age_days BETWEEN 0 AND 90)
            AS optical_ndvi_mean_0_90,
        avg(ndvi) FILTER (WHERE age_days BETWEEN 91 AND 180)
            AS optical_ndvi_mean_91_180,
        avg(ndvi) FILTER (WHERE age_days > 180)
            AS optical_ndvi_mean_181_snapshot,
        avg(ndvi) FILTER (
            WHERE age_days >= greatest(0, snapshot_day - 30)
        ) AS optical_ndvi_mean_last30,
        min(ndvi) AS optical_ndvi_min_0_snapshot,
        max(ndvi) AS optical_ndvi_peak_0_snapshot,
        max(ndvi) - min(ndvi) AS optical_ndvi_amplitude_0_snapshot,
        regr_slope(ndvi, age_days) AS optical_ndvi_slope_0_snapshot,
        (
            array_agg(ndvi ORDER BY age_days DESC)
            FILTER (WHERE ndvi IS NOT NULL)
        )[1]
            AS optical_ndvi_last_value,
        avg(evi2) AS optical_evi2_mean_0_snapshot,
        regr_slope(evi2, age_days) AS optical_evi2_slope_0_snapshot,
        avg(gndvi) AS optical_gndvi_mean_0_snapshot,
        regr_slope(gndvi, age_days) AS optical_gndvi_slope_0_snapshot,
        avg(ndre) AS optical_ndre_mean_0_snapshot,
        regr_slope(ndre, age_days) AS optical_ndre_slope_0_snapshot,
        avg(lswi) AS optical_lswi_mean_0_snapshot,
        avg(ndwi11) AS optical_ndwi11_mean_0_snapshot,
        avg(msi11) AS optical_msi11_mean_0_snapshot
    FROM optical_long
    GROUP BY cod_cg_zafra, snapshot_day
),
radar_long AS (
    SELECT
        s.cod_cg_zafra,
        r.fecha::date AS obs_date,
        (r.fecha::date - s.fecha_inicio_administrativa)::double precision AS age_days,
        lower(r.orbit_pass) AS orbit_name,
        NULLIF(r.vv_promedio::text, 'NaN')::double precision AS vv,
        NULLIF(r.vh_promedio::text, 'NaN')::double precision AS vh,
        NULLIF(r.rvi_promedio::text, 'NaN')::double precision AS rvi,
        NULLIF(r.ratio_promedio::text, 'NaN')::double precision AS ratio,
        NULLIF(r.rfdi_promedio::text, 'NaN')::double precision AS rfdi
    FROM spine s
    JOIN public.radar r
      ON trim(r.lote::text) = s.cod_cg
     AND r.fecha::date BETWEEN s.fecha_inicio_administrativa
                           AND s.snapshot_date
    WHERE NULLIF(r.vv_promedio::text, 'NaN')::double precision IS NOT NULL
      AND NULLIF(r.vh_promedio::text, 'NaN')::double precision IS NOT NULL
),
radar AS (
    SELECT
        cod_cg_zafra,
        count(DISTINCT obs_date)::double precision AS radar_date_count_0_snapshot,
        count(DISTINCT obs_date) FILTER (WHERE age_days <= 180)::double precision
            AS radar_date_count_0_180,
        count(DISTINCT obs_date) FILTER (WHERE orbit_name = 'ascending')::double precision
            AS radar_ascending_date_count,
        count(DISTINCT obs_date) FILTER (WHERE orbit_name = 'descending')::double precision
            AS radar_descending_date_count,
        avg(vv) AS radar_vv_mean_0_snapshot,
        avg(vh) AS radar_vh_mean_0_snapshot,
        avg(rvi) AS radar_rvi_mean_0_snapshot,
        avg(ratio) AS radar_ratio_mean_0_snapshot,
        avg(rfdi) AS radar_rfdi_mean_0_snapshot,
        regr_slope(vv, age_days) AS radar_vv_slope_0_snapshot,
        regr_slope(vh, age_days) AS radar_vh_slope_0_snapshot,
        regr_slope(rvi, age_days) AS radar_rvi_slope_0_snapshot,
        avg(rvi) FILTER (WHERE age_days BETWEEN 0 AND 90)
            AS radar_rvi_mean_0_90,
        avg(rvi) FILTER (WHERE age_days BETWEEN 91 AND 180)
            AS radar_rvi_mean_91_180,
        avg(rvi) FILTER (WHERE age_days > 180)
            AS radar_rvi_mean_181_snapshot,
        (
            array_agg(rvi ORDER BY age_days DESC)
            FILTER (WHERE rvi IS NOT NULL)
        )[1] AS radar_rvi_last_value
    FROM radar_long
    GROUP BY cod_cg_zafra
),
climate_long AS (
    SELECT
        s.cod_cg_zafra,
        (c.fecha_inicio::date - s.fecha_inicio_administrativa)::double precision
            AS age_days,
        NULLIF(c.precipitacion_sum::text, 'NaN')::double precision AS precip,
        NULLIF(c.eto_sum::text, 'NaN')::double precision AS eto,
        NULLIF(c.radiacion_sum::text, 'NaN')::double precision AS radiation,
        NULLIF(c.precipitacion_sum::text, 'NaN')::double precision
            - NULLIF(c.eto_sum::text, 'NaN')::double precision AS water_balance,
        greatest(
            NULLIF(c.temperatura_mean::text, 'NaN')::double precision - 10.0,
            0.0
        ) * 5.0 AS gdd_10c,
        NULLIF(c.temperatura_mean::text, 'NaN')::double precision AS tmean,
        NULLIF(c.temperatura_max::text, 'NaN')::double precision AS tmax,
        NULLIF(c.temperatura_min::text, 'NaN')::double precision AS tmin,
        NULLIF(c.humedad_relativa::text, 'NaN')::double precision AS rh
    FROM spine s
    JOIN public.clima_lote_pentada_new c
      ON trim(c.cod_cg::text) = s.cod_cg
     AND c.fecha_inicio::date BETWEEN s.fecha_inicio_administrativa
                                  AND s.snapshot_date
),
climate AS (
    SELECT
        cod_cg_zafra,
        count(*)::double precision AS climate_pentad_count_0_snapshot,
        count(*) FILTER (WHERE age_days <= 180)::double precision
            AS climate_pentad_count_0_180,
        sum(precip) AS climate_precip_acc_0_snapshot,
        sum(eto) AS climate_eto_acc_0_snapshot,
        sum(radiation) AS climate_radiation_acc_0_snapshot,
        sum(water_balance) AS climate_water_balance_acc_0_snapshot,
        sum(gdd_10c) AS climate_gdd_10c_acc_0_snapshot,
        avg(tmean) AS climate_tmean_mean_0_snapshot,
        avg(tmax) AS climate_tmax_mean_0_snapshot,
        avg(tmin) AS climate_tmin_mean_0_snapshot,
        avg(rh) AS climate_rh_mean_0_snapshot,
        regr_slope(water_balance, age_days)
            AS climate_water_balance_slope_0_snapshot,
        regr_slope(precip, age_days) AS climate_precip_slope_0_snapshot
    FROM climate_long
    GROUP BY cod_cg_zafra
),
enso AS (
    SELECT
        s.cod_cg_zafra,
        count(e.date)::double precision AS enso_month_count_snapshot,
        avg(e.oni) FILTER (
            WHERE e.date::date < s.fecha_inicio_administrativa
        ) AS enso_oni_precycle_mean,
        avg(e.oni) FILTER (
            WHERE e.date::date >= s.fecha_inicio_administrativa
        ) AS enso_oni_snapshot_mean,
        max(abs(e.oni)) FILTER (
            WHERE e.date::date >= s.fecha_inicio_administrativa
        ) AS enso_oni_abs_max_snapshot,
        avg(e.nino34) FILTER (
            WHERE e.date::date >= s.fecha_inicio_administrativa
        ) AS enso_nino34_snapshot_mean,
        avg(e.soi) FILTER (
            WHERE e.date::date >= s.fecha_inicio_administrativa
        ) AS enso_soi_snapshot_mean
    FROM spine s
    LEFT JOIN public.enso e
      ON e.date::date BETWEEN s.fecha_inicio_administrativa - INTERVAL '180 days'
                          AND s.snapshot_date
    GROUP BY s.cod_cg_zafra
)
SELECT
    s.*,
    (s.previous_fecha_cierre IS NOT NULL)::integer AS has_previous_close_feature,
    abs(s.diferencia_inicios_dias)::double precision
        AS start_disagreement_abs_days,
    (abs(s.diferencia_inicios_dias) <= 30)::integer
        AS start_alignment_within_30d,
    (COALESCE(o.optical_obs_count_0_snapshot, 0) >= 7)::integer
        AS optical_coverage_flag,
    (COALESCE(r.radar_date_count_0_snapshot, 0) >= 7)::integer
        AS radar_coverage_flag,
    (COALESCE(c.climate_pentad_count_0_snapshot, 0) >= 30)::integer
        AS climate_coverage_flag,
    o.optical_obs_count_0_snapshot,
    o.optical_obs_count_0_180,
    o.optical_observed_span_days,
    o.optical_ndvi_mean_0_snapshot,
    o.optical_ndvi_mean_0_90,
    o.optical_ndvi_mean_91_180,
    o.optical_ndvi_mean_181_snapshot,
    o.optical_ndvi_mean_last30,
    o.optical_ndvi_min_0_snapshot,
    o.optical_ndvi_peak_0_snapshot,
    o.optical_ndvi_amplitude_0_snapshot,
    o.optical_ndvi_slope_0_snapshot,
    o.optical_ndvi_last_value,
    o.optical_evi2_mean_0_snapshot,
    o.optical_evi2_slope_0_snapshot,
    o.optical_gndvi_mean_0_snapshot,
    o.optical_gndvi_slope_0_snapshot,
    o.optical_ndre_mean_0_snapshot,
    o.optical_ndre_slope_0_snapshot,
    o.optical_lswi_mean_0_snapshot,
    o.optical_ndwi11_mean_0_snapshot,
    o.optical_msi11_mean_0_snapshot,
    r.radar_date_count_0_snapshot,
    r.radar_date_count_0_180,
    r.radar_ascending_date_count,
    r.radar_descending_date_count,
    r.radar_vv_mean_0_snapshot,
    r.radar_vh_mean_0_snapshot,
    r.radar_rvi_mean_0_snapshot,
    r.radar_ratio_mean_0_snapshot,
    r.radar_rfdi_mean_0_snapshot,
    r.radar_vv_slope_0_snapshot,
    r.radar_vh_slope_0_snapshot,
    r.radar_rvi_slope_0_snapshot,
    r.radar_rvi_mean_0_90,
    r.radar_rvi_mean_91_180,
    r.radar_rvi_mean_181_snapshot,
    r.radar_rvi_last_value,
    c.climate_pentad_count_0_snapshot,
    c.climate_pentad_count_0_180,
    c.climate_precip_acc_0_snapshot,
    c.climate_eto_acc_0_snapshot,
    c.climate_radiation_acc_0_snapshot,
    c.climate_water_balance_acc_0_snapshot,
    c.climate_gdd_10c_acc_0_snapshot,
    c.climate_tmean_mean_0_snapshot,
    c.climate_tmax_mean_0_snapshot,
    c.climate_tmin_mean_0_snapshot,
    c.climate_rh_mean_0_snapshot,
    c.climate_water_balance_slope_0_snapshot,
    c.climate_precip_slope_0_snapshot,
    e.enso_month_count_snapshot,
    e.enso_oni_precycle_mean,
    e.enso_oni_snapshot_mean,
    e.enso_oni_abs_max_snapshot,
    e.enso_nino34_snapshot_mean,
    e.enso_soi_snapshot_mean
FROM spine s
LEFT JOIN optical o USING (cod_cg_zafra)
LEFT JOIN radar r USING (cod_cg_zafra)
LEFT JOIN climate c USING (cod_cg_zafra)
LEFT JOIN enso e USING (cod_cg_zafra);
