-- v2_experiments_focused.sql
--
-- A focused, fair comparison metric: contamination rate.
-- A clean cycle has LOW NDVI at the start. A contaminated cycle (prior-cycle
-- bleed-in) shows HIGH NDVI early. Define:
--
--   first60_max_ndvi = MAX(NDVI) within first 60 days of the variant window.
--   "clean_start" iff first60_max_ndvi <= 0.5
--
-- This is robust to window-length differences across variants (unlike mean
-- first-60d NDVI). Report per variant: # lots clean, mean TCH, mean shape on
-- clean subset.

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

-- Variant starts.
DROP TABLE IF EXISTS pg_temp.starts;
CREATE TEMP TABLE starts AS
WITH e2b_anchor AS (
    SELECT cod_cg_zafra,
           fecha_stac AS min_ndvi_date,
           ndvi AS min_ndvi
    FROM (
        SELECT c.*,
               row_number() OVER (PARTITION BY c.cod_cg_zafra ORDER BY c.ndvi ASC NULLS LAST, c.fecha_stac) AS rk
        FROM cand_obs c
        WHERE c.ndvi IS NOT NULL
          AND c.fecha_stac <= c.fecha_inicio_baseline
                + ((c.cierre_date - c.fecha_inicio_baseline) / 2)
    ) t WHERE rk = 1
)
SELECT
    p.cod_cg_zafra,
    p.cierre_date,
    p.tch,
    p.fecha_inicio_baseline AS start_B,
    GREATEST(
        p.fecha_inicio_baseline,
        COALESCE(p.prev_cierre_date + INTERVAL '21 day', p.fecha_inicio_baseline)::date
    ) AS start_E1,
    CASE
        WHEN a.min_ndvi IS NOT NULL AND a.min_ndvi <= 0.30
            THEN a.min_ndvi_date
        ELSE p.fecha_inicio_baseline
    END AS start_E2b
FROM prod_filt p
LEFT JOIN e2b_anchor a USING (cod_cg_zafra);
CREATE INDEX ON starts (cod_cg_zafra);

-- Per-lot shape metric per variant.
DROP TABLE IF EXISTS pg_temp.shapes;
CREATE TEMP TABLE shapes AS
SELECT
    s.cod_cg_zafra,
    s.tch,
    -- Baseline shape
    (s.cierre_date - s.start_B) AS w_B,
    (SELECT max(ndvi) FROM cand_obs c WHERE c.cod_cg_zafra = s.cod_cg_zafra
        AND c.fecha_stac BETWEEN s.start_B AND s.start_B + INTERVAL '60 day') AS first60_max_B,
    (SELECT max(ndvi) FROM cand_obs c WHERE c.cod_cg_zafra = s.cod_cg_zafra
        AND c.fecha_stac >= s.start_B) AS peak_B,
    (SELECT max(ndvi) - min(ndvi) FROM cand_obs c WHERE c.cod_cg_zafra = s.cod_cg_zafra
        AND c.fecha_stac >= s.start_B) AS amp_B,
    -- E1 shape
    (s.cierre_date - s.start_E1) AS w_E1,
    (SELECT max(ndvi) FROM cand_obs c WHERE c.cod_cg_zafra = s.cod_cg_zafra
        AND c.fecha_stac BETWEEN s.start_E1 AND s.start_E1 + INTERVAL '60 day') AS first60_max_E1,
    (SELECT max(ndvi) FROM cand_obs c WHERE c.cod_cg_zafra = s.cod_cg_zafra
        AND c.fecha_stac >= s.start_E1) AS peak_E1,
    (SELECT max(ndvi) - min(ndvi) FROM cand_obs c WHERE c.cod_cg_zafra = s.cod_cg_zafra
        AND c.fecha_stac >= s.start_E1) AS amp_E1,
    -- E2b shape
    (s.cierre_date - s.start_E2b) AS w_E2b,
    (SELECT max(ndvi) FROM cand_obs c WHERE c.cod_cg_zafra = s.cod_cg_zafra
        AND c.fecha_stac BETWEEN s.start_E2b AND s.start_E2b + INTERVAL '60 day') AS first60_max_E2b,
    (SELECT max(ndvi) FROM cand_obs c WHERE c.cod_cg_zafra = s.cod_cg_zafra
        AND c.fecha_stac >= s.start_E2b) AS peak_E2b,
    (SELECT max(ndvi) - min(ndvi) FROM cand_obs c WHERE c.cod_cg_zafra = s.cod_cg_zafra
        AND c.fecha_stac >= s.start_E2b) AS amp_E2b
FROM starts s;

-- Block: contamination rates per variant.
SELECT 'B  baseline' AS variant,
       count(*) AS lots,
       sum(CASE WHEN first60_max_B <= 0.5 THEN 1 ELSE 0 END) AS clean_start_lots,
       round(100.0 * sum(CASE WHEN first60_max_B <= 0.5 THEN 1 ELSE 0 END) / count(*), 1) AS pct_clean,
       round(avg(w_B)::numeric,1) AS avg_window_d,
       round(avg(first60_max_B)::numeric,3) AS avg_first60_max,
       round(avg(peak_B)::numeric,3) AS avg_peak,
       round(avg(amp_B)::numeric,3) AS avg_amp,
       round(avg(tch)::numeric,1) AS avg_tch
FROM shapes
UNION ALL
SELECT 'E1 clip+21d',
       count(*),
       sum(CASE WHEN first60_max_E1 <= 0.5 THEN 1 ELSE 0 END),
       round(100.0 * sum(CASE WHEN first60_max_E1 <= 0.5 THEN 1 ELSE 0 END) / count(*), 1),
       round(avg(w_E1)::numeric,1),
       round(avg(first60_max_E1)::numeric,3),
       round(avg(peak_E1)::numeric,3),
       round(avg(amp_E1)::numeric,3),
       round(avg(tch)::numeric,1)
FROM shapes
UNION ALL
SELECT 'E2b min-NDVI 1st-half',
       count(*),
       sum(CASE WHEN first60_max_E2b <= 0.5 THEN 1 ELSE 0 END),
       round(100.0 * sum(CASE WHEN first60_max_E2b <= 0.5 THEN 1 ELSE 0 END) / count(*), 1),
       round(avg(w_E2b)::numeric,1),
       round(avg(first60_max_E2b)::numeric,3),
       round(avg(peak_E2b)::numeric,3),
       round(avg(amp_E2b)::numeric,3),
       round(avg(tch)::numeric,1)
FROM shapes
ORDER BY 1;

-- Stratify: for lots flagged as contaminated under B, how does each variant rescue them?
SELECT
    'lots contaminated under B (first60_max>0.5)' AS subset,
    count(*) AS lots,
    sum(CASE WHEN first60_max_E1 <= 0.5 THEN 1 ELSE 0 END) AS rescued_by_E1,
    sum(CASE WHEN first60_max_E2b <= 0.5 THEN 1 ELSE 0 END) AS rescued_by_E2b,
    round(avg(first60_max_B)::numeric,3) AS avg_B_first60_max,
    round(avg(first60_max_E1)::numeric,3) AS avg_E1_first60_max,
    round(avg(first60_max_E2b)::numeric,3) AS avg_E2b_first60_max
FROM shapes
WHERE first60_max_B > 0.5;
