-- v2_experiments_v2.sql
--
-- Refined experiments. Same baseline as v2_experiments.sql plus the same
-- TCH bounds. New variants:
--
--   E1  Clip start by previous cierre + 21d (unchanged).
--
--   E2b NDVI-anchored start (refined):
--       Look ONLY in the first half of the baseline window
--       ([baseline_start, baseline_start + 0.5*window]).
--       Pick the date of MINIMUM NDVI in that prefix; if min <= 0.30,
--       use it as the real start (post-cut bare soil moment).
--       Else fall back to baseline_start.
--
--   E12b  Combine E1 (prev-cierre clip) THEN E2b (NDVI-anchor inside the
--         clipped window's first half).
--
--   E3 (shape gate) applied to all variants for fairness.

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
CREATE INDEX ON prod_filt (cod_cg);
CREATE INDEX ON prod_filt (cod_cg_zafra);

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

-- E1 start.
DROP TABLE IF EXISTS pg_temp.cycle_starts;
CREATE TEMP TABLE cycle_starts AS
SELECT
    cod_cg_zafra,
    fecha_inicio_baseline,
    cierre_date,
    GREATEST(
        fecha_inicio_baseline,
        COALESCE(prev_cierre_date + INTERVAL '21 day', fecha_inicio_baseline)::date
    ) AS fecha_inicio_e1
FROM prod_filt;
CREATE INDEX ON cycle_starts (cod_cg_zafra);

-- E2b: find min-NDVI date in the first half of the BASELINE window.
DROP TABLE IF EXISTS pg_temp.e2b_anchor;
CREATE TEMP TABLE e2b_anchor AS
WITH first_half AS (
    SELECT
        c.cod_cg_zafra,
        c.fecha_stac,
        c.ndvi,
        c.fecha_inicio_baseline,
        c.cierre_date,
        row_number() OVER (
            PARTITION BY c.cod_cg_zafra
            ORDER BY c.ndvi ASC NULLS LAST, c.fecha_stac
        ) AS rk
    FROM cand_obs c
    WHERE c.ndvi IS NOT NULL
      AND c.fecha_stac <= c.fecha_inicio_baseline
            + ((c.cierre_date - c.fecha_inicio_baseline) / 2)
)
SELECT
    cod_cg_zafra,
    fecha_stac AS min_ndvi_date,
    ndvi AS min_ndvi
FROM first_half
WHERE rk = 1;

DROP TABLE IF EXISTS pg_temp.e2b_starts;
CREATE TEMP TABLE e2b_starts AS
SELECT
    p.cod_cg_zafra,
    p.fecha_inicio_baseline,
    p.cierre_date,
    CASE
        WHEN a.min_ndvi IS NOT NULL AND a.min_ndvi <= 0.30
            THEN a.min_ndvi_date
        ELSE p.fecha_inicio_baseline
    END AS fecha_inicio_e2b
FROM prod_filt p
LEFT JOIN e2b_anchor a USING (cod_cg_zafra);

-- E12b: E1 then anchor inside the E1-clipped first half.
DROP TABLE IF EXISTS pg_temp.e12b_anchor;
CREATE TEMP TABLE e12b_anchor AS
WITH joined AS (
    SELECT
        c.cod_cg_zafra,
        c.fecha_stac,
        c.ndvi,
        cs.fecha_inicio_e1,
        cs.cierre_date
    FROM cand_obs c
    JOIN cycle_starts cs USING (cod_cg_zafra)
    WHERE c.ndvi IS NOT NULL
      AND c.fecha_stac >= cs.fecha_inicio_e1
      AND c.fecha_stac <= cs.fecha_inicio_e1
            + ((cs.cierre_date - cs.fecha_inicio_e1) / 2)
),
ranked AS (
    SELECT
        cod_cg_zafra,
        fecha_stac,
        ndvi,
        row_number() OVER (
            PARTITION BY cod_cg_zafra
            ORDER BY ndvi ASC NULLS LAST, fecha_stac
        ) AS rk
    FROM joined
)
SELECT cod_cg_zafra, fecha_stac AS min_ndvi_date, ndvi AS min_ndvi
FROM ranked
WHERE rk = 1;

DROP TABLE IF EXISTS pg_temp.e12b_starts;
CREATE TEMP TABLE e12b_starts AS
SELECT
    cs.cod_cg_zafra,
    cs.cierre_date,
    cs.fecha_inicio_e1,
    CASE
        WHEN a.min_ndvi IS NOT NULL AND a.min_ndvi <= 0.30
            THEN a.min_ndvi_date
        ELSE cs.fecha_inicio_e1
    END AS fecha_inicio_e12b
FROM cycle_starts cs
LEFT JOIN e12b_anchor a USING (cod_cg_zafra);

-- Shape macro via a single function-like helper expressed inline per variant.
-- We compute shape for each variant by joining cand_obs to the chosen start.

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
        WHERE (fecha_stac - fecha_inicio_baseline)
              >= ((cierre_date - fecha_inicio_baseline) - 30)
    ) AS ndvi_last_30d,
    (array_agg((fecha_stac - fecha_inicio_baseline) ORDER BY ndvi DESC NULLS LAST, fecha_stac)
        FILTER (WHERE ndvi IS NOT NULL))[1] AS edad_at_peak
