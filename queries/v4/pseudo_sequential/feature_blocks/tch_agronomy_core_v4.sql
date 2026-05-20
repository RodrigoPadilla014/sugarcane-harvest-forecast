-- tch_agronomy_core_v4.sql
--
-- Agronomy/static context core feature block for the pseudo-sequential/tabular
-- TCH strategy.
--
-- Shape:
--   one row per valid cod_cg_zafra
--
-- Intent:
--   Keep only stable, defensibly pre-known lot/crop descriptors. Categorical
--   encoding is handled downstream by the SageMaker pipeline.
--
-- Source rules:
--   - public.tch_raw_longitudinal_v4 supplies validated cycle bounds, target,
--     model metadata, and cleaned productividad categorical fields.
--   - Do not include excluded/leaky productividad fields here or in ablation:
--     yield/lab outcomes, harvest operations/timing, fertilizer, irrigation,
--     weed/pest/maturation controls, or raw productividad climate fields.
--
-- Usage:
--   This is a reusable feature block, not the final training table. Join later
--   to other source blocks by cod_cg_zafra.

WITH base_cycles AS (
    SELECT
        r.cod_cg_zafra,
        max(r.cod_cg) AS cod_cg,
        max(r.zafra_norm) AS zafra_norm,
        max(r.area)::double precision AS area,
        max(r.tch)::double precision AS tch,
        max(r.tc)::double precision AS tc,
        min(r.fecha_inicio_estimada)::date AS fecha_inicio_ciclo,
        max(r.fecha_fin_objetivo)::date AS fecha_fin_ciclo,
        max(r.edad_de_cultivo)::double precision AS cycle_age_max,

        max(r.prod_ingenio) AS prod_ingenio,
        max(r.prod_grupo_de_suelo) AS prod_grupo_de_suelo,
        max(r.prod_grupo_de_humedad) AS prod_grupo_de_humedad,
        max(r.prod_codigo_zae) AS prod_codigo_zae,
        max(r.prod_familia_de_suelo) AS prod_familia_de_suelo,
        max(r.prod_variedad) AS prod_variedad,
        max(r.prod_no_corte) AS prod_no_corte,
        max(r.prod_cosecha) AS prod_cosecha
    FROM public.tch_raw_longitudinal_v4 r
    WHERE r.tch IS NOT NULL
      AND r.tch BETWEEN 20 AND 150
      AND r.ciclo_valido = true
      AND r.cod_cg_zafra IS NOT NULL
    GROUP BY r.cod_cg_zafra
)
SELECT
    cod_cg_zafra,
    cod_cg,
    zafra_norm,
    area,
    tch,
    tc,
    fecha_inicio_ciclo,
    fecha_fin_ciclo,
    cycle_age_max,

    prod_ingenio,
    prod_grupo_de_suelo,
    prod_grupo_de_humedad,
    prod_codigo_zae,
    prod_familia_de_suelo,
    prod_variedad,
    prod_no_corte,
    prod_cosecha
FROM base_cycles;
