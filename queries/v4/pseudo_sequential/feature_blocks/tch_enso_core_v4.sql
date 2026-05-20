-- tch_enso_core_v4.sql
--
-- ENSO core feature block for the pseudo-sequential/tabular TCH strategy.
--
-- Shape:
--   one row per valid cod_cg_zafra
--
-- Intent:
--   Add compact background climate-regime context without expanding monthly
--   ENSO observations into a high-dimensional sequence.
--
-- Source rules:
--   - public.tch_raw_longitudinal_v4 supplies validated cycle bounds, target,
--     and model metadata.
--   - public.enso supplies direct monthly ENSO/regime observations.
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
        max(r.edad_de_cultivo)::double precision AS cycle_age_max
    FROM public.tch_raw_longitudinal_v4 r
    WHERE r.tch IS NOT NULL
      AND r.tch BETWEEN 20 AND 150
      AND r.ciclo_valido = true
      AND r.cod_cg_zafra IS NOT NULL
    GROUP BY r.cod_cg_zafra
),
enso_seq AS (
    SELECT
        b.cod_cg_zafra,
        b.zafra_norm,
        e.date::date AS enso_month,
        (e.date::date - b.fecha_inicio_ciclo)::double precision AS age_days,
        CASE
            WHEN e.date::date < b.fecha_inicio_ciclo THEN 'precycle_180d'
            WHEN e.date::date BETWEEN b.fecha_inicio_ciclo
                 AND b.fecha_inicio_ciclo + INTERVAL '120 days' THEN 'early'
            WHEN e.date::date > b.fecha_inicio_ciclo + INTERVAL '120 days'
                 AND e.date::date <= b.fecha_inicio_ciclo + INTERVAL '240 days' THEN 'mid'
            WHEN e.date::date > b.fecha_inicio_ciclo + INTERVAL '240 days'
                 AND e.date::date <= b.fecha_fin_ciclo THEN 'late'
            ELSE 'outside'
        END AS enso_window,
        NULLIF(e.oni::text, 'NaN')::double precision AS oni,
        NULLIF(e.nino34::text, 'NaN')::double precision AS nino34,
        NULLIF(e.soi::text, 'NaN')::double precision AS soi
    FROM base_cycles b
    JOIN public.enso e
      ON e.date::date >= b.fecha_inicio_ciclo - INTERVAL '180 days'
     AND e.date::date <= b.fecha_fin_ciclo
),
enso_features AS (
    SELECT
        cod_cg_zafra,
        count(*)::double precision AS enso_month_count,

        avg(oni) FILTER (WHERE enso_window = 'precycle_180d') AS enso_oni_precycle_mean,
        avg(oni) FILTER (WHERE enso_window = 'early') AS enso_oni_early_mean,
        avg(oni) FILTER (WHERE enso_window = 'mid') AS enso_oni_mid_mean,
        avg(oni) FILTER (WHERE enso_window = 'late') AS enso_oni_late_mean,
        max(abs(oni)) FILTER (WHERE enso_window IN ('precycle_180d', 'early')) AS enso_oni_abs_max_precycle_early,

        avg(nino34) FILTER (WHERE enso_window = 'precycle_180d') AS enso_nino34_precycle_mean,
        avg(nino34) FILTER (WHERE enso_window = 'early') AS enso_nino34_early_mean,
        max(abs(nino34)) FILTER (WHERE enso_window IN ('precycle_180d', 'early')) AS enso_nino34_abs_max_precycle_early,

        avg(soi) FILTER (WHERE enso_window = 'precycle_180d') AS enso_soi_precycle_mean,
        avg(soi) FILTER (WHERE enso_window = 'early') AS enso_soi_early_mean,
        avg(soi) FILTER (WHERE enso_window = 'mid') AS enso_soi_mid_mean,
        avg(soi) FILTER (WHERE enso_window = 'late') AS enso_soi_late_mean,

        avg((soi > 0)::int) FILTER (WHERE enso_window = 'precycle_180d')::double precision AS enso_soi_positive_fraction_precycle,
        avg((oni > 0.5)::int) FILTER (WHERE enso_window = 'precycle_180d')::double precision AS enso_el_nino_fraction_precycle,
        avg((oni < -0.5)::int) FILTER (WHERE enso_window = 'precycle_180d')::double precision AS enso_la_nina_fraction_precycle
    FROM enso_seq
    GROUP BY cod_cg_zafra
)
SELECT
    b.cod_cg_zafra,
    b.cod_cg,
    b.zafra_norm,
    b.area,
    b.tch,
    b.tc,
    b.fecha_inicio_ciclo,
    b.fecha_fin_ciclo,
    b.cycle_age_max,

    e.enso_month_count,
    e.enso_oni_precycle_mean,
    e.enso_oni_early_mean,
    e.enso_oni_mid_mean,
    e.enso_oni_late_mean,
    e.enso_oni_abs_max_precycle_early,
    e.enso_nino34_precycle_mean,
    e.enso_nino34_early_mean,
    e.enso_nino34_abs_max_precycle_early,
    e.enso_soi_precycle_mean,
    e.enso_soi_early_mean,
    e.enso_soi_mid_mean,
    e.enso_soi_late_mean,
    e.enso_soi_positive_fraction_precycle,
    e.enso_el_nino_fraction_precycle,
    e.enso_la_nina_fraction_precycle
FROM base_cycles b
LEFT JOIN enso_features e USING (cod_cg_zafra);