FROM cand_obs
GROUP BY cod_cg_zafra;

DROP TABLE IF EXISTS pg_temp.shape_E1;
CREATE TEMP TABLE shape_E1 AS
SELECT
    cs.cod_cg_zafra,
    max(c.tch) AS tch,
    max(cs.cierre_date - cs.fecha_inicio_e1) AS window_days,
    count(c.ndvi) FILTER (WHERE c.fecha_stac >= cs.fecha_inicio_e1) AS ndvi_obs,
    max(c.fecha_stac - cs.fecha_inicio_e1) FILTER (WHERE c.fecha_stac >= cs.fecha_inicio_e1) AS max_edad,
    min(c.ndvi) FILTER (WHERE c.fecha_stac >= cs.fecha_inicio_e1) AS ndvi_min,
    max(c.ndvi) FILTER (WHERE c.fecha_stac >= cs.fecha_inicio_e1) AS ndvi_max,
    max(c.ndvi) FILTER (WHERE c.fecha_stac >= cs.fecha_inicio_e1)
        - min(c.ndvi) FILTER (WHERE c.fecha_stac >= cs.fecha_inicio_e1) AS ndvi_amp,
    avg(c.ndvi) FILTER (
        WHERE c.fecha_stac >= cs.fecha_inicio_e1
          AND (c.fecha_stac - cs.fecha_inicio_e1) <= 60
    ) AS ndvi_first_60d,
    avg(c.ndvi) FILTER (
        WHERE c.fecha_stac >= cs.fecha_inicio_e1
          AND (c.fecha_stac - cs.fecha_inicio_e1) >= ((cs.cierre_date - cs.fecha_inicio_e1) - 30)
    ) AS ndvi_last_30d,
    (array_agg((c.fecha_stac - cs.fecha_inicio_e1)
        ORDER BY c.ndvi DESC NULLS LAST, c.fecha_stac)
        FILTER (WHERE c.ndvi IS NOT NULL AND c.fecha_stac >= cs.fecha_inicio_e1))[1] AS edad_at_peak
FROM cand_obs c
JOIN cycle_starts cs USING (cod_cg_zafra)
GROUP BY cs.cod_cg_zafra;

