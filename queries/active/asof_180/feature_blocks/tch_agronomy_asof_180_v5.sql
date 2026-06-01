-- Agronomy/static context block for v5 as-of-180.
-- One row per valid cod_cg_zafra. Excludes 2019_2020 and cycles shorter than 180 days.

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
    180::integer AS cutoff_age_days,
    (min(r.fecha_inicio_estimada)::date + INTERVAL '180 days')::date AS cutoff_date,

    max(r.prod_ingenio) AS prod_ingenio,
    max(r.prod_grupo_de_suelo) AS prod_grupo_de_suelo,
    max(r.prod_grupo_de_humedad) AS prod_grupo_de_humedad,
    max(r.prod_codigo_zae) AS prod_codigo_zae,
    max(r.prod_familia_de_suelo) AS prod_familia_de_suelo,
    max(r.prod_variedad) AS prod_variedad,
    max(r.prod_no_corte) AS prod_no_corte
FROM public.tch_raw_longitudinal_v4 r
WHERE r.tch IS NOT NULL
  AND r.tch BETWEEN 20 AND 150
  AND r.ciclo_valido = true
  AND r.cod_cg_zafra IS NOT NULL
  AND r.zafra_norm <> '2019_2020'
GROUP BY r.cod_cg_zafra
HAVING max(r.edad_de_cultivo)::double precision >= 180;
