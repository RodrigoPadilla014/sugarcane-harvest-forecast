-- ENSO block for v5 as-of-180.
-- Uses monthly ENSO context from 180 days before cycle start through cutoff.

WITH base_cycles AS (
    SELECT *
    FROM (
        SELECT
            r.cod_cg_zafra,
            min(r.fecha_inicio_estimada)::date AS fecha_inicio_ciclo,
            max(r.edad_de_cultivo)::double precision AS cycle_age_max
        FROM public.tch_raw_longitudinal_v4 r
        WHERE r.tch IS NOT NULL
          AND r.tch BETWEEN 20 AND 150
          AND r.ciclo_valido = true
          AND r.cod_cg_zafra IS NOT NULL
          AND r.zafra_norm <> '2019_2020'
        GROUP BY r.cod_cg_zafra
    ) b
    WHERE cycle_age_max >= 180
),
enso_seq AS (
    SELECT
        b.cod_cg_zafra,
        e.date::date AS enso_month,
        CASE
            WHEN e.date::date < b.fecha_inicio_ciclo THEN 'precycle_180d'
            ELSE 'asof_0_180d'
        END AS enso_window,
        NULLIF(e.oni::text, 'NaN')::double precision AS oni,
        NULLIF(e.nino34::text, 'NaN')::double precision AS nino34,
        NULLIF(e.soi::text, 'NaN')::double precision AS soi
    FROM base_cycles b
    LEFT JOIN public.enso e
      ON e.date::date >= b.fecha_inicio_ciclo - INTERVAL '180 days'
     AND e.date::date <= (b.fecha_inicio_ciclo + INTERVAL '180 days')::date
)
SELECT
    cod_cg_zafra,
    count(enso_month)::double precision AS enso_month_count_asof,
    avg(oni) FILTER (WHERE enso_window = 'precycle_180d') AS enso_oni_precycle_mean,
    avg(oni) FILTER (WHERE enso_window = 'asof_0_180d') AS enso_oni_asof_mean,
    max(abs(oni)) AS enso_oni_abs_max_asof,
    avg(nino34) FILTER (WHERE enso_window = 'precycle_180d') AS enso_nino34_precycle_mean,
    avg(nino34) FILTER (WHERE enso_window = 'asof_0_180d') AS enso_nino34_asof_mean,
    avg(soi) FILTER (WHERE enso_window = 'precycle_180d') AS enso_soi_precycle_mean,
    avg(soi) FILTER (WHERE enso_window = 'asof_0_180d') AS enso_soi_asof_mean,
    avg((oni > 0.5)::int) AS enso_el_nino_fraction_asof,
    avg((oni < -0.5)::int) AS enso_la_nina_fraction_asof
FROM enso_seq
GROUP BY cod_cg_zafra;
