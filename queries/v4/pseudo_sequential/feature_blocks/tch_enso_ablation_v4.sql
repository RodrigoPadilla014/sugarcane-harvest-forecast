-- tch_enso_ablation_v4.sql
--
-- Secondary ENSO/regime feature block for later ablation tests.
--
-- Shape:
--   one row per valid cod_cg_zafra
--
-- Intent:
--   Keep broader or more speculative climate-regime signals separate from the
--   compact ENSO core: RONI, MEI, PDO, AMO, extra Nino-region summaries, and
--   simple interaction/intensity terms.
--
-- Source rules:
--   - public.tch_raw_longitudinal_v4 supplies validated cycle bounds, target,
--     and model metadata.
--   - public.enso supplies direct monthly ENSO/regime observations.
--
-- Usage:
--   Join to the core training table by cod_cg_zafra only when running ablation.

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
        NULLIF(e.nino3::text, 'NaN')::double precision AS nino3,
        NULLIF(e.nino12::text, 'NaN')::double precision AS nino12,
        NULLIF(e.nino4::text, 'NaN')::double precision AS nino4,
        NULLIF(e.soi::text, 'NaN')::double precision AS soi,
        NULLIF(e.roni::text, 'NaN')::double precision AS roni,
        NULLIF(e.mei::text, 'NaN')::double precision AS mei,
        NULLIF(e.pdo::text, 'NaN')::double precision AS pdo,
        NULLIF(e.amo::text, 'NaN')::double precision AS amo
    FROM base_cycles b
    JOIN public.enso e
      ON e.date::date >= b.fecha_inicio_ciclo - INTERVAL '180 days'
     AND e.date::date <= b.fecha_fin_ciclo
),
enso_features AS (
    SELECT
        cod_cg_zafra,

        avg(roni) FILTER (WHERE enso_window = 'precycle_180d') AS enso_abl_roni_precycle_mean,
        avg(roni) FILTER (WHERE enso_window = 'early') AS enso_abl_roni_early_mean,
        avg(roni) FILTER (WHERE enso_window = 'mid') AS enso_abl_roni_mid_mean,
        avg(roni) FILTER (WHERE enso_window = 'late') AS enso_abl_roni_late_mean,
        max(abs(roni)) FILTER (WHERE enso_window IN ('precycle_180d', 'early')) AS enso_abl_roni_abs_max_precycle_early,

        avg(mei) FILTER (WHERE enso_window = 'precycle_180d') AS enso_abl_mei_precycle_mean,
        avg(mei) FILTER (WHERE enso_window = 'early') AS enso_abl_mei_early_mean,
        max(abs(mei)) FILTER (WHERE enso_window IN ('precycle_180d', 'early')) AS enso_abl_mei_abs_max_precycle_early,

        avg(pdo) FILTER (WHERE enso_window = 'precycle_180d') AS enso_abl_pdo_precycle_mean,
        avg(pdo) FILTER (WHERE enso_window = 'early') AS enso_abl_pdo_early_mean,
        avg(amo) FILTER (WHERE enso_window = 'precycle_180d') AS enso_abl_amo_precycle_mean,
        avg(amo) FILTER (WHERE enso_window = 'early') AS enso_abl_amo_early_mean,

        avg(nino3) FILTER (WHERE enso_window = 'precycle_180d') AS enso_abl_nino3_precycle_mean,
        avg(nino3) FILTER (WHERE enso_window = 'early') AS enso_abl_nino3_early_mean,
        avg(nino12) FILTER (WHERE enso_window = 'precycle_180d') AS enso_abl_nino12_precycle_mean,
        avg(nino12) FILTER (WHERE enso_window = 'early') AS enso_abl_nino12_early_mean,
        avg(nino4) FILTER (WHERE enso_window = 'precycle_180d') AS enso_abl_nino4_precycle_mean,
        avg(nino4) FILTER (WHERE enso_window = 'early') AS enso_abl_nino4_early_mean,

        avg(nino34) FILTER (WHERE enso_window = 'mid') AS enso_abl_nino34_mid_mean,
        avg(nino34) FILTER (WHERE enso_window = 'late') AS enso_abl_nino34_late_mean,

        avg(oni) FILTER (WHERE enso_window = 'precycle_180d')
            * avg(soi) FILTER (WHERE enso_window = 'precycle_180d') AS enso_abl_oni_x_soi_precycle,
        avg(oni) FILTER (WHERE enso_window = 'early')
            - avg(oni) FILTER (WHERE enso_window = 'precycle_180d') AS enso_abl_oni_early_minus_precycle,
        avg(soi) FILTER (WHERE enso_window = 'early')
            - avg(soi) FILTER (WHERE enso_window = 'precycle_180d') AS enso_abl_soi_early_minus_precycle,
        avg((abs(oni) >= 0.5)::int) FILTER (WHERE enso_window = 'precycle_180d')::double precision AS enso_abl_oni_active_fraction_precycle
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

    e.enso_abl_roni_precycle_mean,
    e.enso_abl_roni_early_mean,
    e.enso_abl_roni_mid_mean,
    e.enso_abl_roni_late_mean,
    e.enso_abl_roni_abs_max_precycle_early,
    e.enso_abl_mei_precycle_mean,
    e.enso_abl_mei_early_mean,
    e.enso_abl_mei_abs_max_precycle_early,
    e.enso_abl_pdo_precycle_mean,
    e.enso_abl_pdo_early_mean,
    e.enso_abl_amo_precycle_mean,
    e.enso_abl_amo_early_mean,
    e.enso_abl_nino3_precycle_mean,
    e.enso_abl_nino3_early_mean,
    e.enso_abl_nino12_precycle_mean,
    e.enso_abl_nino12_early_mean,
    e.enso_abl_nino4_precycle_mean,
    e.enso_abl_nino4_early_mean,
    e.enso_abl_nino34_mid_mean,
    e.enso_abl_nino34_late_mean,
    e.enso_abl_oni_x_soi_precycle,
    e.enso_abl_oni_early_minus_precycle,
    e.enso_abl_soi_early_minus_precycle,
    e.enso_abl_oni_active_fraction_precycle
FROM base_cycles b
LEFT JOIN enso_features e USING (cod_cg_zafra);
