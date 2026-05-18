-- v3_template_sanity.sql
--
-- Sanity-check the v3 template's phenology gate by running it as a CTE-only
-- query against productividad + stac_indices and tallying the validity flags.
-- This mirrors the WITH chain in queries/template/v3/tch_raw_longitudinal_v3.sql
-- (without the SAR / clima / ENSO joins, which don't affect ciclo_valido).

WITH base AS (
    SELECT
        p.lote AS cod_cg,
        s.fecha::date AS fecha_stac,
        p.cod_cg_zafra,
        NULLIF(s.ndvi_promedio::text, 'NaN')::double precision AS ndvi_promedio,
        p.tch,
        p.edad AS prod_edad,
        to_date(p.cierre, 'DD/MM/YYYY'::text) AS cierre_date
    FROM productividad p
    JOIN stac_indices s
      ON s.lote = p.lote
     AND s.fecha::date >= (to_date(p.cierre, 'DD/MM/YYYY'::text)
            - make_interval(days => greatest(0, round((p.edad::double precision * 30.44))::integer)))::date
     AND s.fecha::date <= to_date(p.cierre, 'DD/MM/YYYY'::text)
    WHERE p.tch IS NOT NULL
      AND NOT (p.tch < 20 OR p.tch > 150)
      AND p.cierre IS NOT NULL
      AND p.edad IS NOT NULL
),
windowed AS (
    SELECT
        b.*,
        b.cierre_date AS fecha_fin_objetivo,
        (b.cierre_date
          - make_interval(days => greatest(0, round((b.prod_edad::double precision * 30.44))::integer)))::date AS fecha_inicio_estimada
    FROM base b
),
with_age AS (
    SELECT
        w.*,
        (w.fecha_stac - w.fecha_inicio_estimada) AS edad_de_cultivo
    FROM windowed w
    WHERE w.fecha_stac BETWEEN w.fecha_inicio_estimada AND w.fecha_fin_objetivo
),
cycle_stats AS (
    SELECT
        cod_cg_zafra,
        count(*) AS cycle_obs_count,
        count(ndvi_promedio) AS cycle_ndvi_obs_count,
        max(edad_de_cultivo) AS max_edad,
        max(fecha_fin_objetivo - fecha_inicio_estimada) AS window_days,
        min(ndvi_promedio) AS ndvi_min,
        max(ndvi_promedio) AS ndvi_max,
        avg(ndvi_promedio) FILTER (
            WHERE edad_de_cultivo IS NOT NULL AND edad_de_cultivo <= 60
        ) AS ndvi_first_60d,
        avg(ndvi_promedio) FILTER (
            WHERE edad_de_cultivo IS NOT NULL
              AND edad_de_cultivo >= (fecha_fin_objetivo - fecha_inicio_estimada) - 30
        ) AS ndvi_last_30d,
        (array_agg(edad_de_cultivo ORDER BY ndvi_promedio DESC NULLS LAST, fecha_stac)
            FILTER (WHERE ndvi_promedio IS NOT NULL))[1] AS edad_en_pico_ndvi,
        max(tch) AS tch
    FROM with_age
    GROUP BY cod_cg_zafra
)
SELECT
    count(*) AS lots_total,
    sum(CASE WHEN cycle_obs_count >= 7 AND max_edad >= 150 THEN 1 ELSE 0 END) AS basico_valid,
    sum(CASE
        WHEN cycle_ndvi_obs_count >= 7
         AND ndvi_first_60d < 0.35
         AND ndvi_max > 0.60
         AND (ndvi_max - ndvi_min) > 0.40
         AND window_days > 0
         AND (edad_en_pico_ndvi::numeric / window_days) BETWEEN 0.25 AND 0.95
        THEN 1 ELSE 0 END) AS phenology_valid_e3,
    sum(CASE
        WHEN cycle_obs_count >= 7 AND max_edad >= 150
         AND cycle_ndvi_obs_count >= 7
         AND ndvi_first_60d < 0.35
         AND ndvi_max > 0.60
         AND (ndvi_max - ndvi_min) > 0.40
         AND window_days > 0
         AND (edad_en_pico_ndvi::numeric / window_days) BETWEEN 0.25 AND 0.95
        THEN 1 ELSE 0 END) AS ciclo_valido_v3,
    round((avg(ndvi_first_60d) FILTER (
        WHERE cycle_obs_count >= 7 AND max_edad >= 150
         AND cycle_ndvi_obs_count >= 7
         AND ndvi_first_60d < 0.35
         AND ndvi_max > 0.60
         AND (ndvi_max - ndvi_min) > 0.40
         AND window_days > 0
         AND (edad_en_pico_ndvi::numeric / window_days) BETWEEN 0.25 AND 0.95
    ))::numeric, 3) AS avg_first_60d_valid,
    round((avg(ndvi_max) FILTER (
        WHERE cycle_obs_count >= 7 AND max_edad >= 150
         AND cycle_ndvi_obs_count >= 7
         AND ndvi_first_60d < 0.35
         AND ndvi_max > 0.60
         AND (ndvi_max - ndvi_min) > 0.40
         AND window_days > 0
         AND (edad_en_pico_ndvi::numeric / window_days) BETWEEN 0.25 AND 0.95
    ))::numeric, 3) AS avg_peak_valid,
    round((avg(tch) FILTER (
        WHERE cycle_obs_count >= 7 AND max_edad >= 150
         AND cycle_ndvi_obs_count >= 7
         AND ndvi_first_60d < 0.35
         AND ndvi_max > 0.60
         AND (ndvi_max - ndvi_min) > 0.40
         AND window_days > 0
         AND (edad_en_pico_ndvi::numeric / window_days) BETWEEN 0.25 AND 0.95
    ))::numeric, 1) AS avg_tch_valid
FROM cycle_stats;
