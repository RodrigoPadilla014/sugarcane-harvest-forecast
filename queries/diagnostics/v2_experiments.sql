-- v2_experiments.sql
--
-- Experiment with three improvements to the v2 cierre-window logic.
-- TCH bounds [20, 150] are kept identical to baseline.
--
--   E1  Clip window start by previous cierre + 21d buffer:
--          fecha_inicio = MAX(cierre - edad*30.44, prev_cierre + 21)
--
--   E2  NDVI-anchored start: pick the LATEST date in the candidate window
--       with NDVI < 0.25 as fecha_inicio_real (post-cut bare soil signal).
--       Fall back to baseline start if no such date exists.
--
--   E3  Shape gate (replaces v2 amp>=0.35 + peak in [45,360]):
--         ndvi_first_60d < 0.35
--         AND ndvi_max > 0.60
--         AND ndvi_amp > 0.40
--         AND rel_peak_pos BETWEEN 0.25 AND 0.95
--
-- For each variant we report: lots kept, mean shape (first_60d, peak, last_30d,
-- amp, rel_peak_pos), avg TCH. Compare against baseline.

DROP TABLE IF EXISTS pg_temp.prod_filt;

CREATE TEMP TABLE prod_filt AS
SELECT
    cod_cg_zafra,
    lote AS cod_cg,
    tch,
    edad::numeric AS prod_edad_months,
    to_date(cierre, 'DD/MM/YYYY') AS cierre_date,
    (to_date(cierre, 'DD/MM/YYYY')
      - make_interval(days => greatest(0, round((edad::double precision * 30.44))::integer)))::date AS fecha_inicio_baseline,
    lag(to_date(cierre, 'DD/MM/YYYY')) OVER (
        PARTITION BY lote ORDER BY to_date(cierre, 'DD/MM/YYYY')
    ) AS prev_cierre_date
FROM productividad
WHERE tch IS NOT NULL
  AND cierre IS NOT NULL
  AND edad IS NOT NULL
  AND NOT (tch < 20 OR tch > 150);

CREATE INDEX ON prod_filt (cod_cg_zafra);
CREATE INDEX ON prod_filt (cod_cg);

-- Common: pull all candidate STAC obs once over the widest possible window
-- (baseline start). E1/E2 just re-filter rows from this pool.
DROP TABLE IF EXISTS pg_temp.cand_obs;

CREATE TEMP TABLE cand_obs AS
SELECT
    p.cod_cg_zafra,
    p.tch,
    p.cierre_date,
    p.fecha_inicio_baseline,
    p.prev_cierre_date,
    s.fecha::date AS fecha_stac,
    NULLIF(s.ndvi_promedio::text, 'NaN')::double precision AS ndvi
FROM prod_filt p
JOIN stac_indices s
  ON s.lote = p.cod_cg
 AND s.fecha::date BETWEEN p.fecha_inicio_baseline AND p.cierre_date;

CREATE INDEX ON cand_obs (cod_cg_zafra);

-- Helper: per-cycle shape for a given start date. We parametrise by computing
-- shape in a single CTE that takes fecha_inicio_v as an input column.
-- For each experiment we materialise a separate <exp>_shape table.

----------------------------------------------------------------------
-- Variant B (baseline) shape, for direct comparison.
----------------------------------------------------------------------
DROP TABLE IF EXISTS pg_temp.shape_B;
CREATE TEMP TABLE shape_B AS
SELECT
    cod_cg_zafra,
    max(tch) AS tch,
    max(cierre_date - fecha_inicio_baseline) AS window_days,
    count(ndvi) AS ndvi_obs,
    max(fecha_stac - fecha_inicio_baseline) AS max_edad,
    min(ndvi) AS ndvi_min,
    max(ndvi) AS ndvi_max,
    max(ndvi) - min(ndvi) AS ndvi_amp,
    avg(ndvi) FILTER (WHERE (fecha_stac - fecha_inicio_baseline) <= 60) AS ndvi_first_60d,
    avg(ndvi) FILTER (
        WHERE (fecha_stac - fecha_inicio_baseline) >= ((cierre_date - fecha_inicio_baseline) - 30)
    ) AS ndvi_last_30d,
    (array_agg((fecha_stac - fecha_inicio_baseline) ORDER BY ndvi DESC NULLS LAST, fecha_stac)
        FILTER (WHERE ndvi IS NOT NULL))[1] AS edad_at_peak
