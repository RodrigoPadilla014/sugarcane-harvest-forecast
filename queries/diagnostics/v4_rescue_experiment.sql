-- v4_rescue_experiment.sql
--
-- Measure how many contaminated cycles v4 can rescue.
--
-- Strategy:
--   - For lots with a previous cierre on the same lote: clip the window start
--     to MAX(baseline_start, prev_cierre + 21d)  --> E1 applied.
--     Gate: obs>=7, ndvi_max>0.60, ndvi_amp>0.40, rel_peak BETWEEN 0.25 AND 0.95
--     (skip ndvi_first_60d check -- contamination physically removed by clip)
--
--   - For lots WITHOUT a previous cierre: keep baseline window.
--     Gate: same as v3 E3 (including ndvi_first_60d < 0.35).
--     Mark start_contaminado = true when ndvi_first_60d >= 0.35.

DROP TABLE IF EXISTS pg_temp.prod_v4;
CREATE TEMP TABLE prod_v4 AS
WITH base_prod AS (
    SELECT
        lote AS cod_cg,
        cod_cg_zafra,
        tch,
        edad::numeric AS prod_edad,
        to_date(cierre, 'DD/MM/YYYY') AS cierre_date,
        (to_date(cierre, 'DD/MM/YYYY')
          - make_interval(days => greatest(0, round((edad::double precision * 30.44))::integer)))::date AS fecha_inicio_baseline,
        lag(to_date(cierre, 'DD/MM/YYYY'))
            OVER (PARTITION BY lote ORDER BY to_date(cierre, 'DD/MM/YYYY'))
            AS prev_cierre_date
    FROM productividad
    WHERE tch IS NOT NULL
      AND NOT (tch < 20 OR tch > 150)
      AND cierre IS NOT NULL
      AND edad IS NOT NULL
)
SELECT
    *,
    GREATEST(
        fecha_inicio_baseline,
        COALESCE((prev_cierre_date + INTERVAL '21 day')::date, fecha_inicio_baseline)
    ) AS fecha_inicio_v4,
    (prev_cierre_date IS NOT NULL
     AND (prev_cierre_date + INTERVAL '21 day')::date > fecha_inicio_baseline) AS e1_applied
FROM base_prod;
CREATE INDEX ON prod_v4 (cod_cg_zafra);
CREATE INDEX ON prod_v4 (cod_cg);

DROP TABLE IF EXISTS pg_temp.obs_v4;
CREATE TEMP TABLE obs_v4 AS
SELECT
    p.cod_cg_zafra,
    p.tch,
    p.cierre_date,
    p.fecha_inicio_v4,
    p.fecha_inicio_baseline,
    p.e1_applied,
    s.fecha::date AS fecha_stac,
    (s.fecha::date - p.fecha_inicio_v4) AS edad_dias,
    NULLIF(s.ndvi_promedio::text, 'NaN')::double precision AS ndvi
FROM prod_v4 p
JOIN stac_indices s
  ON s.lote = p.cod_cg
 AND s.fecha::date BETWEEN p.fecha_inicio_v4 AND p.cierre_date;
CREATE INDEX ON obs_v4 (cod_cg_zafra);

DROP TABLE IF EXISTS pg_temp.shape_v4;
CREATE TEMP TABLE shape_v4 AS
SELECT
    cod_cg_zafra,
    max(tch) AS tch,
    bool_or(e1_applied) AS e1_applied,
    max(cierre_date - fecha_inicio_v4) AS window_days,
    count(ndvi) AS ndvi_obs,
    min(ndvi) AS ndvi_min,
    max(ndvi) AS ndvi_max,
    max(ndvi) - min(ndvi) AS ndvi_amp,
    avg(ndvi) FILTER (WHERE edad_dias <= 60) AS ndvi_first_60d,
    avg(ndvi) FILTER (
        WHERE edad_dias >= (cierre_date - fecha_inicio_v4) - 30
    ) AS ndvi_last_30d,
    (array_agg(edad_dias ORDER BY ndvi DESC NULLS LAST, fecha_stac)
        FILTER (WHERE ndvi IS NOT NULL))[1] AS edad_at_peak
