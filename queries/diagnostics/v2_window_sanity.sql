-- v2_window_sanity.sql
--
-- Sanity check the v2 cierre-window crop-age logic.
--
-- v2 defines, for each productividad row:
--   fecha_inicio_estimada = cierre_date - prod_edad * 30.44 days
--   fecha_fin_objetivo    = cierre_date
--   STAC obs accepted iff fecha_stac in [fecha_inicio_estimada, cierre_date]
--
-- We do NOT touch productividad / stac_indices. We just describe the
-- distribution of prod_edad, derived window length, expected NDVI obs count,
-- and overlap with previous cycle's cierre on the same lote.

DROP TABLE IF EXISTS pg_temp.v2_windows;

CREATE TEMP TABLE v2_windows AS
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
),
windows AS (
    SELECT
        p.*,
        (cierre_date - fecha_inicio_estimada) AS window_days,
        lag(cierre_date) OVER (PARTITION BY cod_cg ORDER BY cierre_date) AS prev_cierre_date
    FROM p
)
SELECT
    w.*,
    CASE
        WHEN prev_cierre_date IS NULL THEN NULL
        WHEN prev_cierre_date >= fecha_inicio_estimada THEN
            (prev_cierre_date - fecha_inicio_estimada)::int
        ELSE 0
    END AS days_overlapping_prev_cycle,
    CASE
        WHEN prev_cierre_date IS NULL THEN NULL
        ELSE (cierre_date - prev_cierre_date)::int
    END AS days_since_prev_cierre
FROM windows w;

-- Block 1: edad / window distribution.
SELECT
    count(*) AS rows_total,
    round(min(prod_edad_months), 1) AS min_edad,
    round(max(prod_edad_months), 1) AS max_edad,
    round(avg(prod_edad_months), 2) AS avg_edad,
    percentile_cont(0.05) WITHIN GROUP (ORDER BY prod_edad_months) AS p05_edad,
    percentile_cont(0.50) WITHIN GROUP (ORDER BY prod_edad_months) AS p50_edad,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY prod_edad_months) AS p95_edad,
    min(window_days) AS min_window_days,
    max(window_days) AS max_window_days,
    percentile_cont(0.05) WITHIN GROUP (ORDER BY window_days) AS p05_w,
    percentile_cont(0.50) WITHIN GROUP (ORDER BY window_days) AS p50_w,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY window_days) AS p95_w
FROM v2_windows;

-- Block 2: overlap of v2 window with the previous cierre date on the same lote.
SELECT
    CASE
        WHEN prev_cierre_date IS NULL THEN 'no_prev_cierre'
        WHEN days_overlapping_prev_cycle = 0 THEN 'clean_window'
        WHEN days_overlapping_prev_cycle <= 30 THEN 'overlap_<=30d'
        WHEN days_overlapping_prev_cycle <= 90 THEN 'overlap_<=90d'
        WHEN days_overlapping_prev_cycle <= 180 THEN 'overlap_<=180d'
        ELSE 'overlap_>180d'
    END AS bucket,
    count(*) AS lot_zafras,
    round(avg(prod_edad_months), 2) AS avg_edad_months,
    round(avg(window_days), 1) AS avg_window_days,
    round(avg(days_overlapping_prev_cycle), 1) AS avg_overlap_days,
    round(avg(days_since_prev_cierre), 1) AS avg_days_since_prev_cierre
FROM v2_windows
GROUP BY 1
ORDER BY 2 DESC;

-- Block 3: how well does edad*30.44 match the actual prev->current cierre gap?
SELECT
    count(*) AS pairs,
    round(avg(window_days - days_since_prev_cierre), 1) AS avg_window_minus_actual_days,
    percentile_cont(0.05) WITHIN GROUP (ORDER BY (window_days - days_since_prev_cierre)) AS p05_diff,
    percentile_cont(0.50) WITHIN GROUP (ORDER BY (window_days - days_since_prev_cierre)) AS p50_diff,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY (window_days - days_since_prev_cierre)) AS p95_diff
FROM v2_windows
WHERE prev_cierre_date IS NOT NULL;