FROM cand_obs
GROUP BY cod_cg_zafra;

----------------------------------------------------------------------
-- E1: clip start by previous cierre + 21d.
----------------------------------------------------------------------
DROP TABLE IF EXISTS pg_temp.cand_E1;
CREATE TEMP TABLE cand_E1 AS
SELECT
    c.*,
    GREATEST(
        c.fecha_inicio_baseline,
        COALESCE(c.prev_cierre_date + INTERVAL '21 day', c.fecha_inicio_baseline)::date
    ) AS fecha_inicio_e1
FROM cand_obs c;

DROP TABLE IF EXISTS pg_temp.shape_E1;
CREATE TEMP TABLE shape_E1 AS
SELECT
    cod_cg_zafra,
    max(tch) AS tch,
    max(cierre_date - fecha_inicio_e1) AS window_days,
    count(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e1) AS ndvi_obs,
    max(fecha_stac - fecha_inicio_e1) FILTER (WHERE fecha_stac >= fecha_inicio_e1) AS max_edad,
    min(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e1) AS ndvi_min,
    max(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e1) AS ndvi_max,
    max(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e1)
        - min(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e1) AS ndvi_amp,
    avg(ndvi) FILTER (
        WHERE fecha_stac >= fecha_inicio_e1
          AND (fecha_stac - fecha_inicio_e1) <= 60
    ) AS ndvi_first_60d,
    avg(ndvi) FILTER (
        WHERE fecha_stac >= fecha_inicio_e1
          AND (fecha_stac - fecha_inicio_e1) >= ((cierre_date - fecha_inicio_e1) - 30)
    ) AS ndvi_last_30d,
    (array_agg((fecha_stac - fecha_inicio_e1) ORDER BY ndvi DESC NULLS LAST, fecha_stac)
        FILTER (WHERE ndvi IS NOT NULL AND fecha_stac >= fecha_inicio_e1))[1] AS edad_at_peak
FROM cand_E1
GROUP BY cod_cg_zafra;

