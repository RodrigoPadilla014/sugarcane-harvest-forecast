-- tch_features_v5_asof_180d_core.sql
--
-- Cutoff-aware feature table for predicting final TCH at crop age 180 days.
--
-- Shape: one row per valid cod_cg_zafra.
-- Source spine: public.tch_raw_longitudinal_v4.
-- Cutoff rule: source summaries use only observations with age <= 180 days.
-- Exclusions: 2019_2020 is excluded because pre-180 source coverage is not
-- comparable to later zafras.
--
-- This query is self-contained for sagemaker/jobs/upload_dataset.py.

WITH
agronomy_core AS (
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
            180::integer AS cutoff_age_days,
            (min(r.fecha_inicio_estimada)::date + INTERVAL '180 days')::date AS cutoff_date,

            max(r.prod_ingenio) AS prod_ingenio,
            max(r.prod_grupo_de_suelo) AS prod_grupo_de_suelo,
            max(r.prod_grupo_de_humedad) AS prod_grupo_de_humedad,
            max(r.prod_codigo_zae) AS prod_codigo_zae,
            max(r.prod_familia_de_suelo) AS prod_familia_de_suelo,
            max(r.prod_variedad) AS prod_variedad,
            max(r.prod_no_corte) AS prod_no_corte
        FROM public.tch_raw_longitudinal_v4 r
        WHERE r.tch IS NOT NULL
          AND r.tch BETWEEN 20 AND 150
          AND r.ciclo_valido = true
          AND r.cod_cg_zafra IS NOT NULL
          AND r.zafra_norm <> '2019_2020'
        GROUP BY r.cod_cg_zafra
        HAVING max(r.edad_de_cultivo)::double precision >= 180
    )
    SELECT *
    FROM base_cycles
),
optical_core AS (
    WITH base_cycles AS (
        SELECT
            cod_cg_zafra,
            cod_cg,
            fecha_inicio_ciclo,
            cutoff_date
        FROM agronomy_core
    ),
    optical_long AS (
        SELECT
            b.cod_cg_zafra,
            r.fecha_stac::date AS fecha_obs,
            r.edad_de_cultivo::double precision AS age_days,
            CASE
                WHEN r.edad_de_cultivo BETWEEN 0 AND 90 THEN 'age_000_090'
                WHEN r.edad_de_cultivo BETWEEN 91 AND 180 THEN 'age_091_180'
                ELSE 'outside'
            END AS age_window,
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
                ('lswi', NULLIF(r.stac_lswi_promedio::text, 'NaN')::double precision),
                ('ndvire', NULLIF(r.stac_ndvire_promedio::text, 'NaN')::double precision),
                ('cire', NULLIF(r.stac_cire_promedio::text, 'NaN')::double precision),
                ('ndwi11', NULLIF(r.stac_ndwi11_promedio::text, 'NaN')::double precision),
                ('msi11', NULLIF(r.stac_msi11_promedio::text, 'NaN')::double precision)
        ) AS v(index_name, index_value)
        WHERE r.ciclo_valido = true
          AND r.edad_de_cultivo BETWEEN 0 AND 180
    ),
    weighted AS (
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
            least(180.0, coalesce((age_days + next_age) / 2.0, age_days + 7.5)) AS obs_end_age
        FROM weighted
    ),
    features_long AS (
        SELECT
            cod_cg_zafra,
            index_name,
            count(index_value)::double precision AS obs_count_0_180,
            min(age_days) FILTER (WHERE index_value IS NOT NULL) AS first_obs_age_0_180,
            max(age_days) FILTER (WHERE index_value IS NOT NULL) AS last_obs_age_0_180,
            max(age_days) FILTER (WHERE index_value IS NOT NULL)
                - min(age_days) FILTER (WHERE index_value IS NOT NULL) AS observed_age_span_0_180,
            max(age_days - prev_age) FILTER (WHERE index_value IS NOT NULL) AS max_gap_days_0_180,
            avg(index_value) AS mean_0_180,
            avg(index_value) FILTER (WHERE age_window = 'age_000_090') AS mean_0_90,
            avg(index_value) FILTER (WHERE age_window = 'age_091_180') AS mean_91_180,
            avg(index_value) FILTER (WHERE age_window = 'age_091_180')
                - avg(index_value) FILTER (WHERE age_window = 'age_000_090') AS mean_91_180_minus_0_90,
            max(index_value) AS peak_0_180,
            min(index_value) AS min_0_180,
            max(index_value) - min(index_value) AS amplitude_0_180,
            (array_agg(age_days ORDER BY index_value DESC NULLS LAST, age_days)
                FILTER (WHERE index_value IS NOT NULL))[1] AS age_at_peak_0_180,
            (array_agg(index_value ORDER BY age_days DESC NULLS LAST, fecha_obs DESC)
                FILTER (WHERE index_value IS NOT NULL))[1] AS last_value_before_180,
            (array_agg(age_days ORDER BY age_days DESC NULLS LAST, fecha_obs DESC)
                FILTER (WHERE index_value IS NOT NULL))[1] AS last_obs_age_before_180,
            sum(index_value * greatest(0.0, obs_end_age - obs_start_age)) AS auc_0_180,
            sum(index_value * greatest(0.0, least(obs_end_age, 90.0) - greatest(obs_start_age, 0.0))) AS auc_0_90,
            sum(index_value * greatest(0.0, obs_end_age - greatest(obs_start_age, 90.0))) AS auc_91_180,
            regr_slope(index_value, age_days) AS slope_0_180,
            regr_slope(index_value, age_days) FILTER (WHERE age_window = 'age_000_090') AS slope_0_90,
            regr_slope(index_value, age_days) FILTER (WHERE age_window = 'age_091_180') AS slope_91_180,
            sum(greatest(0.0, obs_end_age - obs_start_age))
                FILTER (WHERE index_value >= 0.8 * peak_value_window) AS duration_above_80pct_peak_0_180
        FROM prepared
        GROUP BY cod_cg_zafra, index_name
    ),
    features_wide AS (
        SELECT
            cod_cg_zafra,

            max(obs_count_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_obs_count_0_180,
            max(first_obs_age_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_first_obs_age_0_180,
            max(last_obs_age_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_last_obs_age_0_180,
            max(max_gap_days_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_max_gap_days_0_180,

            max(peak_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_peak_0_180,
            max(mean_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mean_0_180,
            max(mean_91_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mean_91_180,
            max(mean_91_180_minus_0_90) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mean_91_180_minus_0_90,
            max(amplitude_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_amplitude_0_180,
            max(auc_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_auc_0_180,
            max(auc_91_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_auc_91_180,
            max(slope_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_slope_0_180,
            max(last_value_before_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_last_value_before_180,
            max(age_at_peak_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_age_at_peak_0_180,
            max(duration_above_80pct_peak_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_duration_above_80pct_peak_0_180,

            max(peak_0_180) FILTER (WHERE index_name = 'evi2') AS optical_evi2_peak_0_180,
            max(mean_0_180) FILTER (WHERE index_name = 'evi2') AS optical_evi2_mean_0_180,
            max(mean_91_180) FILTER (WHERE index_name = 'evi2') AS optical_evi2_mean_91_180,
            max(amplitude_0_180) FILTER (WHERE index_name = 'evi2') AS optical_evi2_amplitude_0_180,
            max(auc_91_180) FILTER (WHERE index_name = 'evi2') AS optical_evi2_auc_91_180,
            max(slope_0_180) FILTER (WHERE index_name = 'evi2') AS optical_evi2_slope_0_180,

            max(peak_0_180) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_peak_0_180,
            max(mean_0_180) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_mean_0_180,
            max(mean_91_180) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_mean_91_180,
            max(amplitude_0_180) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_amplitude_0_180,
            max(auc_91_180) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_auc_91_180,
            max(slope_0_180) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_slope_0_180,

            max(peak_0_180) FILTER (WHERE index_name = 'ndre') AS optical_ndre_peak_0_180,
            max(mean_0_180) FILTER (WHERE index_name = 'ndre') AS optical_ndre_mean_0_180,
            max(mean_91_180) FILTER (WHERE index_name = 'ndre') AS optical_ndre_mean_91_180,
            max(amplitude_0_180) FILTER (WHERE index_name = 'ndre') AS optical_ndre_amplitude_0_180,
            max(auc_91_180) FILTER (WHERE index_name = 'ndre') AS optical_ndre_auc_91_180,
            max(slope_0_180) FILTER (WHERE index_name = 'ndre') AS optical_ndre_slope_0_180,
            max(age_at_peak_0_180) FILTER (WHERE index_name = 'ndre') AS optical_ndre_age_at_peak_0_180,

            max(peak_0_180) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_peak_0_180,
            max(mean_91_180) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_mean_91_180,
            max(amplitude_0_180) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_amplitude_0_180,
            max(auc_91_180) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_auc_91_180,

            max(peak_0_180) FILTER (WHERE index_name = 'cire') AS optical_cire_peak_0_180,
            max(mean_0_180) FILTER (WHERE index_name = 'cire') AS optical_cire_mean_0_180,
            max(mean_91_180) FILTER (WHERE index_name = 'cire') AS optical_cire_mean_91_180,
            max(amplitude_0_180) FILTER (WHERE index_name = 'cire') AS optical_cire_amplitude_0_180,
            max(auc_0_180) FILTER (WHERE index_name = 'cire') AS optical_cire_auc_0_180,
            max(auc_91_180) FILTER (WHERE index_name = 'cire') AS optical_cire_auc_91_180,

            max(mean_91_180) FILTER (WHERE index_name = 'lswi') AS optical_lswi_mean_91_180,
            max(mean_91_180_minus_0_90) FILTER (WHERE index_name = 'lswi') AS optical_lswi_mean_91_180_minus_0_90,
            max(auc_91_180) FILTER (WHERE index_name = 'lswi') AS optical_lswi_auc_91_180,

            max(mean_91_180) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_mean_91_180,
            max(auc_91_180) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_auc_91_180,
            max(mean_91_180) FILTER (WHERE index_name = 'msi11') AS optical_msi11_mean_91_180,
            max(auc_91_180) FILTER (WHERE index_name = 'msi11') AS optical_msi11_auc_91_180
        FROM features_long
        GROUP BY cod_cg_zafra
    )
    SELECT *
    FROM features_wide
),
climate_core AS (
    WITH base_cycles AS (
        SELECT
            cod_cg_zafra,
            cod_cg,
            fecha_inicio_ciclo,
            cutoff_date
        FROM agronomy_core
    ),
    climate_seq AS (
        SELECT
            b.cod_cg_zafra,
            c.fecha_inicio::date AS clima_fecha_inicio,
            (c.fecha_inicio::date - b.fecha_inicio_ciclo)::double precision AS age_days,
            CASE
                WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 0 AND 90 THEN 'age_000_090'
                WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 91 AND 180 THEN 'age_091_180'
                ELSE 'outside'
            END AS age_window,
            NULLIF(c.precipitacion_sum::text, 'NaN')::double precision AS precip,
            NULLIF(c.eto_sum::text, 'NaN')::double precision AS eto,
            NULLIF(c.temperatura_max::text, 'NaN')::double precision AS tmax,
            NULLIF(c.temperatura_min::text, 'NaN')::double precision AS tmin,
            NULLIF(c.temperatura_mean::text, 'NaN')::double precision AS tmean,
            NULLIF(c.humedad_relativa::text, 'NaN')::double precision AS rh,
            NULLIF(c.radiacion_sum::text, 'NaN')::double precision AS rad,
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
            END AS heat_pentad
        FROM base_cycles b
        LEFT JOIN public.clima_lote_pentada_new c
          ON c.cod_cg = b.cod_cg
         AND c.fecha_inicio::date BETWEEN b.fecha_inicio_ciclo AND b.cutoff_date
    )
    SELECT
        cod_cg_zafra,
        count(clima_fecha_inicio)::double precision AS climate_pentad_count_0_180,
        max(clima_fecha_inicio - lag_clima_fecha_inicio)::double precision AS climate_max_gap_days_0_180,
        sum(precip) AS climate_precip_acc_0_180,
        sum(precip) FILTER (WHERE age_window = 'age_000_090') AS climate_precip_acc_0_90,
        sum(precip) FILTER (WHERE age_window = 'age_091_180') AS climate_precip_acc_91_180,
        sum(eto) AS climate_eto_acc_0_180,
        sum(water_balance) AS climate_water_balance_acc_0_180,
        sum(water_balance) FILTER (WHERE age_window = 'age_000_090') AS climate_water_balance_acc_0_90,
        sum(water_balance) FILTER (WHERE age_window = 'age_091_180') AS climate_water_balance_acc_91_180,
        sum(precip) / NULLIF(sum(eto), 0) AS climate_water_ratio_0_180,
        sum(rad) AS climate_rad_acc_0_180,
        sum(gdd_10c) AS climate_gdd_10c_acc_0_180,
        avg(tmean) AS climate_tmean_mean_0_180,
        avg(tmax) AS climate_tmax_mean_0_180,
        avg(tmin) AS climate_tmin_mean_0_180,
        avg(rh) AS climate_rh_mean_0_180,
        sum(dry_pentad) AS climate_dry_pentad_count_0_180,
        avg(dry_pentad) AS climate_dry_fraction_0_180,
        sum(heat_pentad) AS climate_heat_pentad_count_0_180,
        regr_slope(water_balance, age_days) AS climate_water_balance_slope_0_180,
        regr_slope(precip, age_days) AS climate_precip_slope_0_180,
        regr_slope(rad, age_days) AS climate_rad_slope_0_180,
        regr_slope(tmean, age_days) AS climate_tmean_slope_0_180
    FROM (
        SELECT
            *,
            lag(clima_fecha_inicio) OVER (
                PARTITION BY cod_cg_zafra
                ORDER BY clima_fecha_inicio
            ) AS lag_clima_fecha_inicio
        FROM climate_seq
    ) s
    GROUP BY cod_cg_zafra
),
enso_core AS (
    WITH enso_seq AS (
        SELECT
            b.cod_cg_zafra,
            e.date::date AS enso_month,
            CASE
                WHEN e.date::date < b.fecha_inicio_ciclo THEN 'precycle_180d'
                WHEN e.date::date <= b.cutoff_date THEN 'asof_0_180d'
                ELSE 'outside'
            END AS enso_window,
            NULLIF(e.oni::text, 'NaN')::double precision AS oni,
            NULLIF(e.nino34::text, 'NaN')::double precision AS nino34,
            NULLIF(e.soi::text, 'NaN')::double precision AS soi
        FROM agronomy_core b
        LEFT JOIN public.enso e
          ON e.date::date >= b.fecha_inicio_ciclo - INTERVAL '180 days'
         AND e.date::date <= b.cutoff_date
    )
    SELECT
        cod_cg_zafra,
        count(enso_month)::double precision AS enso_month_count_asof,
        avg(oni) FILTER (WHERE enso_window = 'precycle_180d') AS enso_oni_precycle_mean,
        avg(oni) FILTER (WHERE enso_window = 'asof_0_180d') AS enso_oni_asof_mean,
        max(abs(oni)) AS enso_oni_abs_max_asof,
        avg(nino34) FILTER (WHERE enso_window = 'precycle_180d') AS enso_nino34_precycle_mean,
        avg(nino34) FILTER (WHERE enso_window = 'asof_0_180d') AS enso_nino34_asof_mean,
        avg(soi) FILTER (WHERE enso_window = 'precycle_180d') AS enso_soi_precycle_mean,
        avg(soi) FILTER (WHERE enso_window = 'asof_0_180d') AS enso_soi_asof_mean,
        avg((oni > 0.5)::int) AS enso_el_nino_fraction_asof,
        avg((oni < -0.5)::int) AS enso_la_nina_fraction_asof
    FROM enso_seq
    GROUP BY cod_cg_zafra
)
SELECT
    a.cod_cg_zafra,
    a.cod_cg,
    a.zafra_norm,
    a.area,
    a.tch,
    a.tc,
    a.fecha_inicio_ciclo,
    a.fecha_fin_ciclo,
    a.cycle_age_max,
    a.cutoff_age_days,
    a.cutoff_date,

    a.prod_ingenio,
    a.prod_grupo_de_suelo,
    a.prod_grupo_de_humedad,
    a.prod_codigo_zae,
    a.prod_familia_de_suelo,
    a.prod_variedad,
    a.prod_no_corte,

    o.optical_obs_count_0_180,
    o.optical_first_obs_age_0_180,
    o.optical_last_obs_age_0_180,
    o.optical_max_gap_days_0_180,
    o.optical_ndvi_peak_0_180,
    o.optical_ndvi_mean_0_180,
    o.optical_ndvi_mean_91_180,
    o.optical_ndvi_mean_91_180_minus_0_90,
    o.optical_ndvi_amplitude_0_180,
    o.optical_ndvi_auc_0_180,
    o.optical_ndvi_auc_91_180,
    o.optical_ndvi_slope_0_180,
    o.optical_ndvi_last_value_before_180,
    o.optical_ndvi_age_at_peak_0_180,
    o.optical_ndvi_duration_above_80pct_peak_0_180,
    o.optical_evi2_peak_0_180,
    o.optical_evi2_mean_0_180,
    o.optical_evi2_mean_91_180,
    o.optical_evi2_amplitude_0_180,
    o.optical_evi2_auc_91_180,
    o.optical_evi2_slope_0_180,
    o.optical_gndvi_peak_0_180,
    o.optical_gndvi_mean_0_180,
    o.optical_gndvi_mean_91_180,
    o.optical_gndvi_amplitude_0_180,
    o.optical_gndvi_auc_91_180,
    o.optical_gndvi_slope_0_180,
    o.optical_ndre_peak_0_180,
    o.optical_ndre_mean_0_180,
    o.optical_ndre_mean_91_180,
    o.optical_ndre_amplitude_0_180,
    o.optical_ndre_auc_91_180,
    o.optical_ndre_slope_0_180,
    o.optical_ndre_age_at_peak_0_180,
    o.optical_ndvire_peak_0_180,
    o.optical_ndvire_mean_91_180,
    o.optical_ndvire_amplitude_0_180,
    o.optical_ndvire_auc_91_180,
    o.optical_cire_peak_0_180,
    o.optical_cire_mean_0_180,
    o.optical_cire_mean_91_180,
    o.optical_cire_amplitude_0_180,
    o.optical_cire_auc_0_180,
    o.optical_cire_auc_91_180,
    o.optical_lswi_mean_91_180,
    o.optical_lswi_mean_91_180_minus_0_90,
    o.optical_lswi_auc_91_180,
    o.optical_ndwi11_mean_91_180,
    o.optical_ndwi11_auc_91_180,
    o.optical_msi11_mean_91_180,
    o.optical_msi11_auc_91_180,

    c.climate_pentad_count_0_180,
    c.climate_max_gap_days_0_180,
    c.climate_precip_acc_0_180,
    c.climate_precip_acc_0_90,
    c.climate_precip_acc_91_180,
    c.climate_eto_acc_0_180,
    c.climate_water_balance_acc_0_180,
    c.climate_water_balance_acc_0_90,
    c.climate_water_balance_acc_91_180,
    c.climate_water_ratio_0_180,
    c.climate_rad_acc_0_180,
    c.climate_gdd_10c_acc_0_180,
    c.climate_tmean_mean_0_180,
    c.climate_tmax_mean_0_180,
    c.climate_tmin_mean_0_180,
    c.climate_rh_mean_0_180,
    c.climate_dry_pentad_count_0_180,
    c.climate_dry_fraction_0_180,
    c.climate_heat_pentad_count_0_180,
    c.climate_water_balance_slope_0_180,
    c.climate_precip_slope_0_180,
    c.climate_rad_slope_0_180,
    c.climate_tmean_slope_0_180,

    e.enso_month_count_asof,
    e.enso_oni_precycle_mean,
    e.enso_oni_asof_mean,
    e.enso_oni_abs_max_asof,
    e.enso_nino34_precycle_mean,
    e.enso_nino34_asof_mean,
    e.enso_soi_precycle_mean,
    e.enso_soi_asof_mean,
    e.enso_el_nino_fraction_asof,
    e.enso_la_nina_fraction_asof
FROM agronomy_core a
LEFT JOIN optical_core o USING (cod_cg_zafra)
LEFT JOIN climate_core c USING (cod_cg_zafra)
LEFT JOIN enso_core e USING (cod_cg_zafra);
