-- tch_features_v4_temporal_bins_long.sql
--
-- Canonical v4 temporal dataset.
--
-- Unit:
--   one row per cod_cg_zafra and crop-age bin.
--
-- Goal:
--   Preserve the crop-cycle sequence before pivoting to a one-row-per-lot
--   training table. TCH outliers below 20 or above 150 are excluded here so
--   downstream long and wide datasets use the same clean population.

CREATE OR REPLACE VIEW public.tch_features_v4_temporal_bins_long AS
WITH age_bins AS (
    SELECT *
    FROM (
        VALUES
            ('age_000_090'::text, 0.0::double precision, 90.0::double precision, 1),
            ('age_090_150'::text, 90.0::double precision, 150.0::double precision, 2),
            ('age_150_210'::text, 150.0::double precision, 210.0::double precision, 3),
            ('age_210_270'::text, 210.0::double precision, 270.0::double precision, 4),
            ('age_270_plus'::text, 270.0::double precision, NULL::double precision, 5)
    ) AS b(bin_name, bin_start_age, bin_end_age, bin_order)
),
raw_valid AS (
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

        prod_grupo_de_suelo,
        prod_grupo_de_humedad,
        prod_no_corte,

        stac_ndvi_promedio,
        stac_evi2_promedio,
        stac_lswi_promedio,
        stac_gndvi_promedio,
        stac_ndre_promedio
    FROM public.tch_raw_longitudinal_v4
    WHERE tch IS NOT NULL
      AND tch >= 20
      AND tch <= 150
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
        max(prod_grupo_de_suelo) AS prod_grupo_de_suelo,
        max(prod_grupo_de_humedad) AS prod_grupo_de_humedad,
        max(prod_no_corte) AS prod_no_corte,
        count(*) AS cycle_obs_count
    FROM raw_valid
    GROUP BY cod_cg_zafra
),
cycle_bins AS (
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
        b.prod_grupo_de_suelo,
        b.prod_grupo_de_humedad,
        b.prod_no_corte,
        b.cycle_obs_count,
        ab.bin_name,
        ab.bin_start_age,
        ab.bin_end_age,
        ab.bin_order,
        greatest(
            0.0,
            least(coalesce(ab.bin_end_age, b.cycle_age_max), b.cycle_age_max)
            - ab.bin_start_age
        ) AS bin_coverage_days
    FROM base_cycles b
    CROSS JOIN age_bins ab
),
optical_by_bin AS (
    SELECT
        r.cod_cg_zafra,
        ab.bin_name,
        count(*) AS bin_obs_count,
        count(r.stac_ndvi_promedio) AS optical_obs_count,

        avg(r.stac_ndvi_promedio) AS ndvi_mean,
        max(r.stac_ndvi_promedio) AS ndvi_max,
        min(r.stac_ndvi_promedio) AS ndvi_min,
        regr_slope(r.stac_ndvi_promedio, r.edad_de_cultivo) AS ndvi_slope,

        avg(r.stac_evi2_promedio) AS evi2_mean,
        max(r.stac_evi2_promedio) AS evi2_max,
        min(r.stac_evi2_promedio) AS evi2_min,
        regr_slope(r.stac_evi2_promedio, r.edad_de_cultivo) AS evi2_slope,

        avg(r.stac_lswi_promedio) AS lswi_mean,
        max(r.stac_lswi_promedio) AS lswi_max,
        min(r.stac_lswi_promedio) AS lswi_min,
        regr_slope(r.stac_lswi_promedio, r.edad_de_cultivo) AS lswi_slope,

        avg(r.stac_gndvi_promedio) AS gndvi_mean,
        max(r.stac_gndvi_promedio) AS gndvi_max,
        min(r.stac_gndvi_promedio) AS gndvi_min,
        regr_slope(r.stac_gndvi_promedio, r.edad_de_cultivo) AS gndvi_slope,

        avg(r.stac_ndre_promedio) AS ndre_mean,
        max(r.stac_ndre_promedio) AS ndre_max,
        min(r.stac_ndre_promedio) AS ndre_min,
        regr_slope(r.stac_ndre_promedio, r.edad_de_cultivo) AS ndre_slope
    FROM raw_valid r
    JOIN age_bins ab
      ON r.edad_de_cultivo >= ab.bin_start_age
     AND (ab.bin_end_age IS NULL OR r.edad_de_cultivo < ab.bin_end_age)
    GROUP BY r.cod_cg_zafra, ab.bin_name
),
climate_by_bin AS (
    SELECT
        b.cod_cg_zafra,
        ab.bin_name,
        count(c.fecha_inicio) AS climate_pentad_count,

        sum(c.precipitacion_sum) AS prec_sum,
        sum(c.eto_sum) AS eto_sum,
        sum(c.precipitacion_sum - c.eto_sum) AS water_balance_sum,
        sum(c.precipitacion_sum) / nullif(sum(c.eto_sum), 0) AS water_ratio,
        sum(CASE WHEN c.precipitacion_sum < c.eto_sum THEN 1 ELSE 0 END) AS dry_pentad_count,

        sum(greatest(c.temperatura_mean - 10.0, 0.0) * 5.0) AS gdd_10c_sum,
        sum(c.radiacion_sum) AS radiacion_sum,
        avg(c.temperatura_mean) AS tmean_mean,
        avg(c.temperatura_max) AS tmax_mean,
        avg(c.temperatura_min) AS tmin_mean,
        sum(CASE WHEN c.temperatura_max >= 34 THEN 1 ELSE 0 END) AS heat_pentad_count,
        avg(c.humedad_relativa) AS rh_mean
    FROM base_cycles b
    JOIN age_bins ab ON true
    LEFT JOIN public.clima_lote_pentada_new c
      ON c.cod_cg_zafra = b.cod_cg_zafra
     AND c.fecha_inicio::date >= b.fecha_inicio_ciclo
     AND c.fecha_inicio::date <= b.fecha_fin_ciclo
     AND (c.fecha_inicio::date - b.fecha_inicio_ciclo::date)::double precision >= ab.bin_start_age
     AND (
            ab.bin_end_age IS NULL
            OR (c.fecha_inicio::date - b.fecha_inicio_ciclo::date)::double precision < ab.bin_end_age
         )
    GROUP BY b.cod_cg_zafra, ab.bin_name
)
SELECT
    cb.cod_cg_zafra,
    cb.cod_cg,
    cb.zafra_norm,
    cb.area,
    cb.tch,
    cb.tc,
    cb.fecha_inicio_ciclo,
    cb.fecha_fin_ciclo,
    cb.cycle_age_max,
    cb.prod_grupo_de_suelo,
    cb.prod_grupo_de_humedad,
    cb.prod_no_corte,
    cb.cycle_obs_count,
    cb.bin_name,
    cb.bin_start_age,
    cb.bin_end_age,
    cb.bin_order,
    cb.bin_coverage_days,

    coalesce(o.bin_obs_count, 0) AS bin_obs_count,
    coalesce(o.optical_obs_count, 0) AS optical_obs_count,
    1.0 - (coalesce(o.optical_obs_count, 0)::double precision / nullif(o.bin_obs_count, 0)) AS optical_missing_rate,

    o.ndvi_mean,
    o.ndvi_max,
    o.ndvi_min,
    o.ndvi_slope,
    o.evi2_mean,
    o.evi2_max,
    o.evi2_min,
    o.evi2_slope,
    o.lswi_mean,
    o.lswi_max,
    o.lswi_min,
    o.lswi_slope,
    o.gndvi_mean,
    o.gndvi_max,
    o.gndvi_min,
    o.gndvi_slope,
    o.ndre_mean,
    o.ndre_max,
    o.ndre_min,
    o.ndre_slope,

    coalesce(c.climate_pentad_count, 0) AS climate_pentad_count,
    c.prec_sum,
    c.eto_sum,
    c.water_balance_sum,
    c.water_ratio,
    coalesce(c.dry_pentad_count, 0) AS dry_pentad_count,
    c.gdd_10c_sum,
    c.radiacion_sum,
    c.tmean_mean,
    c.tmax_mean,
    c.tmin_mean,
    coalesce(c.heat_pentad_count, 0) AS heat_pentad_count,
    c.rh_mean
FROM cycle_bins cb
LEFT JOIN optical_by_bin o
  ON o.cod_cg_zafra = cb.cod_cg_zafra
 AND o.bin_name = cb.bin_name
LEFT JOIN climate_by_bin c
  ON c.cod_cg_zafra = cb.cod_cg_zafra
 AND c.bin_name = cb.bin_name;