----------------------------------------------------------------------
-- E2: NDVI-anchored start.
--   fecha_inicio_e2 = latest date in [baseline_start, cierre - 90d]
--                     with NDVI < 0.25; else baseline_start.
--   (cap at cierre-90d so we don't collapse the window into peak/decline.)
----------------------------------------------------------------------
DROP TABLE IF EXISTS pg_temp.bare_dates;
CREATE TEMP TABLE bare_dates AS
SELECT
    c.cod_cg_zafra,
    max(c.fecha_stac) AS fecha_inicio_e2_candidate
FROM cand_obs c
WHERE c.ndvi IS NOT NULL
  AND c.ndvi < 0.25
  AND c.fecha_stac <= c.cierre_date - INTERVAL '90 day'
GROUP BY c.cod_cg_zafra;

DROP TABLE IF EXISTS pg_temp.cand_E2;
CREATE TEMP TABLE cand_E2 AS
SELECT
    c.*,
    COALESCE(b.fecha_inicio_e2_candidate, c.fecha_inicio_baseline) AS fecha_inicio_e2
FROM cand_obs c
LEFT JOIN bare_dates b USING (cod_cg_zafra);

DROP TABLE IF EXISTS pg_temp.shape_E2;
CREATE TEMP TABLE shape_E2 AS
SELECT
    cod_cg_zafra,
    max(tch) AS tch,
    max(cierre_date - fecha_inicio_e2) AS window_days,
    count(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e2) AS ndvi_obs,
    max(fecha_stac - fecha_inicio_e2) FILTER (WHERE fecha_stac >= fecha_inicio_e2) AS max_edad,
    min(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e2) AS ndvi_min,
    max(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e2) AS ndvi_max,
    max(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e2)
        - min(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e2) AS ndvi_amp,
    avg(ndvi) FILTER (
        WHERE fecha_stac >= fecha_inicio_e2
          AND (fecha_stac - fecha_inicio_e2) <= 60
    ) AS ndvi_first_60d,
    avg(ndvi) FILTER (
        WHERE fecha_stac >= fecha_inicio_e2
          AND (fecha_stac - fecha_inicio_e2) >= ((cierre_date - fecha_inicio_e2) - 30)
    ) AS ndvi_last_30d,
    (array_agg((fecha_stac - fecha_inicio_e2) ORDER BY ndvi DESC NULLS LAST, fecha_stac)
        FILTER (WHERE ndvi IS NOT NULL AND fecha_stac >= fecha_inicio_e2))[1] AS edad_at_peak
FROM cand_E2
GROUP BY cod_cg_zafra;

----------------------------------------------------------------------
-- E1+E2 combined: clip by prev cierre AND then NDVI-anchor.
----------------------------------------------------------------------
DROP TABLE IF EXISTS pg_temp.bare_dates_e12;
CREATE TEMP TABLE bare_dates_e12 AS
SELECT
    e1.cod_cg_zafra,
    max(e1.fecha_stac) AS fecha_inicio_e12_candidate
FROM cand_E1 e1
WHERE e1.ndvi IS NOT NULL
  AND e1.ndvi < 0.25
  AND e1.fecha_stac >= e1.fecha_inicio_e1
  AND e1.fecha_stac <= e1.cierre_date - INTERVAL '90 day'
GROUP BY e1.cod_cg_zafra;

DROP TABLE IF EXISTS pg_temp.cand_E12;
CREATE TEMP TABLE cand_E12 AS
SELECT
    e1.*,
    COALESCE(b.fecha_inicio_e12_candidate, e1.fecha_inicio_e1) AS fecha_inicio_e12
FROM cand_E1 e1
LEFT JOIN bare_dates_e12 b USING (cod_cg_zafra);

DROP TABLE IF EXISTS pg_temp.shape_E12;
CREATE TEMP TABLE shape_E12 AS
SELECT
    cod_cg_zafra,
    max(tch) AS tch,
    max(cierre_date - fecha_inicio_e12) AS window_days,
    count(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e12) AS ndvi_obs,
    max(fecha_stac - fecha_inicio_e12) FILTER (WHERE fecha_stac >= fecha_inicio_e12) AS max_edad,
    min(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e12) AS ndvi_min,
    max(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e12) AS ndvi_max,
    max(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e12)
        - min(ndvi) FILTER (WHERE fecha_stac >= fecha_inicio_e12) AS ndvi_amp,
    avg(ndvi) FILTER (
        WHERE fecha_stac >= fecha_inicio_e12
          AND (fecha_stac - fecha_inicio_e12) <= 60
    ) AS ndvi_first_60d,
    avg(ndvi) FILTER (
        WHERE fecha_stac >= fecha_inicio_e12
          AND (fecha_stac - fecha_inicio_e12) >= ((cierre_date - fecha_inicio_e12) - 30)
    ) AS ndvi_last_30d,
    (array_agg((fecha_stac - fecha_inicio_e12) ORDER BY ndvi DESC NULLS LAST, fecha_stac)
        FILTER (WHERE ndvi IS NOT NULL AND fecha_stac >= fecha_inicio_e12))[1] AS edad_at_peak
FROM cand_E12
GROUP BY cod_cg_zafra;

----------------------------------------------------------------------
-- Reports.
----------------------------------------------------------------------
-- Block 1: side-by-side shape across variants.
SELECT 'B  (baseline)' AS variant,
       count(*) AS lots,
       round(avg(window_days)::numeric, 1) AS avg_window_d,
       round(avg(ndvi_obs)::numeric, 1) AS avg_obs,
       round(avg(ndvi_first_60d)::numeric, 3) AS first_60d,
       round(avg(ndvi_max)::numeric, 3) AS peak,
       round(avg(ndvi_last_30d)::numeric, 3) AS last_30d,
       round(avg(ndvi_amp)::numeric, 3) AS amp,
       round(avg(edad_at_peak::numeric / NULLIF(window_days, 0)), 3) AS avg_rel_peak,
       round(avg(tch)::numeric, 1) AS avg_tch
FROM shape_B
UNION ALL
SELECT 'E1 (clip prev+21d)',
       count(*),
       round(avg(window_days)::numeric, 1),
       round(avg(ndvi_obs)::numeric, 1),
       round(avg(ndvi_first_60d)::numeric, 3),
       round(avg(ndvi_max)::numeric, 3),
       round(avg(ndvi_last_30d)::numeric, 3),
       round(avg(ndvi_amp)::numeric, 3),
       round(avg(edad_at_peak::numeric / NULLIF(window_days, 0)), 3),
       round(avg(tch)::numeric, 1)
FROM shape_E1
UNION ALL
SELECT 'E2 (NDVI-anchor)',
       count(*),
       round(avg(window_days)::numeric, 1),
       round(avg(ndvi_obs)::numeric, 1),
       round(avg(ndvi_first_60d)::numeric, 3),
       round(avg(ndvi_max)::numeric, 3),
       round(avg(ndvi_last_30d)::numeric, 3),
       round(avg(ndvi_amp)::numeric, 3),
       round(avg(edad_at_peak::numeric / NULLIF(window_days, 0)), 3),
       round(avg(tch)::numeric, 1)
FROM shape_E2
UNION ALL
SELECT 'E12 (E1 + E2)',
       count(*),
       round(avg(window_days)::numeric, 1),
       round(avg(ndvi_obs)::numeric, 1),
       round(avg(ndvi_first_60d)::numeric, 3),
       round(avg(ndvi_max)::numeric, 3),
       round(avg(ndvi_last_30d)::numeric, 3),
       round(avg(ndvi_amp)::numeric, 3),
       round(avg(edad_at_peak::numeric / NULLIF(window_days, 0)), 3),
       round(avg(tch)::numeric, 1)
FROM shape_E12
ORDER BY 1;

-- Block 2: each variant after the E3 shape gate is applied.
WITH apply_e3 AS (
    SELECT 'B'  AS variant, * FROM shape_B
    UNION ALL SELECT 'E1', * FROM shape_E1
    UNION ALL SELECT 'E2', * FROM shape_E2
    UNION ALL SELECT 'E12', * FROM shape_E12
),
flagged AS (
    SELECT variant,
           tch,
           ndvi_obs,
           max_edad,
           window_days,
           ndvi_first_60d,
           ndvi_max,
           ndvi_amp,
           ndvi_last_30d,
           edad_at_peak,
           (edad_at_peak::numeric / NULLIF(window_days, 0)) AS rel_peak,
           (ndvi_obs >= 7 AND max_edad >= 150
             AND ndvi_amp >= 0.35
             AND edad_at_peak BETWEEN 45 AND 360) AS pass_v2,
           (ndvi_first_60d < 0.35
             AND ndvi_max > 0.60
             AND ndvi_amp > 0.40
             AND (edad_at_peak::numeric / NULLIF(window_days, 0)) BETWEEN 0.25 AND 0.95
             AND ndvi_obs >= 7) AS pass_e3
    FROM apply_e3
)
SELECT
    variant,
    sum(CASE WHEN pass_v2 THEN 1 ELSE 0 END) AS v2_valid,
    sum(CASE WHEN pass_e3 THEN 1 ELSE 0 END) AS e3_valid,
    sum(CASE WHEN pass_v2 AND pass_e3 THEN 1 ELSE 0 END) AS both,
    sum(CASE WHEN pass_v2 AND NOT pass_e3 THEN 1 ELSE 0 END) AS v2_only,
    sum(CASE WHEN NOT pass_v2 AND pass_e3 THEN 1 ELSE 0 END) AS e3_only
FROM flagged
GROUP BY variant
ORDER BY variant;

-- Block 3: mean shape AMONG e3-passing rows (i.e. how clean is the surviving set?).
WITH apply_e3 AS (
    SELECT 'B'  AS variant, * FROM shape_B
    UNION ALL SELECT 'E1', * FROM shape_E1
    UNION ALL SELECT 'E2', * FROM shape_E2
    UNION ALL SELECT 'E12', * FROM shape_E12
)
SELECT
    variant,
    count(*) AS lots_e3_valid,
    round(avg(window_days)::numeric, 1) AS avg_window_d,
    round(avg(ndvi_first_60d)::numeric, 3) AS first_60d,
    round(avg(ndvi_max)::numeric, 3) AS peak,
    round(avg(ndvi_last_30d)::numeric, 3) AS last_30d,
    round(avg(ndvi_amp)::numeric, 3) AS amp,
    round(avg(tch)::numeric, 1) AS avg_tch
FROM apply_e3
WHERE ndvi_first_60d < 0.35
  AND ndvi_max > 0.60
  AND ndvi_amp > 0.40
  AND (edad_at_peak::numeric / NULLIF(window_days, 0)) BETWEEN 0.25 AND 0.95
  AND ndvi_obs >= 7
GROUP BY variant
ORDER BY variant;
