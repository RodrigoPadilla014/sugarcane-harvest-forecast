-- v2_phenology_shape.sql
--
-- For each lot-zafra v2 window, summarise NDVI shape:
--   - ndvi at the start of the window (post-prev-cut zone)
--   - ndvi at the end of the window (pre-cierre zone)
--   - ndvi peak and the *relative* age (0..1) at which it occurs
--   - check that NDVI rose monotonically from start -> peak (no early peak)
--
-- Expected sinusoidal canon: start LOW (just after cut), peak somewhere
-- in the middle/late part of the cycle, possibly fall before harvest.
--
-- We re-derive the v2 window from productividad + stac_indices directly so
-- this audit does not rely on tch_raw_longitudinal.

DROP TABLE IF EXISTS pg_temp.v2_obs;

CREATE TEMP TABLE v2_obs AS
WITH p AS (
    SELECT
        cod_cg_zafra,
        lote AS cod_cg,
        tch,
        edad::numeric AS prod_edad_months,
        to_date(cierre, 'DD/MM/YYYY') AS cierre_date,
        (to_date(cierre, 'DD/MM/YYYY')
          - make_interval(days => greatest(0, round((edad::double precision * 30.44))::integer)))::date AS fecha_inicio_estimada
    FROM productividad
    WHERE tch IS NOT NULL
      AND cierre IS NOT NULL
      AND edad IS NOT NULL
      AND NOT (tch < 20 OR tch > 150)
)
SELECT
    p.cod_cg_zafra,
    p.cod_cg,
    p.tch,
    p.prod_edad_months,
    p.cierre_date,
    p.fecha_inicio_estimada,
    s.fecha::date AS fecha_stac,
    (s.fecha::date - p.fecha_inicio_estimada) AS edad_dias,
    NULLIF(s.ndvi_promedio::text, 'NaN')::double precision AS ndvi
FROM p
JOIN stac_indices s
  ON s.lote = p.cod_cg
 AND s.fecha::date BETWEEN p.fecha_inicio_estimada AND p.cierre_date;

CREATE INDEX ON v2_obs (cod_cg_zafra);

DROP TABLE IF EXISTS pg_temp.v2_shape;

CREATE TEMP TABLE v2_shape AS
WITH cycle AS (
    SELECT
        cod_cg_zafra,
        max(cod_cg) AS cod_cg,
        max(tch) AS tch,
        max(prod_edad_months) AS prod_edad_months,
        max(cierre_date) AS cierre_date,
        max(fecha_inicio_estimada) AS fecha_inicio_estimada,
        max(cierre_date - fecha_inicio_estimada) AS window_days,
        count(ndvi) AS ndvi_obs,
        min(ndvi) AS ndvi_min,
        max(ndvi) AS ndvi_max,
        max(ndvi) - min(ndvi) AS ndvi_amp,
        avg(ndvi) FILTER (WHERE edad_dias <= 30) AS ndvi_first_30d,
        avg(ndvi) FILTER (WHERE edad_dias <= 60) AS ndvi_first_60d,
        avg(ndvi) FILTER (WHERE edad_dias BETWEEN 30 AND 120) AS ndvi_day30_120,
        avg(ndvi) FILTER (
            WHERE edad_dias >= (cierre_date - fecha_inicio_estimada) - 30
        ) AS ndvi_last_30d,
        (array_agg(edad_dias ORDER BY ndvi DESC NULLS LAST, fecha_stac)
            FILTER (WHERE ndvi IS NOT NULL))[1] AS edad_at_peak,
        (array_agg(ndvi ORDER BY ndvi DESC NULLS LAST, fecha_stac)
            FILTER (WHERE ndvi IS NOT NULL))[1] AS ndvi_peak
    FROM v2_obs
    GROUP BY cod_cg_zafra
)
SELECT
    *,
    CASE
        WHEN window_days = 0 THEN NULL
        ELSE edad_at_peak::numeric / window_days
    END AS rel_peak_pos
FROM cycle;

-- Block A: overall NDVI shape across all v2 windows.
SELECT
    count(*) AS lot_zafras,
    round(avg(ndvi_obs)::numeric, 1) AS avg_obs,
    round(avg(ndvi_min)::numeric, 3) AS avg_ndvi_min,
    round(avg(ndvi_first_30d)::numeric, 3) AS avg_ndvi_first_30d,
    round(avg(ndvi_first_60d)::numeric, 3) AS avg_ndvi_first_60d,
    round(avg(ndvi_day30_120)::numeric, 3) AS avg_ndvi_day30_120,
    round(avg(ndvi_peak)::numeric, 3) AS avg_ndvi_peak,
    round(avg(ndvi_last_30d)::numeric, 3) AS avg_ndvi_last_30d,
    round(avg(ndvi_amp)::numeric, 3) AS avg_ndvi_amp,
    round(avg(rel_peak_pos)::numeric, 3) AS avg_rel_peak_pos
