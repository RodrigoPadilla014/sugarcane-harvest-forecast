-- dataset_quality.sql
--
-- Five diagnostic checks on tch_raw_longitudinal_v4 (ciclo_valido = true).
--
-- 1. Zafra (year) coverage
-- 2. No_corte (cut number) distribution
-- 3. TCH distribution
-- 4. STAC gap distribution (max consecutive gap in days per cycle)
-- 5. Observation density by growth phase

-- -----------------------------------------------------------------------
-- Block 1: zafras covered and lot count per year
-- -----------------------------------------------------------------------
SELECT
    zafra_norm,
    count(DISTINCT cod_cg_zafra)          AS lot_zafras,
    round(avg(tch)::numeric, 1)           AS avg_tch,
    round(stddev(tch)::numeric, 1)        AS std_tch,
    min(cierre_ciclo)                     AS first_cierre,
    max(cierre_ciclo)                     AS last_cierre
FROM public.tch_raw_longitudinal_v4
WHERE ciclo_valido
GROUP BY zafra_norm
ORDER BY zafra_norm;

-- -----------------------------------------------------------------------
-- Block 2: no_corte distribution
-- -----------------------------------------------------------------------
SELECT
    prod_no_corte,
    count(DISTINCT cod_cg_zafra)   AS lot_zafras,
    round(avg(tch)::numeric, 1)    AS avg_tch,
    round(stddev(tch)::numeric, 1) AS std_tch
FROM public.tch_raw_longitudinal_v4
WHERE ciclo_valido
GROUP BY prod_no_corte
ORDER BY prod_no_corte;

-- -----------------------------------------------------------------------
-- Block 3: TCH distribution
-- -----------------------------------------------------------------------
SELECT
    CASE
        WHEN tch < 40  THEN '20-40'
        WHEN tch < 60  THEN '40-60'
        WHEN tch < 80  THEN '60-80'
        WHEN tch < 100 THEN '80-100'
        WHEN tch < 120 THEN '100-120'
        WHEN tch < 140 THEN '120-140'
        ELSE                '140-150'
    END AS tch_bucket,
    count(DISTINCT cod_cg_zafra) AS lot_zafras,
    round(avg(tch)::numeric, 1)  AS avg_tch
FROM public.tch_raw_longitudinal_v4
WHERE ciclo_valido
GROUP BY 1
ORDER BY 1;

-- -----------------------------------------------------------------------
-- Block 4: STAC gap distribution (max days between consecutive obs per cycle)
-- -----------------------------------------------------------------------
WITH gaps AS (
    SELECT
        cod_cg_zafra,
        fecha_stac,
        lead(fecha_stac) OVER (PARTITION BY cod_cg_zafra ORDER BY fecha_stac) AS next_stac
    FROM public.tch_raw_longitudinal_v4
    WHERE ciclo_valido
),
max_gap AS (
    SELECT
        cod_cg_zafra,
        max(next_stac - fecha_stac) AS max_gap_days
    FROM gaps
    WHERE next_stac IS NOT NULL
    GROUP BY cod_cg_zafra
)
SELECT
    CASE
        WHEN max_gap_days <= 10  THEN '<=10d'
        WHEN max_gap_days <= 20  THEN '11-20d'
        WHEN max_gap_days <= 30  THEN '21-30d'
        WHEN max_gap_days <= 45  THEN '31-45d'
        WHEN max_gap_days <= 60  THEN '46-60d'
        WHEN max_gap_days <= 90  THEN '61-90d'
        ELSE                          '>90d'
    END AS max_gap_bucket,
    count(*) AS lot_zafras,
    round(avg(max_gap_days)::numeric, 1) AS avg_max_gap
FROM max_gap
GROUP BY 1
ORDER BY avg_max_gap;

-- -----------------------------------------------------------------------
-- Block 5: obs density by growth phase (across all valid cycles)
-- uses edad_de_cultivo relative to window length (rel_age = 0..1)
-- -----------------------------------------------------------------------
SELECT
    CASE
        WHEN rel_age < 0.10 THEN '0-10%'
        WHEN rel_age < 0.20 THEN '10-20%'
        WHEN rel_age < 0.30 THEN '20-30%'
        WHEN rel_age < 0.40 THEN '30-40%'
        WHEN rel_age < 0.50 THEN '40-50%'
        WHEN rel_age < 0.60 THEN '50-60%'
        WHEN rel_age < 0.70 THEN '60-70%'
        WHEN rel_age < 0.80 THEN '70-80%'
        WHEN rel_age < 0.90 THEN '80-90%'
        ELSE                     '90-100%'
    END AS growth_phase,
    count(*)                                    AS obs,
    round(avg(stac_ndvi_promedio)::numeric, 3)  AS avg_ndvi,
    count(DISTINCT cod_cg_zafra)                AS lot_zafras_with_obs
FROM (
    SELECT
        cod_cg_zafra,
        stac_ndvi_promedio,
        CASE
            WHEN cierre_ciclo - fecha_inicio_estimada = 0 THEN NULL
            ELSE edad_de_cultivo::numeric / (cierre_ciclo - fecha_inicio_estimada)
        END AS rel_age
    FROM public.tch_raw_longitudinal_v4
    WHERE ciclo_valido
      AND edad_de_cultivo IS NOT NULL
) t
WHERE rel_age IS NOT NULL
GROUP BY 1
ORDER BY 1;