FROM obs_v4
GROUP BY cod_cg_zafra;

-- Block 1: v3 gate vs v4 gate -- how many rescued?
WITH classified AS (
    SELECT
        cod_cg_zafra, tch, e1_applied, window_days,
        ndvi_obs, ndvi_min, ndvi_max, ndvi_amp,
        ndvi_first_60d, ndvi_last_30d, edad_at_peak,
        CASE WHEN window_days > 0 THEN edad_at_peak::numeric / window_days ELSE NULL END AS rel_peak,
        -- v3 gate (E3, full shape check)
        (ndvi_obs >= 7
         AND ndvi_first_60d < 0.35
         AND ndvi_max > 0.60
         AND ndvi_amp > 0.40
         AND window_days > 0
         AND (edad_at_peak::numeric / window_days) BETWEEN 0.25 AND 0.95
        ) AS v3_valid,
        -- v4 gate (E1 + adaptive)
        (ndvi_obs >= 7
         AND ndvi_max > 0.60
         AND ndvi_amp > 0.40
         AND window_days > 0
         AND (edad_at_peak::numeric / window_days) BETWEEN 0.25 AND 0.95
         AND (e1_applied OR ndvi_first_60d < 0.35)
        ) AS v4_valid,
        -- contaminated but unfixable (no prev_cierre, high start)
        (NOT e1_applied AND ndvi_first_60d >= 0.35) AS start_contaminado
    FROM shape_v4
)
SELECT
    CASE
        WHEN v3_valid AND v4_valid       THEN 'ambos_validos'
        WHEN NOT v3_valid AND v4_valid   THEN 'rescatado_por_v4'
        WHEN v3_valid AND NOT v4_valid   THEN 'perdido_en_v4'
        ELSE                                  'ambos_invalidos'
    END AS resultado,
    count(*) AS lote_zafras,
    round(avg(tch)::numeric, 1) AS avg_tch,
    round(avg(ndvi_first_60d)::numeric, 3) AS avg_first_60d,
    round(avg(ndvi_max)::numeric, 3) AS avg_peak,
    round(avg(ndvi_amp)::numeric, 3) AS avg_amp,
    round(avg(rel_peak)::numeric, 3) AS avg_rel_peak,
    sum(start_contaminado::int) AS con_start_contaminado
FROM classified
GROUP BY 1
ORDER BY 2 DESC;

-- Block 2: shape of rescued lots specifically.
WITH classified AS (
    SELECT
        tch, e1_applied, window_days,
        ndvi_obs, ndvi_max, ndvi_amp, ndvi_first_60d, ndvi_last_30d,
        CASE WHEN window_days > 0 THEN edad_at_peak::numeric / window_days ELSE NULL END AS rel_peak,
        (ndvi_obs >= 7 AND ndvi_first_60d < 0.35 AND ndvi_max > 0.60 AND ndvi_amp > 0.40
         AND window_days > 0
         AND (edad_at_peak::numeric / window_days) BETWEEN 0.25 AND 0.95) AS v3_valid,
        (ndvi_obs >= 7 AND ndvi_max > 0.60 AND ndvi_amp > 0.40 AND window_days > 0
         AND (edad_at_peak::numeric / window_days) BETWEEN 0.25 AND 0.95
         AND (e1_applied OR ndvi_first_60d < 0.35)) AS v4_valid
    FROM shape_v4
)
SELECT
    round(avg(window_days)::numeric, 1) AS avg_window_d,
    round(avg(ndvi_first_60d)::numeric, 3) AS avg_first_60d,
    round(avg(ndvi_max)::numeric, 3) AS avg_peak,
    round(avg(ndvi_last_30d)::numeric, 3) AS avg_last_30d,
    round(avg(ndvi_amp)::numeric, 3) AS avg_amp,
    round(avg(rel_peak)::numeric, 3) AS avg_rel_peak,
    round(avg(tch)::numeric, 1) AS avg_tch
FROM classified
WHERE NOT v3_valid AND v4_valid;
