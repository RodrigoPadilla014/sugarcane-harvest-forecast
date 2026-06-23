-- tch_v10_productivity_snapshot_spine.sql
--
-- Minimal temporal spine for v10.
--
-- Principles:
--   * productividad defines historical lot validity and target TCH;
--   * historical cycles are never removed because of optical/radar shape;
--   * age and closure provide administrative date candidates, not absolute truth;
--   * historical rows simulate information available at fixed snapshot ages;
--   * scoring uses every valid 2025_2026 lot as a 2026_2027 candidate;
--   * scoring eligibility begins at 180 observed days and is capped at 340 days;
--   * no recursive projection of older lots.
--   * historical productividad features are lagged by zafra and never use the
--     target zafra itself.
--
-- This is a cycle/snapshot spine. Feature aggregation is intentionally deferred
-- until the temporal diagnostics have been reviewed.

WITH
source_dates AS (
    SELECT greatest(
        COALESCE((SELECT max(fecha::date) FROM public.stac_indices), DATE '1900-01-01'),
        COALESCE((SELECT max(fecha::date) FROM public.radar), DATE '1900-01-01'),
        COALESCE((SELECT max(fecha_inicio::date) FROM public.clima_lote_pentada_new), DATE '1900-01-01')
    ) AS latest_source_date
),
prod_clean AS (
    SELECT
        trim(p.lote::text) AS cod_cg,
        p.cod_cg_zafra AS cod_cg_zafra_original,
        p.tch::double precision AS tch,
        p.tc::double precision AS tc,
        p.area::double precision AS area,
        p.edad::double precision AS prod_edad_meses,
        p.ingenio AS prod_ingenio,
        p.grupo_de_suelo AS prod_grupo_de_suelo,
        p.grupo_de_humedad AS prod_grupo_de_humedad,
        p.codigo_zae AS prod_codigo_zae,
        p.familia_de_suelo AS prod_familia_de_suelo,
        p.variedad AS prod_variedad,
        p.no_corte AS prod_no_corte,
        p.estrato AS prod_estrato,
        CASE
            WHEN p.cierre::text ~ '^\d{4}-\d{2}-\d{2}$'
            THEN to_date(p.cierre::text, 'YYYY-MM-DD')
            WHEN p.cierre::text ~ '^\d{2}/\d{2}/\d{4}$'
            THEN to_date(p.cierre::text, 'DD/MM/YYYY')
        END AS fecha_cierre_real
    FROM public.productividad p
    WHERE p.lote IS NOT NULL
      AND p.tch IS NOT NULL
      AND p.tch BETWEEN 20 AND 150
      AND p.cierre IS NOT NULL
      AND p.edad IS NOT NULL
),
prod_assigned AS (
    SELECT
        *,
        CASE
            WHEN EXTRACT(MONTH FROM fecha_cierre_real)::int BETWEEN 1 AND 5
            THEN ((EXTRACT(YEAR FROM fecha_cierre_real)::int - 1)::text
                  || '_' || EXTRACT(YEAR FROM fecha_cierre_real)::int::text)
            ELSE (EXTRACT(YEAR FROM fecha_cierre_real)::int::text
                  || '_' || (EXTRACT(YEAR FROM fecha_cierre_real)::int + 1)::text)
        END AS zafra_norm
    FROM prod_clean
    WHERE fecha_cierre_real BETWEEN DATE '2016-01-01'
                                AND CURRENT_DATE + INTERVAL '30 days'
),
prod_unique AS (
    SELECT DISTINCT ON (zafra_norm, cod_cg)
        *
    FROM prod_assigned
    WHERE zafra_norm BETWEEN '2016_2017' AND '2025_2026'
    ORDER BY zafra_norm, cod_cg, fecha_cierre_real DESC
),
prod_windows AS (
    SELECT
        p.*,
        lag(p.fecha_cierre_real) OVER (
            PARTITION BY p.cod_cg
            ORDER BY p.fecha_cierre_real
        ) AS previous_fecha_cierre,
        (
            p.fecha_cierre_real
            - make_interval(
                days => greatest(
                    0,
                    round(p.prod_edad_meses * 30.44)::integer
                )
            )
        )::date AS fecha_inicio_administrativa
    FROM prod_unique p
),
historical_cycles AS (
    SELECT
        (p.cod_cg || '_' || replace(p.zafra_norm, '_', '-'))::text AS cycle_id,
        p.cod_cg,
        p.zafra_norm,
        'training'::text AS dataset_role,
        true AS has_target_tch,
        p.tch,
        p.tc,
        p.area,
        p.fecha_cierre_real,
        p.prod_edad_meses,
        p.fecha_inicio_administrativa,
        CASE
            WHEN p.previous_fecha_cierre IS NOT NULL
            THEN (p.previous_fecha_cierre + INTERVAL '1 day')::date
        END AS fecha_inicio_por_cierre_anterior,
        p.previous_fecha_cierre,
        CASE
            WHEN p.previous_fecha_cierre IS NULL THEN NULL
            ELSE (
                p.fecha_inicio_administrativa
                - (p.previous_fecha_cierre + INTERVAL '1 day')::date
            )::integer
        END AS diferencia_inicios_dias,
        p.prod_ingenio,
        p.prod_grupo_de_suelo,
        p.prod_grupo_de_humedad,
        p.prod_codigo_zae,
        p.prod_familia_de_suelo,
        p.prod_variedad,
        p.prod_no_corte,
        p.prod_estrato
    FROM prod_windows p
    WHERE p.zafra_norm BETWEEN '2020_2021' AND '2025_2026'
),
historical_snapshots AS (
    SELECT
        c.*,
        'fixed_historical'::text AS snapshot_type,
        s.snapshot_day,
        (c.fecha_inicio_administrativa + make_interval(days => s.snapshot_day))::date AS snapshot_date,
        true AS snapshot_available,
        true AS scoring_age_eligible,
        (1.0 / count(*) OVER (PARTITION BY c.cycle_id))::double precision AS snapshot_weight
    FROM historical_cycles c
    CROSS JOIN (
        VALUES (180), (210), (240), (270), (300), (340)
    ) AS s(snapshot_day)
    WHERE c.fecha_inicio_administrativa + make_interval(days => s.snapshot_day)
          <= c.fecha_cierre_real
),
historical_below_minimum AS (
    SELECT
        c.*,
        'historical_below_minimum'::text AS snapshot_type,
        greatest(
            0,
            c.fecha_cierre_real - c.fecha_inicio_administrativa
        )::integer AS snapshot_day,
        c.fecha_cierre_real AS snapshot_date,
        true AS snapshot_available,
        false AS scoring_age_eligible,
        1.0::double precision AS snapshot_weight
    FROM historical_cycles c
    WHERE c.fecha_inicio_administrativa + INTERVAL '180 days'
          > c.fecha_cierre_real
),
latest_2025_2026 AS (
    SELECT *
    FROM historical_cycles
    WHERE zafra_norm = '2025_2026'
),
scoring_cycles AS (
    SELECT
        (p.cod_cg || '_2026-2027_open')::text AS cycle_id,
        p.cod_cg,
        '2026_2027'::text AS zafra_norm,
        'scoring'::text AS dataset_role,
        false AS has_target_tch,
        NULL::double precision AS tch,
        p.tc,
        p.area,
        NULL::date AS fecha_cierre_real,
        NULL::double precision AS prod_edad_meses,
        (p.fecha_cierre_real + INTERVAL '1 day')::date AS fecha_inicio_administrativa,
        (p.fecha_cierre_real + INTERVAL '1 day')::date AS fecha_inicio_por_cierre_anterior,
        p.fecha_cierre_real AS previous_fecha_cierre,
        0::integer AS diferencia_inicios_dias,
        p.prod_ingenio,
        p.prod_grupo_de_suelo,
        p.prod_grupo_de_humedad,
        p.prod_codigo_zae,
        p.prod_familia_de_suelo,
        p.prod_variedad,
        p.prod_no_corte,
        p.prod_estrato,
        d.latest_source_date
    FROM latest_2025_2026 p
    CROSS JOIN source_dates d
),
scoring_snapshots AS (
    SELECT
        c.cycle_id,
        c.cod_cg,
        c.zafra_norm,
        c.dataset_role,
        c.has_target_tch,
        c.tch,
        c.tc,
        c.area,
        c.fecha_cierre_real,
        c.prod_edad_meses,
        c.fecha_inicio_administrativa,
        c.fecha_inicio_por_cierre_anterior,
        c.previous_fecha_cierre,
        c.diferencia_inicios_dias,
        c.prod_ingenio,
        c.prod_grupo_de_suelo,
        c.prod_grupo_de_humedad,
        c.prod_codigo_zae,
        c.prod_familia_de_suelo,
        c.prod_variedad,
        c.prod_no_corte,
        c.prod_estrato,
        'current_scoring'::text AS snapshot_type,
        least(
            340,
            greatest(0, c.latest_source_date - c.fecha_inicio_administrativa)
        )::integer AS snapshot_day,
        least(
            c.latest_source_date,
            c.fecha_inicio_administrativa + INTERVAL '340 days'
        )::date AS snapshot_date,
        (c.latest_source_date >= c.fecha_inicio_administrativa) AS snapshot_available,
        (
            c.latest_source_date - c.fecha_inicio_administrativa
        ) BETWEEN 180 AND 340 AS scoring_age_eligible,
        1.0::double precision AS snapshot_weight
    FROM scoring_cycles c
)
,
history_target_keys AS (
    SELECT DISTINCT cod_cg, zafra_norm
    FROM historical_snapshots
    UNION
    SELECT DISTINCT cod_cg, zafra_norm
    FROM historical_below_minimum
    UNION
    SELECT DISTINCT cod_cg, zafra_norm
    FROM scoring_snapshots
),
history_ranked AS (
    SELECT
        t.cod_cg,
        t.zafra_norm,
        h.zafra_norm AS hist_zafra_norm,
        h.tch AS hist_tch,
        h.area AS hist_area,
        h.tc AS hist_tc,
        h.fecha_cierre_real AS hist_fecha_cierre_real,
        h.prod_edad_meses AS hist_edad_meses,
        h.prod_no_corte AS hist_no_corte,
        h.prod_estrato AS hist_estrato,
        h.prod_ingenio AS hist_ingenio,
        row_number() OVER (
            PARTITION BY t.cod_cg, t.zafra_norm
            ORDER BY h.zafra_norm DESC, h.fecha_cierre_real DESC
        ) AS hist_rank
    FROM history_target_keys t
    LEFT JOIN prod_unique h
      ON h.cod_cg = t.cod_cg
     AND h.zafra_norm < t.zafra_norm
),
history_features AS (
    SELECT
        cod_cg,
        zafra_norm,
        max(hist_zafra_norm) FILTER (WHERE hist_rank = 1) AS last_hist_zafra_norm,
        max(hist_tch) FILTER (WHERE hist_rank = 1) AS last_hist_tch,
        max(hist_area) FILTER (WHERE hist_rank = 1) AS last_hist_area,
        max(hist_tc) FILTER (WHERE hist_rank = 1) AS last_hist_tc,
        max(hist_fecha_cierre_real) FILTER (WHERE hist_rank = 1) AS last_hist_fecha_cierre_real,
        max(hist_edad_meses) FILTER (WHERE hist_rank = 1) AS last_hist_edad_meses,
        max(hist_no_corte) FILTER (WHERE hist_rank = 1) AS last_hist_no_corte,
        max(hist_estrato) FILTER (WHERE hist_rank = 1) AS last_hist_estrato,
        max(hist_ingenio) FILTER (WHERE hist_rank = 1) AS last_hist_ingenio,
        count(hist_tch)::double precision AS hist_tch_count_available,
        avg(hist_tch) FILTER (WHERE hist_rank <= 2) AS hist_tch_mean_last2,
        avg(hist_tch) FILTER (WHERE hist_rank <= 3) AS hist_tch_mean_last3,
        stddev_samp(hist_tch) FILTER (WHERE hist_rank <= 3) AS hist_tch_std_last3,
        min(hist_tch) FILTER (WHERE hist_rank <= 3) AS hist_tch_min_last3,
        max(hist_tch) FILTER (WHERE hist_rank <= 3) AS hist_tch_max_last3,
        (
            max(hist_tch) FILTER (WHERE hist_rank = 1)
            - max(hist_tch) FILTER (WHERE hist_rank = 2)
        ) AS hist_tch_trend_last2,
        (max(hist_tch) FILTER (WHERE hist_rank = 1) IS NOT NULL)::integer
            AS has_last_hist_tch,
        (count(hist_tch) >= 2)::integer AS has_hist_2plus,
        (count(hist_tch) >= 3)::integer AS has_hist_3plus,
        (
            max(hist_zafra_norm) FILTER (WHERE hist_rank = 1)
            = (
                (split_part(zafra_norm, '_', 1)::integer - 1)::text
                || '_' || split_part(zafra_norm, '_', 1)
            )
        )::integer AS has_immediate_previous_zafra
    FROM history_ranked
    GROUP BY cod_cg, zafra_norm
),
history_estrato_means AS (
    SELECT
        zafra_norm,
        prod_estrato,
        avg(tch) AS estrato_zafra_tch_mean
    FROM prod_unique
    GROUP BY zafra_norm, prod_estrato
),
history_ingenio_means AS (
    SELECT
        zafra_norm,
        prod_ingenio,
        avg(tch) AS ingenio_zafra_tch_mean
    FROM prod_unique
    GROUP BY zafra_norm, prod_ingenio
),
history_group_means AS (
    SELECT
        h.cod_cg,
        h.zafra_norm,
        e.estrato_zafra_tch_mean AS last_hist_estrato_zafra_tch_mean,
        i.ingenio_zafra_tch_mean AS last_hist_ingenio_zafra_tch_mean
    FROM history_features h
    LEFT JOIN history_estrato_means e
      ON e.zafra_norm = h.last_hist_zafra_norm
     AND e.prod_estrato = h.last_hist_estrato
    LEFT JOIN history_ingenio_means i
      ON i.zafra_norm = h.last_hist_zafra_norm
     AND i.prod_ingenio = h.last_hist_ingenio
),
history_features_enriched AS (
    SELECT
        h.*,
        g.last_hist_estrato_zafra_tch_mean,
        g.last_hist_ingenio_zafra_tch_mean,
        h.last_hist_tch - g.last_hist_estrato_zafra_tch_mean
            AS last_hist_tch_minus_estrato_zafra_mean,
        h.last_hist_tch - g.last_hist_ingenio_zafra_tch_mean
            AS last_hist_tch_minus_ingenio_zafra_mean,
        h.last_hist_tch / NULLIF(g.last_hist_estrato_zafra_tch_mean, 0)
            AS last_hist_tch_ratio_estrato_zafra_mean,
        h.last_hist_tch / NULLIF(g.last_hist_ingenio_zafra_tch_mean, 0)
            AS last_hist_tch_ratio_ingenio_zafra_mean
    FROM history_features h
    LEFT JOIN history_group_means g
      ON g.cod_cg = h.cod_cg
     AND g.zafra_norm = h.zafra_norm
),
snapshot_spine AS (
    SELECT * FROM historical_snapshots
    UNION ALL
    SELECT * FROM historical_below_minimum
    UNION ALL
    SELECT * FROM scoring_snapshots
)
SELECT
    (cycle_id || '_d' || snapshot_day::text)::text AS cod_cg_zafra,
    snapshot_spine.*,
    snapshot_day::double precision AS prediction_age_days,
    h.last_hist_zafra_norm,
    h.last_hist_tch,
    h.last_hist_area,
    h.last_hist_tc,
    h.last_hist_fecha_cierre_real,
    h.last_hist_edad_meses,
    h.last_hist_no_corte,
    h.last_hist_estrato,
    h.last_hist_ingenio,
    h.hist_tch_count_available,
    h.hist_tch_mean_last2,
    h.hist_tch_mean_last3,
    h.hist_tch_std_last3,
    h.hist_tch_min_last3,
    h.hist_tch_max_last3,
    h.hist_tch_trend_last2,
    h.has_last_hist_tch,
    h.has_hist_2plus,
    h.has_hist_3plus,
    h.has_immediate_previous_zafra,
    h.last_hist_estrato_zafra_tch_mean,
    h.last_hist_ingenio_zafra_tch_mean,
    h.last_hist_tch_minus_estrato_zafra_mean,
    h.last_hist_tch_minus_ingenio_zafra_mean,
    h.last_hist_tch_ratio_estrato_zafra_mean,
    h.last_hist_tch_ratio_ingenio_zafra_mean
FROM snapshot_spine
LEFT JOIN history_features_enriched h
  ON h.cod_cg = snapshot_spine.cod_cg
 AND h.zafra_norm = snapshot_spine.zafra_norm;