FROM v2_shape;

-- Block B: where does the peak land in the window? buckets of relative position.
SELECT
    CASE
        WHEN rel_peak_pos IS NULL THEN 'no_data'
        WHEN rel_peak_pos < 0.10 THEN 'peak_lt_10pct'
        WHEN rel_peak_pos < 0.25 THEN 'peak_10_25pct'
        WHEN rel_peak_pos < 0.50 THEN 'peak_25_50pct'
        WHEN rel_peak_pos < 0.75 THEN 'peak_50_75pct'
        WHEN rel_peak_pos < 0.90 THEN 'peak_75_90pct'
        ELSE 'peak_ge_90pct'
    END AS rel_peak_bucket,
    count(*) AS lot_zafras,
    round(avg(window_days)::numeric, 1) AS avg_window_days,
    round(avg(ndvi_first_60d)::numeric, 3) AS avg_ndvi_first_60d,
    round(avg(ndvi_peak)::numeric, 3) AS avg_ndvi_peak,
    round(avg(ndvi_last_30d)::numeric, 3) AS avg_ndvi_last_30d,
    round(avg(ndvi_amp)::numeric, 3) AS avg_ndvi_amp,
    round(avg(tch)::numeric, 1) AS avg_tch
FROM v2_shape
GROUP BY 1
ORDER BY 1;

-- Block C: anomalous early-peak windows -- likely contamination from prev cycle.
SELECT
    'early_peak (rel<0.25, high start NDVI)' AS issue,
    count(*) AS lot_zafras,
    round(avg(ndvi_first_60d)::numeric, 3) AS avg_ndvi_first_60d,
    round(avg(ndvi_peak)::numeric, 3) AS avg_ndvi_peak,
    round(avg(ndvi_last_30d)::numeric, 3) AS avg_ndvi_last_30d,
    round(avg(ndvi_amp)::numeric, 3) AS avg_ndvi_amp,
    round(avg(window_days)::numeric, 1) AS avg_window_days,
    round(avg(prod_edad_months)::numeric, 2) AS avg_edad
FROM v2_shape
WHERE rel_peak_pos < 0.25
  AND ndvi_first_60d > 0.4
UNION ALL
SELECT
    'late_low_no_decline (peak>=0.75, last>=0.6)' AS issue,
    count(*),
    round(avg(ndvi_first_60d)::numeric, 3),
    round(avg(ndvi_peak)::numeric, 3),
    round(avg(ndvi_last_30d)::numeric, 3),
    round(avg(ndvi_amp)::numeric, 3),
    round(avg(window_days)::numeric, 1),
    round(avg(prod_edad_months)::numeric, 2)
FROM v2_shape
WHERE rel_peak_pos >= 0.75
  AND ndvi_last_30d >= 0.6
UNION ALL
SELECT
    'flat (amp<0.20)' AS issue,
    count(*),
    round(avg(ndvi_first_60d)::numeric, 3),
    round(avg(ndvi_peak)::numeric, 3),
    round(avg(ndvi_last_30d)::numeric, 3),
    round(avg(ndvi_amp)::numeric, 3),
    round(avg(window_days)::numeric, 1),
    round(avg(prod_edad_months)::numeric, 2)
FROM v2_shape
WHERE ndvi_amp < 0.20;

-- Block D: distribution of edad_at_peak in DAYS (test v2 phenology bound [45,360]).
SELECT
    CASE
        WHEN edad_at_peak < 45 THEN 'lt_45d'
        WHEN edad_at_peak < 90 THEN '45_90d'
        WHEN edad_at_peak < 150 THEN '90_150d'
        WHEN edad_at_peak < 240 THEN '150_240d'
        WHEN edad_at_peak < 360 THEN '240_360d'
        ELSE 'ge_360d'
    END AS peak_age_bucket,
    count(*) AS lot_zafras,
    round(avg(tch)::numeric, 1) AS avg_tch,
    round(avg(ndvi_amp)::numeric, 3) AS avg_amp,
    round(avg(ndvi_first_60d)::numeric, 3) AS avg_first_60d
FROM v2_shape
GROUP BY 1
ORDER BY 1;
