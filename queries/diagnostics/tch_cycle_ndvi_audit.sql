-- tch_cycle_ndvi_audit.sql
--
-- Audit the current public.tch_raw_longitudinal crop-age / close-date logic
-- against the raw STAC NDVI signal.
--
-- Key questions:
--   1. Which lot-seasons are marked valid/invalid by tch_raw_longitudinal?
--   2. How many valid observations occur after productividad.cierre_date?
--   3. Which invalid lot-seasons still show a strong NDVI growth/cut signal?
--
-- Notes:
--   - productividad.edad appears to be months; edad_de_cultivo is days.
--   - stac_indices has some floating NaN NDVI values, so this query converts
--     NaN to SQL NULL before calculating phenology metrics.

DROP TABLE IF EXISTS pg_temp.tch_cycle_ndvi_audit;

CREATE TEMP TABLE tch_cycle_ndvi_audit AS
WITH raw_cycle AS (
    SELECT
        cod_cg_zafra,
        max(cod_cg) AS cod_cg,
        bool_or(ciclo_valido) AS valid,
        count(*) AS raw_obs,
        count(*) FILTER (WHERE gap_in_data) AS gap_obs,
        count(*) FILTER (WHERE edad_de_cultivo IS NOT NULL) AS age_obs,
        max(edad_de_cultivo) AS max_age,
        min(fecha_stac) AS first_raw_stac,
        max(fecha_stac) AS last_raw_stac,
        min(cierre_date)::date AS prod_cierre,
        min(cierre_ciclo)::date AS min_cycle_cierre,
        max(cierre_ciclo)::date AS max_cycle_cierre,
        count(*) FILTER (WHERE fecha_stac <= cierre_date) AS pre_or_on_cierre_obs,
        count(*) FILTER (WHERE fecha_stac > cierre_date) AS post_cierre_obs,
        count(*) FILTER (WHERE ciclo_valido AND fecha_stac > cierre_date) AS valid_post_cierre_obs,
        max(fecha_stac - cierre_date) FILTER (
            WHERE ciclo_valido AND fecha_stac > cierre_date
        ) AS max_days_after_cierre
    FROM public.tch_raw_longitudinal
    WHERE tch IS NOT NULL
      AND cod_cg_zafra IS NOT NULL
      AND zafra_norm IS NOT NULL
      AND area IS NOT NULL
    GROUP BY cod_cg_zafra
),
stac_productividad AS (
    SELECT
        s.cod_cg_zafra,
        s.fecha::date AS fecha_stac,
        NULLIF(s.ndvi_promedio::text, 'NaN')::double precision AS ndvi,
        p.edad AS prod_edad_months,
        to_date(p.cierre, 'DD/MM/YYYY') AS prod_cierre_date
    FROM public.stac_indices s
    JOIN public.productividad p
      ON p.cod_cg_zafra = s.cod_cg_zafra
    WHERE p.tch IS NOT NULL
      AND p.cierre IS NOT NULL
),
phenology_1 AS (
    SELECT
        cod_cg_zafra,
        min(fecha_stac) AS first_stac,
        max(fecha_stac) AS last_stac,
        count(ndvi) AS ndvi_obs,
        min(ndvi) AS ndvi_min,
        max(ndvi) AS ndvi_max,
        max(ndvi) - min(ndvi) AS ndvi_amp,
        (
            array_agg(fecha_stac ORDER BY ndvi DESC NULLS LAST, fecha_stac)
            FILTER (WHERE ndvi IS NOT NULL)
        )[1] AS peak_date,
        max(prod_edad_months) AS prod_edad_months,
        max(prod_cierre_date) AS prod_cierre_date
    FROM stac_productividad
    GROUP BY cod_cg_zafra
),
phenology AS (
    SELECT
        p.*,
        max(s.ndvi) FILTER (WHERE s.fecha_stac <= p.peak_date)
            - min(s.ndvi) FILTER (WHERE s.fecha_stac <= p.peak_date) AS rise_to_peak,
        max(s.ndvi) FILTER (WHERE s.fecha_stac >= p.peak_date)
            - min(s.ndvi) FILTER (WHERE s.fecha_stac >= p.peak_date) AS fall_after_peak,
        count(*) FILTER (
            WHERE s.fecha_stac >= p.peak_date
              AND s.ndvi < 0.2
        ) AS low_after_peak_obs
    FROM phenology_1 p
    JOIN stac_productividad s USING (cod_cg_zafra)
    GROUP BY
        p.cod_cg_zafra,
        p.first_stac,
        p.last_stac,
        p.ndvi_obs,
        p.ndvi_min,
        p.ndvi_max,
        p.ndvi_amp,
        p.peak_date,
        p.prod_edad_months,
        p.prod_cierre_date
),
classified AS (
    SELECT
        r.*,
        p.ndvi_obs,
        p.ndvi_min,
        p.ndvi_max,
        p.ndvi_amp,
        p.peak_date,
        p.prod_edad_months,
        p.rise_to_peak,
        p.fall_after_peak,
        p.low_after_peak_obs,
        CASE
            WHEN r.valid THEN 'valid'
            WHEN r.gap_obs > 0 THEN 'invalid_gap_or_null_age'
            WHEN r.age_obs = 0 THEN 'invalid_no_age_in_raw'
            WHEN r.age_obs < 7 THEN 'invalid_lt_7_age_obs'
            WHEN r.max_age < 150 OR r.max_age IS NULL THEN 'invalid_max_age_lt_150_or_null'
            ELSE 'invalid_other'
        END AS raw_status_hint,
        CASE
            WHEN p.ndvi_obs >= 7
             AND p.ndvi_amp >= 0.35
             AND p.rise_to_peak >= 0.25
             AND (p.fall_after_peak >= 0.25 OR p.low_after_peak_obs > 0)
            THEN true
            ELSE false
        END AS ndvi_supports_growth_cut_cycle
    FROM raw_cycle r
    JOIN phenology p USING (cod_cg_zafra)
)
SELECT *
FROM classified;