DROP TABLE IF EXISTS pg_temp.shape_E2b;
CREATE TEMP TABLE shape_E2b AS
SELECT
    s.cod_cg_zafra,
    max(c.tch) AS tch,
    max(s.cierre_date - s.fecha_inicio_e2b) AS window_days,
    count(c.ndvi) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e2b) AS ndvi_obs,
    max(c.fecha_stac - s.fecha_inicio_e2b) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e2b) AS max_edad,
    min(c.ndvi) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e2b) AS ndvi_min,
    max(c.ndvi) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e2b) AS ndvi_max,
    max(c.ndvi) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e2b)
        - min(c.ndvi) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e2b) AS ndvi_amp,
    avg(c.ndvi) FILTER (
        WHERE c.fecha_stac >= s.fecha_inicio_e2b
          AND (c.fecha_stac - s.fecha_inicio_e2b) <= 60
    ) AS ndvi_first_60d,
    avg(c.ndvi) FILTER (
        WHERE c.fecha_stac >= s.fecha_inicio_e2b
          AND (c.fecha_stac - s.fecha_inicio_e2b) >= ((s.cierre_date - s.fecha_inicio_e2b) - 30)
    ) AS ndvi_last_30d,
    (array_agg((c.fecha_stac - s.fecha_inicio_e2b)
        ORDER BY c.ndvi DESC NULLS LAST, c.fecha_stac)
        FILTER (WHERE c.ndvi IS NOT NULL AND c.fecha_stac >= s.fecha_inicio_e2b))[1] AS edad_at_peak
FROM cand_obs c
JOIN e2b_starts s USING (cod_cg_zafra)
GROUP BY s.cod_cg_zafra;

DROP TABLE IF EXISTS pg_temp.shape_E12b;
CREATE TEMP TABLE shape_E12b AS
SELECT
    s.cod_cg_zafra,
    max(c.tch) AS tch,
    max(s.cierre_date - s.fecha_inicio_e12b) AS window_days,
    count(c.ndvi) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e12b) AS ndvi_obs,
    max(c.fecha_stac - s.fecha_inicio_e12b) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e12b) AS max_edad,
    min(c.ndvi) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e12b) AS ndvi_min,
    max(c.ndvi) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e12b) AS ndvi_max,
    max(c.ndvi) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e12b)
        - min(c.ndvi) FILTER (WHERE c.fecha_stac >= s.fecha_inicio_e12b) AS ndvi_amp,
    avg(c.ndvi) FILTER (
        WHERE c.fecha_stac >= s.fecha_inicio_e12b
          AND (c.fecha_stac - s.fecha_inicio_e12b) <= 60
    ) AS ndvi_first_60d,
    avg(c.ndvi) FILTER (
        WHERE c.fecha_stac >= s.fecha_inicio_e12b
          AND (c.fecha_stac - s.fecha_inicio_e12b) >= ((s.cierre_date - s.fecha_inicio_e12b) - 30)
    ) AS ndvi_last_30d,
    (array_agg((c.fecha_stac - s.fecha_inicio_e12b)
        ORDER BY c.ndvi DESC NULLS LAST, c.fecha_stac)
        FILTER (WHERE c.ndvi IS NOT NULL AND c.fecha_stac >= s.fecha_inicio_e12b))[1] AS edad_at_peak
FROM cand_obs c
JOIN e12b_starts s USING (cod_cg_zafra)
GROUP BY s.cod_cg_zafra;

-- Block A: side-by-side mean shape, all variants.
SELECT 'B   (baseline)'      AS variant, count(*) AS lots, round(avg(window_days)::numeric,1) AS window_d,
       round(avg(ndvi_obs)::numeric,1) AS obs, round(avg(ndvi_first_60d)::numeric,3) AS first_60d,
       round(avg(ndvi_max)::numeric,3) AS peak, round(avg(ndvi_last_30d)::numeric,3) AS last_30d,
       round(avg(ndvi_amp)::numeric,3) AS amp,
       round(avg(edad_at_peak::numeric / NULLIF(window_days,0)),3) AS rel_peak,
       round(avg(tch)::numeric,1) AS tch FROM shape_B
