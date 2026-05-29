-- tch_features_v5_asof_180d_base.sql
--
-- Cutoff-aware base table for the next production-timing model.
--
-- Prediction timing:
--   Predict final TCH when the crop is 180 days old.
--
-- Leakage rule:
--   This query may use final TCH as the target and harvest/cierre dates as
--   metadata, but all predictor/source summaries must be computed using only
--   observations available on or before fecha_inicio_ciclo + 180 days.
--   Harvest outcomes and harvest-operation fields are intentionally excluded
--   from the static predictor set. Keep tch, tc, and fecha_fin_ciclo as
--   target/evaluation metadata only.
--
-- Coverage rule:
--   Exclude 2019_2020 because STAC, climate, and ENSO coverage before the
--   180-day cutoff is not comparable to later zafras.
--
-- This is intentionally a compact base/skeleton query. Add feature engineering
-- on top of the as-of CTEs below rather than using the full-cycle v4 feature
-- blocks.

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
),
eligible_cycles AS (
    SELECT
        *,
        180::integer AS cutoff_age_days,
        (fecha_inicio_ciclo + INTERVAL '180 days')::date AS cutoff_date
    FROM base_cycles
    WHERE cycle_age_max >= 180
),
optical_asof AS (
    SELECT
        r.cod_cg_zafra,
        r.fecha_stac::date AS fecha_obs,
        r.edad_de_cultivo::double precision AS age_days,
        NULLIF(r.stac_ndvi_promedio::text, 'NaN')::double precision AS ndvi,
        NULLIF(r.stac_evi2_promedio::text, 'NaN')::double precision AS evi2,
        NULLIF(r.stac_gndvi_promedio::text, 'NaN')::double precision AS gndvi,
        NULLIF(r.stac_ndre_promedio::text, 'NaN')::double precision AS ndre,
        NULLIF(r.stac_lswi_promedio::text, 'NaN')::double precision AS lswi
    FROM public.tch_raw_longitudinal_v4 r
    JOIN eligible_cycles b USING (cod_cg_zafra)
    WHERE r.ciclo_valido = true
      AND r.edad_de_cultivo BETWEEN 0 AND b.cutoff_age_days
),
climate_asof AS (
    SELECT
        b.cod_cg_zafra,
        c.fecha_inicio::date AS clima_fecha_inicio,
        (c.fecha_inicio::date - b.fecha_inicio_ciclo)::double precision AS age_days,
        NULLIF(c.precipitacion_sum::text, 'NaN')::double precision AS precip,
        NULLIF(c.eto_sum::text, 'NaN')::double precision AS eto,
        NULLIF(c.temperatura_max::text, 'NaN')::double precision AS tmax,
        NULLIF(c.temperatura_min::text, 'NaN')::double precision AS tmin,
        NULLIF(c.temperatura_mean::text, 'NaN')::double precision AS tmean,
        NULLIF(c.humedad_relativa::text, 'NaN')::double precision AS rh,
        NULLIF(c.radiacion_sum::text, 'NaN')::double precision AS rad
    FROM eligible_cycles b
    LEFT JOIN public.clima_lote_pentada_new c
      ON c.cod_cg = b.cod_cg
     AND c.fecha_inicio::date BETWEEN b.fecha_inicio_ciclo AND b.cutoff_date
),
enso_asof AS (
    SELECT
        b.cod_cg_zafra,
        e.date::date AS enso_month,
        (e.date::date - b.fecha_inicio_ciclo)::double precision AS age_days,
        CASE
            WHEN e.date::date < b.fecha_inicio_ciclo THEN 'precycle_180d'
            WHEN e.date::date <= b.cutoff_date THEN 'asof_0_180d'
            ELSE 'outside'
        END AS enso_window,
        NULLIF(e.oni::text, 'NaN')::double precision AS oni,
        NULLIF(e.nino34::text, 'NaN')::double precision AS nino34,
        NULLIF(e.soi::text, 'NaN')::double precision AS soi
    FROM eligible_cycles b
    LEFT JOIN public.enso e
      ON e.date::date >= b.fecha_inicio_ciclo - INTERVAL '180 days'
     AND e.date::date <= b.cutoff_date
),
coverage AS (
    SELECT
        b.cod_cg_zafra,
        count(DISTINCT o.fecha_obs)::double precision AS optical_obs_count_0_180,
        min(o.age_days) AS optical_first_obs_age_0_180,
        max(o.age_days) AS optical_last_obs_age_0_180,
        count(DISTINCT c.clima_fecha_inicio)::double precision AS climate_pentad_count_0_180,
        count(DISTINCT e.enso_month)::double precision AS enso_month_count_asof
    FROM eligible_cycles b
    LEFT JOIN optical_asof o USING (cod_cg_zafra)
    LEFT JOIN climate_asof c USING (cod_cg_zafra)
    LEFT JOIN enso_asof e USING (cod_cg_zafra)
    GROUP BY b.cod_cg_zafra
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
    b.cutoff_age_days,
    b.cutoff_date,

    b.prod_ingenio,
    b.prod_grupo_de_suelo,
    b.prod_grupo_de_humedad,
    b.prod_codigo_zae,
    b.prod_familia_de_suelo,
    b.prod_variedad,
    b.prod_no_corte,

    c.optical_obs_count_0_180,
    c.optical_first_obs_age_0_180,
    c.optical_last_obs_age_0_180,
    c.climate_pentad_count_0_180,
    c.enso_month_count_asof
FROM eligible_cycles b
LEFT JOIN coverage c USING (cod_cg_zafra);