-- Block 1: high-level validity vs NDVI support.
SELECT
    raw_status_hint,
    ndvi_supports_growth_cut_cycle,
    count(*) AS lot_seasons,
    round(avg(raw_obs)::numeric, 1) AS avg_raw_obs,
    round(avg(age_obs)::numeric, 1) AS avg_age_obs,
    round(avg(max_age)::numeric, 1) AS avg_max_age_days,
    round(avg(prod_edad_months)::numeric, 1) AS avg_prod_edad_months,
    round(avg(ndvi_amp)::numeric, 3) AS avg_ndvi_amp,
    round(avg(rise_to_peak)::numeric, 3) AS avg_rise_to_peak,
    round(avg(fall_after_peak)::numeric, 3) AS avg_fall_after_peak
FROM tch_cycle_ndvi_audit
GROUP BY raw_status_hint, ndvi_supports_growth_cut_cycle
ORDER BY raw_status_hint, ndvi_supports_growth_cut_cycle;

-- Block 2: valid rows that occur after productividad.cierre_date.
SELECT
    valid,
    CASE
        WHEN valid_post_cierre_obs = 0 THEN 'no_valid_post_cierre_rows'
        WHEN valid_post_cierre_obs::double precision / raw_obs < 0.25 THEN '<25% post_cierre'
        WHEN valid_post_cierre_obs::double precision / raw_obs < 0.50 THEN '25-50% post_cierre'
        ELSE '>=50% post_cierre'
    END AS post_cierre_share_bucket,
    count(*) AS lot_seasons,
    round(avg(raw_obs)::numeric, 1) AS avg_raw_obs,
    round(avg(pre_or_on_cierre_obs)::numeric, 1) AS avg_pre_or_on_cierre_obs,
    round(avg(valid_post_cierre_obs)::numeric, 1) AS avg_valid_post_cierre_obs,
    max(max_days_after_cierre) AS max_days_after_cierre
FROM tch_cycle_ndvi_audit
GROUP BY
    valid,
    CASE
        WHEN valid_post_cierre_obs = 0 THEN 'no_valid_post_cierre_rows'
        WHEN valid_post_cierre_obs::double precision / raw_obs < 0.25 THEN '<25% post_cierre'
        WHEN valid_post_cierre_obs::double precision / raw_obs < 0.50 THEN '25-50% post_cierre'
        ELSE '>=50% post_cierre'
    END
ORDER BY valid, lot_seasons DESC;

-- Block 3: examples of invalid lot-seasons with strong NDVI support.
SELECT
    cod_cg_zafra,
    cod_cg,
    raw_status_hint,
    raw_obs,
    age_obs,
    max_age,
    prod_cierre,
    min_cycle_cierre,
    max_cycle_cierre,
    prod_edad_months,
    first_raw_stac,
    last_raw_stac,
    peak_date,
    round(ndvi_min::numeric, 3) AS ndvi_min,
    round(ndvi_max::numeric, 3) AS ndvi_max,
    round(ndvi_amp::numeric, 3) AS ndvi_amp,
    round(rise_to_peak::numeric, 3) AS rise_to_peak,
    round(fall_after_peak::numeric, 3) AS fall_after_peak,
    low_after_peak_obs
FROM tch_cycle_ndvi_audit
WHERE valid = false
  AND ndvi_supports_growth_cut_cycle = true
ORDER BY ndvi_amp DESC, raw_obs DESC
LIMIT 50;