UNION ALL
SELECT 'E1  (clip prev+21d)', count(*), round(avg(window_days)::numeric,1),
       round(avg(ndvi_obs)::numeric,1), round(avg(ndvi_first_60d)::numeric,3),
       round(avg(ndvi_max)::numeric,3), round(avg(ndvi_last_30d)::numeric,3),
       round(avg(ndvi_amp)::numeric,3),
       round(avg(edad_at_peak::numeric / NULLIF(window_days,0)),3),
       round(avg(tch)::numeric,1) FROM shape_E1
UNION ALL
SELECT 'E2b (min-NDVI 1st half)', count(*), round(avg(window_days)::numeric,1),
       round(avg(ndvi_obs)::numeric,1), round(avg(ndvi_first_60d)::numeric,3),
       round(avg(ndvi_max)::numeric,3), round(avg(ndvi_last_30d)::numeric,3),
       round(avg(ndvi_amp)::numeric,3),
       round(avg(edad_at_peak::numeric / NULLIF(window_days,0)),3),
       round(avg(tch)::numeric,1) FROM shape_E2b
UNION ALL
SELECT 'E12b (E1 + E2b)', count(*), round(avg(window_days)::numeric,1),
       round(avg(ndvi_obs)::numeric,1), round(avg(ndvi_first_60d)::numeric,3),
       round(avg(ndvi_max)::numeric,3), round(avg(ndvi_last_30d)::numeric,3),
       round(avg(ndvi_amp)::numeric,3),
       round(avg(edad_at_peak::numeric / NULLIF(window_days,0)),3),
       round(avg(tch)::numeric,1) FROM shape_E12b
ORDER BY 1;

-- Block B: validity counts under E3 shape gate.
WITH all_v AS (
    SELECT 'B' AS v, * FROM shape_B UNION ALL
    SELECT 'E1', * FROM shape_E1 UNION ALL
    SELECT 'E2b', * FROM shape_E2b UNION ALL
    SELECT 'E12b', * FROM shape_E12b
)
SELECT
    v AS variant,
    count(*) AS lots_total,
    sum(CASE WHEN ndvi_obs >= 7 AND max_edad >= 150
                  AND ndvi_amp >= 0.35
                  AND edad_at_peak BETWEEN 45 AND 360 THEN 1 ELSE 0 END) AS v2_valid,
    sum(CASE WHEN ndvi_obs >= 7
                  AND ndvi_first_60d < 0.35
                  AND ndvi_max > 0.60
                  AND ndvi_amp > 0.40
                  AND (edad_at_peak::numeric / NULLIF(window_days,0)) BETWEEN 0.25 AND 0.95
                  THEN 1 ELSE 0 END) AS e3_valid
FROM all_v
GROUP BY v
ORDER BY v;

-- Block C: mean shape of surviving E3-valid lots, per variant.
WITH all_v AS (
    SELECT 'B' AS v, * FROM shape_B UNION ALL
    SELECT 'E1', * FROM shape_E1 UNION ALL
    SELECT 'E2b', * FROM shape_E2b UNION ALL
    SELECT 'E12b', * FROM shape_E12b
)
SELECT v AS variant,
       count(*) AS lots,
       round(avg(window_days)::numeric,1) AS window_d,
       round(avg(ndvi_first_60d)::numeric,3) AS first_60d,
       round(avg(ndvi_max)::numeric,3) AS peak,
       round(avg(ndvi_last_30d)::numeric,3) AS last_30d,
       round(avg(ndvi_amp)::numeric,3) AS amp,
       round(avg(tch)::numeric,1) AS tch
FROM all_v
WHERE ndvi_obs >= 7
  AND ndvi_first_60d < 0.35
  AND ndvi_max > 0.60
  AND ndvi_amp > 0.40
  AND (edad_at_peak::numeric / NULLIF(window_days,0)) BETWEEN 0.25 AND 0.95
GROUP BY v
ORDER BY v;
