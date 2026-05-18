-- v2_phenology_gate_vs_shape.sql
--
-- Compare the v2 template's ciclo_valido gate
--   ciclo_valido = (cycle_obs_count >= 7 AND max_edad >= 150)
--                  AND (cycle_obs_count >= 7
--                       AND ndvi_amp >= 0.35
--                       AND edad_en_pico_ndvi BETWEEN 45 AND 360)
-- against a shape-based "looks sinusoidal" check:
--   low_start    = ndvi_first_60d < 0.35
--   high_peak    = ndvi_peak > 0.6
--   non_flat     = ndvi_amp > 0.4
--   reasonable_peak_pos = rel_peak_pos BETWEEN 0.25 AND 0.95
--
-- Goal: quantify rows the v2 gate keeps that shape-check would drop, and
--       vice-versa, and what their TCH looks like.

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
    p.tch,
    p.cierre_date,
    p.fecha_inicio_estimada,
    (s.fecha::date - p.fecha_inicio_estimada) AS edad_dias,
    NULLIF(s.ndvi_promedio::text, 'NaN')::double precision AS ndvi
FROM p
JOIN stac_indices s
  ON s.lote = p.cod_cg
 AND s.fecha::date BETWEEN p.fecha_inicio_estimada AND p.cierre_date;

DROP TABLE IF EXISTS pg_temp.v2_gate;

CREATE TEMP TABLE v2_gate AS
SELECT
    cod_cg_zafra,
    max(tch) AS tch,
    max(cierre_date - fecha_inicio_estimada) AS window_days,
    count(ndvi) AS ndvi_obs,
    max(edad_dias) AS max_edad,
    min(ndvi) AS ndvi_min,
    max(ndvi) AS ndvi_max,
    max(ndvi) - min(ndvi) AS ndvi_amp,
    avg(ndvi) FILTER (WHERE edad_dias <= 60) AS ndvi_first_60d,
    (array_agg(edad_dias ORDER BY ndvi DESC NULLS LAST)
        FILTER (WHERE ndvi IS NOT NULL))[1] AS edad_at_peak
FROM v2_obs
GROUP BY cod_cg_zafra;

-- Block: 2x2 confusion between v2 gate and shape gate.
SELECT
    CASE
        WHEN ndvi_obs >= 7
         AND max_edad >= 150
         AND ndvi_amp >= 0.35
         AND edad_at_peak BETWEEN 45 AND 360
        THEN 'v2_valid'
        ELSE 'v2_invalid'
    END AS v2_gate,
    CASE
        WHEN ndvi_first_60d < 0.35
         AND ndvi_max > 0.6
         AND ndvi_amp > 0.4
         AND edad_at_peak::numeric / NULLIF(window_days, 0) BETWEEN 0.25 AND 0.95
        THEN 'shape_valid'
        ELSE 'shape_invalid'
    END AS shape_gate,
    count(*) AS lot_zafras,
    round(avg(tch)::numeric, 1) AS avg_tch,
    round(avg(ndvi_amp)::numeric, 3) AS avg_amp,
    round(avg(ndvi_first_60d)::numeric, 3) AS avg_first_60d,
    round(avg(edad_at_peak)::numeric, 1) AS avg_peak_age_days
FROM v2_gate
GROUP BY 1, 2
ORDER BY 1, 2;
