-- tch_features_v7_dynamic_all_cycles.sql
--
-- Standalone dynamic-as-of feature dataset.
--
-- Intent:
--   * one row per lot-cycle;
--   * closed cycles are training rows with real TCH from productividad;
--   * open cycles are scoring rows without TCH;
--   * include only cycles with at least 180 days available;
--   * use the natural available age, capped at 340 days;
--   * assign productive zafra from real or estimated closure, not from
--     STAC/climate/radar source zafra labels.
--
-- Source tables:
--   public.productividad
--   public.stac_indices
--   public.clima_lote_pentada_new
--   public.enso
--
-- This query is self-contained for sagemaker/jobs/upload_dataset.py.

WITH
productividad_lote_keys AS (
    SELECT DISTINCT
        p.lote::text AS cod_cg,
        CASE
            WHEN p.lote::text LIKE '%-%'
             AND split_part(trim(p.lote::text), '-', 2) ~ '^\d+$'
            THEN split_part(trim(p.lote::text), '-', 1) || '-' || (split_part(trim(p.lote::text), '-', 2)::bigint)::text
            ELSE NULL
        END AS canonical_lote_key
    FROM public.productividad p
    WHERE p.lote IS NOT NULL
),
stac_lote_keys AS (
    SELECT DISTINCT
        s.lote::text AS source_lote,
        CASE
            WHEN s.lote::text LIKE '%-%'
             AND split_part(trim(s.lote::text), '-', 2) ~ '^\d+$'
            THEN split_part(trim(s.lote::text), '-', 1) || '-' || (split_part(trim(s.lote::text), '-', 2)::bigint)::text
            ELSE NULL
        END AS canonical_lote_key
    FROM public.stac_indices s
    WHERE s.lote IS NOT NULL
),
stac_lote_canonical_unique AS (
    SELECT
        canonical_lote_key,
        min(source_lote) AS source_lote
    FROM stac_lote_keys
    WHERE canonical_lote_key IS NOT NULL
    GROUP BY canonical_lote_key
    HAVING count(DISTINCT source_lote) = 1
),
stac_lote_lookup AS (
    SELECT
        p.cod_cg,
        COALESCE(exact.source_lote, canonical.source_lote) AS stac_lote_matched,
        CASE
            WHEN exact.source_lote IS NOT NULL THEN 'exact'
            WHEN canonical.source_lote IS NOT NULL THEN 'canonical'
            ELSE 'no_match'
        END AS stac_lote_match_method
    FROM productividad_lote_keys p
    LEFT JOIN stac_lote_keys exact
      ON exact.source_lote = p.cod_cg
    LEFT JOIN stac_lote_canonical_unique canonical
      ON canonical.canonical_lote_key = p.canonical_lote_key
),
climate_lote_keys AS (
    SELECT DISTINCT
        c.cod_cg::text AS source_lote,
        CASE
            WHEN c.cod_cg::text LIKE '%-%'
             AND split_part(trim(c.cod_cg::text), '-', 2) ~ '^\d+$'
            THEN split_part(trim(c.cod_cg::text), '-', 1) || '-' || (split_part(trim(c.cod_cg::text), '-', 2)::bigint)::text
            ELSE NULL
        END AS canonical_lote_key
    FROM public.clima_lote_pentada_new c
    WHERE c.cod_cg IS NOT NULL
),
climate_lote_canonical_unique AS (
    SELECT
        canonical_lote_key,
        min(source_lote) AS source_lote
    FROM climate_lote_keys
    WHERE canonical_lote_key IS NOT NULL
    GROUP BY canonical_lote_key
    HAVING count(DISTINCT source_lote) = 1
),
climate_lote_lookup AS (
    SELECT
        p.cod_cg,
        COALESCE(exact.source_lote, canonical.source_lote) AS climate_lote_matched,
        CASE
            WHEN exact.source_lote IS NOT NULL THEN 'exact'
            WHEN canonical.source_lote IS NOT NULL THEN 'canonical'
            ELSE 'no_match'
        END AS climate_lote_match_method
    FROM productividad_lote_keys p
    LEFT JOIN climate_lote_keys exact
      ON exact.source_lote = p.cod_cg
    LEFT JOIN climate_lote_canonical_unique canonical
      ON canonical.canonical_lote_key = p.canonical_lote_key
),
prod_source AS (
    SELECT
        p.lote AS cod_cg,
        p.cod_cg_zafra AS cod_cg_zafra_original,
        replace(regexp_replace(p.zafra, '^Zafra\s+', '', 'i'), '-', '_') AS zafra_norm_original,
        p.zafra AS zafra_productividad_raw,
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
        p.cierre,
        CASE
            WHEN p.cierre::text ~ '^\d{4}-\d{2}-\d{2}$' THEN to_date(p.cierre::text, 'YYYY-MM-DD')
            WHEN p.cierre::text ~ '^\d{2}/\d{2}/\d{4}$' THEN to_date(p.cierre::text, 'DD/MM/YYYY')
            ELSE NULL::date
        END AS fecha_cierre_real
    FROM public.productividad p
    WHERE p.cod_cg_zafra IS NOT NULL
      AND p.lote IS NOT NULL
      AND p.tch IS NOT NULL
      AND p.tch BETWEEN 20 AND 150
      AND p.cierre IS NOT NULL
      AND p.edad IS NOT NULL
),
prod_windows AS (
    SELECT
        p.*,
        (
            p.fecha_cierre_real
            - make_interval(days => greatest(0, round((p.prod_edad_meses * 30.44))::integer))
        )::date AS fecha_inicio_baseline,
        lag(p.fecha_cierre_real) OVER (
            PARTITION BY p.cod_cg
            ORDER BY p.fecha_cierre_real
        ) AS previous_fecha_cierre
    FROM prod_source p
    WHERE p.fecha_cierre_real IS NOT NULL
),
closed_cycle_spine AS (
    SELECT
        p.cod_cg,
        CASE
            WHEN EXTRACT(MONTH FROM p.fecha_cierre_real)::int BETWEEN 1 AND 5 THEN
                ((EXTRACT(YEAR FROM p.fecha_cierre_real)::int - 1)::text || '_' || EXTRACT(YEAR FROM p.fecha_cierre_real)::int::text)
            WHEN EXTRACT(MONTH FROM p.fecha_cierre_real)::int BETWEEN 6 AND 12 THEN
                (EXTRACT(YEAR FROM p.fecha_cierre_real)::int::text || '_' || (EXTRACT(YEAR FROM p.fecha_cierre_real)::int + 1)::text)
            ELSE p.zafra_norm_original
        END AS zafra_norm,
        p.cod_cg_zafra_original,
        p.zafra_norm_original,
        'training'::text AS dataset_role,
        'closed'::text AS cycle_status,
        true AS has_target_tch,
        p.tch,
        p.tc,
        p.area,
        GREATEST(
            p.fecha_inicio_baseline,
            COALESCE((p.previous_fecha_cierre + INTERVAL '21 days')::date, p.fecha_inicio_baseline)
        ) AS fecha_inicio_ciclo,
        p.fecha_inicio_baseline,
        p.fecha_cierre_real,
        NULL::date AS fecha_cierre_estimada,
        p.fecha_cierre_real AS fecha_fin_ciclo,
        p.previous_fecha_cierre,
        'closed_baseline_or_previous_cierre_plus_21d'::text AS start_rule,
        (
            GREATEST(
                p.fecha_inicio_baseline,
                COALESCE((p.previous_fecha_cierre + INTERVAL '21 days')::date, p.fecha_inicio_baseline)
            ) - p.fecha_inicio_baseline
        )::integer AS start_correction_days,
        'real_cierre_productiva'::text AS zafra_assignment_method,
        p.prod_edad_meses,
        p.prod_ingenio,
        p.prod_grupo_de_suelo,
        p.prod_grupo_de_humedad,
        p.prod_codigo_zae,
        p.prod_familia_de_suelo,
        p.prod_variedad,
        p.prod_no_corte
    FROM prod_windows p
),
closed_zafra_bounds AS (
    SELECT max(zafra_norm) AS max_training_zafra
    FROM closed_cycle_spine
),
latest_closed_cycle AS (
    SELECT DISTINCT ON (cod_cg)
        cod_cg,
        zafra_norm AS previous_zafra_norm,
        fecha_inicio_ciclo AS previous_fecha_inicio_ciclo,
        fecha_cierre_real AS previous_fecha_cierre,
        tch AS previous_tch,
        tc AS previous_tc,
        area,
        prod_ingenio,
        prod_grupo_de_suelo,
        prod_grupo_de_humedad,
        prod_codigo_zae,
        prod_familia_de_suelo,
        prod_variedad,
        prod_no_corte
    FROM closed_cycle_spine
    ORDER BY cod_cg, fecha_cierre_real DESC NULLS LAST
),
open_cycle_dates AS (
    SELECT
        l.*,
        (l.previous_fecha_cierre + INTERVAL '1 day')::date AS fecha_inicio_ciclo,
        ((l.previous_fecha_cierre + INTERVAL '1 day') + INTERVAL '365 days')::date AS fecha_cierre_estimada
    FROM latest_closed_cycle l
),
open_latest_observation AS (
    SELECT
        o.cod_cg,
        GREATEST(
            COALESCE(max(s.fecha)::date, DATE '1900-01-01'),
            COALESCE(max(c.fecha_inicio)::date, DATE '1900-01-01')
        ) AS latest_observation_date
    FROM open_cycle_dates o
    LEFT JOIN stac_lote_lookup sl
      ON sl.cod_cg = o.cod_cg
    LEFT JOIN public.stac_indices s
      ON s.lote = sl.stac_lote_matched
     AND s.fecha::date >= o.fecha_inicio_ciclo
    LEFT JOIN climate_lote_lookup cl
      ON cl.cod_cg = o.cod_cg
    LEFT JOIN public.clima_lote_pentada_new c
      ON c.cod_cg = cl.climate_lote_matched
     AND c.fecha_inicio::date >= o.fecha_inicio_ciclo
    GROUP BY o.cod_cg
),
open_cycle_spine AS (
    SELECT
        o.cod_cg,
        CASE
            WHEN EXTRACT(MONTH FROM o.fecha_cierre_estimada)::int BETWEEN 1 AND 5 THEN
                ((EXTRACT(YEAR FROM o.fecha_cierre_estimada)::int - 1)::text || '_' || EXTRACT(YEAR FROM o.fecha_cierre_estimada)::int::text)
            WHEN EXTRACT(MONTH FROM o.fecha_cierre_estimada)::int BETWEEN 6 AND 12 THEN
                (EXTRACT(YEAR FROM o.fecha_cierre_estimada)::int::text || '_' || (EXTRACT(YEAR FROM o.fecha_cierre_estimada)::int + 1)::text)
            ELSE NULL
        END AS zafra_norm,
        NULL::text AS cod_cg_zafra_original,
        NULL::text AS zafra_norm_original,
        'scoring'::text AS dataset_role,
        'open'::text AS cycle_status,
        false AS has_target_tch,
        NULL::double precision AS tch,
        NULL::double precision AS tc,
        o.area,
        o.fecha_inicio_ciclo,
        NULL::date AS fecha_inicio_baseline,
        NULL::date AS fecha_cierre_real,
        o.fecha_cierre_estimada,
        o.fecha_cierre_estimada AS fecha_fin_ciclo,
        o.previous_fecha_cierre,
        'open_previous_cierre_plus_1d'::text AS start_rule,
        NULL::integer AS start_correction_days,
        'estimated_cierre_productiva'::text AS zafra_assignment_method,
        NULL::double precision AS prod_edad_meses,
        o.prod_ingenio,
        o.prod_grupo_de_suelo,
        o.prod_grupo_de_humedad,
        o.prod_codigo_zae,
        o.prod_familia_de_suelo,
        o.prod_variedad,
        o.prod_no_corte,
        o.previous_zafra_norm,
        o.previous_fecha_inicio_ciclo,
        o.previous_tch,
        o.previous_tc,
        obs.latest_observation_date
    FROM open_cycle_dates o
    JOIN open_latest_observation obs USING (cod_cg)
    CROSS JOIN closed_zafra_bounds bounds
    WHERE obs.latest_observation_date >= o.fecha_inicio_ciclo
      AND (
          CASE
              WHEN EXTRACT(MONTH FROM o.fecha_cierre_estimada)::int BETWEEN 1 AND 5 THEN
                  ((EXTRACT(YEAR FROM o.fecha_cierre_estimada)::int - 1)::text || '_' || EXTRACT(YEAR FROM o.fecha_cierre_estimada)::int::text)
              WHEN EXTRACT(MONTH FROM o.fecha_cierre_estimada)::int BETWEEN 6 AND 12 THEN
                  (EXTRACT(YEAR FROM o.fecha_cierre_estimada)::int::text || '_' || (EXTRACT(YEAR FROM o.fecha_cierre_estimada)::int + 1)::text)
              ELSE NULL
          END
      ) > bounds.max_training_zafra
),
cycle_spine AS (
    SELECT
        (c.cod_cg || '_' || replace(c.zafra_norm, '_', '-'))::text AS cod_cg_zafra,
        c.cod_cg,
        c.zafra_norm,
        c.cod_cg_zafra_original,
        c.zafra_norm_original,
        c.dataset_role,
        c.cycle_status,
        c.has_target_tch,
        c.tch,
        c.tc,
        c.area,
        c.fecha_inicio_ciclo,
        c.fecha_inicio_baseline,
        c.fecha_cierre_real,
        c.fecha_cierre_estimada,
        c.fecha_fin_ciclo,
        c.previous_fecha_cierre,
        NULL::text AS previous_zafra_norm,
        NULL::date AS previous_fecha_inicio_ciclo,
        NULL::double precision AS previous_tch,
        NULL::double precision AS previous_tc,
        c.start_rule,
        c.start_correction_days,
        c.zafra_assignment_method,
        c.prod_edad_meses,
        c.prod_ingenio,
        c.prod_grupo_de_suelo,
        c.prod_grupo_de_humedad,
        c.prod_codigo_zae,
        c.prod_familia_de_suelo,
        c.prod_variedad,
        c.prod_no_corte,
        c.fecha_fin_ciclo AS natural_asof_limit_date
    FROM closed_cycle_spine c

    UNION ALL

    SELECT
        (o.cod_cg || '_' || replace(o.zafra_norm, '_', '-') || '_open')::text AS cod_cg_zafra,
        o.cod_cg,
        o.zafra_norm,
        o.cod_cg_zafra_original,
        o.zafra_norm_original,
        o.dataset_role,
        o.cycle_status,
        o.has_target_tch,
        o.tch,
        o.tc,
        o.area,
        o.fecha_inicio_ciclo,
        o.fecha_inicio_baseline,
        o.fecha_cierre_real,
        o.fecha_cierre_estimada,
        o.fecha_fin_ciclo,
        o.previous_fecha_cierre,
        o.previous_zafra_norm,
        o.previous_fecha_inicio_ciclo,
        o.previous_tch,
        o.previous_tc,
        o.start_rule,
        o.start_correction_days,
        o.zafra_assignment_method,
        o.prod_edad_meses,
        o.prod_ingenio,
        o.prod_grupo_de_suelo,
        o.prod_grupo_de_humedad,
        o.prod_codigo_zae,
        o.prod_familia_de_suelo,
        o.prod_variedad,
        o.prod_no_corte,
        o.latest_observation_date AS natural_asof_limit_date
    FROM open_cycle_spine o
),
eligible_cycles AS (
    SELECT
        *,
        180::integer AS min_prediction_age_days,
        340::integer AS max_prediction_age_days,
        LEAST(natural_asof_limit_date, (fecha_inicio_ciclo + INTERVAL '340 days')::date) AS as_of_date,
        (LEAST(natural_asof_limit_date, (fecha_inicio_ciclo + INTERVAL '340 days')::date) - fecha_inicio_ciclo)::double precision AS as_of_age_days,
        (fecha_fin_ciclo - fecha_inicio_ciclo)::double precision AS cycle_duration_days
    FROM cycle_spine
    WHERE natural_asof_limit_date IS NOT NULL
      AND (LEAST(natural_asof_limit_date, (fecha_inicio_ciclo + INTERVAL '340 days')::date) - fecha_inicio_ciclo) >= 180
      AND zafra_norm >= '2020_2021'
),
optical_long AS (
    SELECT
        b.cod_cg_zafra,
        s.fecha::date AS fecha_obs,
        (s.fecha::date - b.fecha_inicio_ciclo)::double precision AS age_days,
        b.as_of_age_days,
        CASE
            WHEN (s.fecha::date - b.fecha_inicio_ciclo) BETWEEN 0 AND 90 THEN 'age_000_090'
            WHEN (s.fecha::date - b.fecha_inicio_ciclo) BETWEEN 91 AND 180 THEN 'age_091_180'
            WHEN (s.fecha::date - b.fecha_inicio_ciclo) BETWEEN 181 AND b.as_of_age_days THEN 'age_181_asof'
            ELSE 'outside'
        END AS age_window,
        CASE
            WHEN (s.fecha::date - b.fecha_inicio_ciclo) >= greatest(0.0, b.as_of_age_days - 30.0) THEN true
            ELSE false
        END AS in_last_30d,
        CASE
            WHEN (s.fecha::date - b.fecha_inicio_ciclo) >= greatest(0.0, b.as_of_age_days - 60.0) THEN true
            ELSE false
        END AS in_last_60d,
        v.index_name,
        v.index_value
    FROM eligible_cycles b
    JOIN stac_lote_lookup sl
      ON sl.cod_cg = b.cod_cg
    JOIN public.stac_indices s
      ON s.lote = sl.stac_lote_matched
     AND s.fecha::date BETWEEN b.fecha_inicio_ciclo AND b.as_of_date
    CROSS JOIN LATERAL (
        VALUES
            ('ndvi', NULLIF(s.ndvi_promedio::text, 'NaN')::double precision),
            ('evi2', NULLIF(s.evi2_promedio::text, 'NaN')::double precision),
            ('gndvi', NULLIF(s.gndvi_promedio::text, 'NaN')::double precision),
            ('ndre', NULLIF(s.ndre_promedio::text, 'NaN')::double precision),
            ('lswi', NULLIF(s.lswi_promedio::text, 'NaN')::double precision),
            ('ndvire', NULLIF(s.ndvire_promedio::text, 'NaN')::double precision),
            ('cire', NULLIF(s.cire_promedio::text, 'NaN')::double precision),
            ('ndwi11', NULLIF(s.ndwi11_promedio::text, 'NaN')::double precision),
            ('msi11', NULLIF(s.msi11_promedio::text, 'NaN')::double precision)
    ) AS v(index_name, index_value)
),
optical_prepared AS (
    SELECT
        *,
        lag(age_days) OVER (
            PARTITION BY cod_cg_zafra, index_name
            ORDER BY age_days, fecha_obs
        ) AS prev_age
    FROM optical_long
    WHERE index_value IS NOT NULL
),
optical_features_long AS (
    SELECT
        cod_cg_zafra,
        index_name,
        count(DISTINCT fecha_obs) FILTER (
            WHERE index_value IS NOT NULL
        )::double precision AS obs_count_0_asof,
        count(DISTINCT fecha_obs) FILTER (
            WHERE index_value IS NOT NULL
              AND age_days BETWEEN 0 AND 180
        )::double precision AS obs_count_0_180,
        count(index_value) FILTER (WHERE age_window = 'age_181_asof')::double precision AS obs_count_181_asof,
        count(index_value) FILTER (WHERE in_last_30d)::double precision AS obs_count_last30,
        count(index_value) FILTER (WHERE in_last_60d)::double precision AS obs_count_last60,
        min(age_days) FILTER (WHERE index_value IS NOT NULL) AS first_obs_age_0_asof,
        max(age_days) FILTER (WHERE index_value IS NOT NULL) AS last_obs_age_0_asof,
        min(age_days) FILTER (
            WHERE index_value IS NOT NULL
              AND age_days BETWEEN 0 AND 180
        ) AS first_obs_age_0_180,
        max(age_days) FILTER (
            WHERE index_value IS NOT NULL
              AND age_days BETWEEN 0 AND 180
        ) AS last_obs_age_0_180,
        max(age_days - prev_age) FILTER (WHERE index_value IS NOT NULL AND age_days <= 180) AS max_gap_days_0_180,
        max(age_days - prev_age) FILTER (WHERE index_value IS NOT NULL) AS max_gap_days_0_asof,
        avg(index_value) AS mean_0_asof,
        avg(index_value) FILTER (WHERE age_days BETWEEN 0 AND 180) AS mean_0_180,
        avg(index_value) FILTER (WHERE age_window = 'age_181_asof') AS mean_181_asof,
        avg(index_value) FILTER (WHERE in_last_30d) AS mean_last30,
        avg(index_value) FILTER (WHERE in_last_60d) AS mean_last60,
        max(index_value) AS peak_0_asof,
        max(index_value) FILTER (WHERE age_days BETWEEN 0 AND 180) AS peak_0_180,
        min(index_value) AS min_0_asof,
        min(index_value) FILTER (WHERE age_days BETWEEN 0 AND 180) AS min_0_180,
        max(index_value) - min(index_value) AS amplitude_0_asof,
        max(index_value) FILTER (WHERE age_days BETWEEN 0 AND 180)
            - min(index_value) FILTER (WHERE age_days BETWEEN 0 AND 180) AS amplitude_0_180,
        regr_slope(index_value, age_days) AS slope_0_asof,
        regr_slope(index_value, age_days) FILTER (WHERE age_days BETWEEN 0 AND 180) AS slope_0_180,
        regr_slope(index_value, age_days) FILTER (WHERE age_window = 'age_181_asof') AS slope_181_asof,
        (array_agg(index_value ORDER BY age_days DESC NULLS LAST, fecha_obs DESC)
            FILTER (WHERE index_value IS NOT NULL))[1] AS last_value_before_asof
    FROM optical_prepared
    GROUP BY cod_cg_zafra, index_name
),
optical_core AS (
    SELECT
        cod_cg_zafra,

        max(obs_count_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_obs_count_0_180,
        max(obs_count_0_asof) FILTER (WHERE index_name = 'ndvi') AS optical_obs_count_0_asof,
        max(obs_count_181_asof) FILTER (WHERE index_name = 'ndvi') AS optical_obs_count_181_asof,
        max(obs_count_last30) FILTER (WHERE index_name = 'ndvi') AS optical_obs_count_last30,
        max(max_gap_days_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_max_gap_days_0_180,
        max(max_gap_days_0_asof) FILTER (WHERE index_name = 'ndvi') AS optical_max_gap_days_0_asof,
        greatest(
            max(first_obs_age_0_180) FILTER (WHERE index_name = 'ndvi'),
            max(max_gap_days_0_180) FILTER (WHERE index_name = 'ndvi'),
            180.0 - max(last_obs_age_0_180) FILTER (WHERE index_name = 'ndvi')
        ) AS optical_boundary_max_gap_days_0_180,

        max(mean_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mean_0_180,
        max(mean_0_asof) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mean_0_asof,
        max(mean_181_asof) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mean_181_asof,
        max(mean_last30) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mean_last30,
        max(mean_last60) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mean_last60,
        max(peak_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_peak_0_180,
        max(peak_0_asof) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_peak_0_asof,
        max(min_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_min_0_180,
        max(amplitude_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_amplitude_0_180,
        max(amplitude_0_asof) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_amplitude_0_asof,
        max(slope_0_180) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_slope_0_180,
        max(slope_0_asof) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_slope_0_asof,
        max(slope_181_asof) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_slope_181_asof,
        max(last_value_before_asof) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_last_value_before_asof,

        max(mean_0_180) FILTER (WHERE index_name = 'evi2') AS optical_evi2_mean_0_180,
        max(mean_0_asof) FILTER (WHERE index_name = 'evi2') AS optical_evi2_mean_0_asof,
        max(mean_last30) FILTER (WHERE index_name = 'evi2') AS optical_evi2_mean_last30,
        max(peak_0_asof) FILTER (WHERE index_name = 'evi2') AS optical_evi2_peak_0_asof,
        max(slope_0_asof) FILTER (WHERE index_name = 'evi2') AS optical_evi2_slope_0_asof,

        max(mean_0_180) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_mean_0_180,
        max(mean_0_asof) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_mean_0_asof,
        max(mean_last30) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_mean_last30,
        max(peak_0_asof) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_peak_0_asof,
        max(slope_0_asof) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_slope_0_asof,

        max(mean_0_180) FILTER (WHERE index_name = 'ndre') AS optical_ndre_mean_0_180,
        max(mean_0_asof) FILTER (WHERE index_name = 'ndre') AS optical_ndre_mean_0_asof,
        max(mean_181_asof) FILTER (WHERE index_name = 'ndre') AS optical_ndre_mean_181_asof,
        max(mean_last30) FILTER (WHERE index_name = 'ndre') AS optical_ndre_mean_last30,
        max(peak_0_asof) FILTER (WHERE index_name = 'ndre') AS optical_ndre_peak_0_asof,
        max(slope_0_asof) FILTER (WHERE index_name = 'ndre') AS optical_ndre_slope_0_asof,

        max(mean_0_asof) FILTER (WHERE index_name = 'lswi') AS optical_lswi_mean_0_asof,
        max(mean_181_asof) FILTER (WHERE index_name = 'lswi') AS optical_lswi_mean_181_asof,
        max(mean_last30) FILTER (WHERE index_name = 'lswi') AS optical_lswi_mean_last30,
        max(mean_0_asof) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_mean_0_asof,
        max(mean_181_asof) FILTER (WHERE index_name = 'ndvire') AS optical_ndvire_mean_181_asof,
        max(mean_0_asof) FILTER (WHERE index_name = 'cire') AS optical_cire_mean_0_asof,
        max(mean_181_asof) FILTER (WHERE index_name = 'cire') AS optical_cire_mean_181_asof,
        max(mean_0_asof) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_mean_0_asof,
        max(mean_181_asof) FILTER (WHERE index_name = 'ndwi11') AS optical_ndwi11_mean_181_asof,
        max(mean_0_asof) FILTER (WHERE index_name = 'msi11') AS optical_msi11_mean_0_asof,
        max(mean_181_asof) FILTER (WHERE index_name = 'msi11') AS optical_msi11_mean_181_asof
    FROM optical_features_long
    GROUP BY cod_cg_zafra
),
climate_seq AS (
    SELECT
        b.cod_cg_zafra,
        c.fecha_inicio::date AS clima_fecha_inicio,
        (c.fecha_inicio::date - b.fecha_inicio_ciclo)::double precision AS age_days,
        b.as_of_age_days,
        CASE
            WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 0 AND 90 THEN 'age_000_090'
            WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 91 AND 180 THEN 'age_091_180'
            WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 181 AND b.as_of_age_days THEN 'age_181_asof'
            ELSE 'outside'
        END AS age_window,
        CASE
            WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) >= greatest(0.0, b.as_of_age_days - 30.0) THEN true
            ELSE false
        END AS in_last_30d,
        CASE
            WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) >= greatest(0.0, b.as_of_age_days - 60.0) THEN true
            ELSE false
        END AS in_last_60d,
        NULLIF(c.precipitacion_sum::text, 'NaN')::double precision AS precip,
        NULLIF(c.eto_sum::text, 'NaN')::double precision AS eto,
        NULLIF(c.radiacion_sum::text, 'NaN')::double precision AS rad,
        NULLIF(c.temperatura_mean::text, 'NaN')::double precision AS tmean,
        NULLIF(c.temperatura_max::text, 'NaN')::double precision AS tmax,
        NULLIF(c.temperatura_min::text, 'NaN')::double precision AS tmin,
        NULLIF(c.humedad_relativa::text, 'NaN')::double precision AS rh,
        NULLIF(c.precipitacion_sum::text, 'NaN')::double precision
            - NULLIF(c.eto_sum::text, 'NaN')::double precision AS water_balance,
        greatest(NULLIF(c.temperatura_mean::text, 'NaN')::double precision - 10.0, 0.0) * 5.0 AS gdd_10c
    FROM eligible_cycles b
    LEFT JOIN climate_lote_lookup cl
      ON cl.cod_cg = b.cod_cg
    LEFT JOIN public.clima_lote_pentada_new c
      ON c.cod_cg = cl.climate_lote_matched
     AND c.fecha_inicio::date BETWEEN b.fecha_inicio_ciclo AND b.as_of_date
),
climate_core AS (
    SELECT
        cod_cg_zafra,
        count(clima_fecha_inicio)::double precision AS climate_pentad_count_0_asof,
        count(clima_fecha_inicio) FILTER (WHERE age_days BETWEEN 0 AND 180)::double precision AS climate_pentad_count_0_180,
        count(clima_fecha_inicio) FILTER (WHERE age_window = 'age_181_asof')::double precision AS climate_pentad_count_181_asof,
        sum(precip) AS climate_precip_acc_0_asof,
        sum(precip) FILTER (WHERE age_days BETWEEN 0 AND 180) AS climate_precip_acc_0_180,
        sum(precip) FILTER (WHERE age_window = 'age_181_asof') AS climate_precip_acc_181_asof,
        sum(precip) FILTER (WHERE in_last_30d) AS climate_precip_acc_last30,
        sum(precip) FILTER (WHERE in_last_60d) AS climate_precip_acc_last60,
        sum(eto) AS climate_eto_acc_0_asof,
        sum(eto) FILTER (WHERE age_days BETWEEN 0 AND 180) AS climate_eto_acc_0_180,
        sum(rad) AS climate_rad_acc_0_asof,
        sum(rad) FILTER (WHERE age_days BETWEEN 0 AND 180) AS climate_rad_acc_0_180,
        sum(water_balance) AS climate_water_balance_acc_0_asof,
        sum(water_balance) FILTER (WHERE age_days BETWEEN 0 AND 180) AS climate_water_balance_acc_0_180,
        sum(gdd_10c) AS climate_gdd_10c_acc_0_asof,
        sum(gdd_10c) FILTER (WHERE age_days BETWEEN 0 AND 180) AS climate_gdd_10c_acc_0_180,
        avg(tmean) AS climate_tmean_mean_0_asof,
        avg(tmax) AS climate_tmax_mean_0_asof,
        avg(tmin) AS climate_tmin_mean_0_asof,
        avg(rh) AS climate_rh_mean_0_asof,
        regr_slope(water_balance, age_days) AS climate_water_balance_slope_0_asof,
        regr_slope(precip, age_days) AS climate_precip_slope_0_asof,
        regr_slope(rad, age_days) AS climate_rad_slope_0_asof
    FROM climate_seq
    GROUP BY cod_cg_zafra
),
enso_core AS (
    SELECT
        b.cod_cg_zafra,
        count(e.date)::double precision AS enso_month_count_asof,
        avg(NULLIF(e.oni::text, 'NaN')::double precision) FILTER (
            WHERE e.date::date < b.fecha_inicio_ciclo
        ) AS enso_oni_precycle_mean,
        avg(NULLIF(e.oni::text, 'NaN')::double precision) FILTER (
            WHERE e.date::date >= b.fecha_inicio_ciclo
        ) AS enso_oni_asof_mean,
        max(abs(NULLIF(e.oni::text, 'NaN')::double precision)) AS enso_oni_abs_max_asof,
        avg(NULLIF(e.nino34::text, 'NaN')::double precision) FILTER (
            WHERE e.date::date < b.fecha_inicio_ciclo
        ) AS enso_nino34_precycle_mean,
        avg(NULLIF(e.nino34::text, 'NaN')::double precision) FILTER (
            WHERE e.date::date >= b.fecha_inicio_ciclo
        ) AS enso_nino34_asof_mean,
        avg(NULLIF(e.soi::text, 'NaN')::double precision) FILTER (
            WHERE e.date::date < b.fecha_inicio_ciclo
        ) AS enso_soi_precycle_mean,
        avg(NULLIF(e.soi::text, 'NaN')::double precision) FILTER (
            WHERE e.date::date >= b.fecha_inicio_ciclo
        ) AS enso_soi_asof_mean
    FROM eligible_cycles b
    LEFT JOIN public.enso e
      ON e.date::date >= b.fecha_inicio_ciclo - INTERVAL '180 days'
     AND e.date::date <= b.as_of_date
    GROUP BY b.cod_cg_zafra
),
quality_flags AS (
    SELECT
        b.cod_cg_zafra,
        COALESCE(o.optical_obs_count_0_180, 0) >= 7 AS asof_optical_obs_ok,
        COALESCE(o.optical_boundary_max_gap_days_0_180, 9999) <= 60 AS asof_optical_gap_ok,
        COALESCE(c.climate_pentad_count_0_180, 0) >= 30 AS asof_climate_coverage_ok,
        b.cycle_duration_days BETWEEN 180 AND (14.0 * 30.44) AS asof_cycle_duration_ok,
        (
            o.optical_ndvi_peak_0_180 > 0.60
            AND o.optical_ndvi_amplitude_0_180 > 0.40
        ) AS asof_ndvi_shape_ok,
        (
            o.optical_obs_count_0_180 >= 7
            AND COALESCE(o.optical_boundary_max_gap_days_0_180, 9999) <= 60
            AND COALESCE(c.climate_pentad_count_0_180, 0) >= 30
            AND b.cycle_duration_days BETWEEN 180 AND (14.0 * 30.44)
        ) AS asof_valid
    FROM eligible_cycles b
    LEFT JOIN optical_core o USING (cod_cg_zafra)
    LEFT JOIN climate_core c USING (cod_cg_zafra)
)
SELECT
    b.cod_cg_zafra,
    b.cod_cg,
    b.zafra_norm,
    b.dataset_role,
    b.cycle_status,
    b.has_target_tch,
    b.area,
    b.tch,
    b.tc,
    b.fecha_inicio_ciclo,
    b.fecha_inicio_baseline,
    b.fecha_cierre_real,
    b.fecha_cierre_estimada,
    b.fecha_fin_ciclo,
    b.as_of_date,
    b.as_of_age_days,
    b.min_prediction_age_days,
    b.max_prediction_age_days,
    b.cycle_duration_days,
    b.start_rule,
    b.start_correction_days,
    b.zafra_assignment_method,
    b.cod_cg_zafra_original,
    b.zafra_norm_original,
    b.previous_zafra_norm,
    b.previous_fecha_inicio_ciclo,
    b.previous_fecha_cierre,
    b.previous_tch,
    b.previous_tc,
    b.prod_edad_meses,

    b.prod_ingenio,
    b.prod_grupo_de_suelo,
    b.prod_grupo_de_humedad,
    b.prod_codigo_zae,
    b.prod_familia_de_suelo,
    b.prod_variedad,
    b.prod_no_corte,

    sl.stac_lote_matched,
    sl.stac_lote_match_method,
    cl.climate_lote_matched,
    cl.climate_lote_match_method,

    q.asof_valid,
    q.asof_optical_obs_ok,
    q.asof_optical_gap_ok,
    q.asof_climate_coverage_ok,
    q.asof_cycle_duration_ok,
    q.asof_ndvi_shape_ok,

    o.optical_obs_count_0_180,
    o.optical_obs_count_0_asof,
    o.optical_obs_count_181_asof,
    o.optical_obs_count_last30,
    o.optical_max_gap_days_0_180,
    o.optical_max_gap_days_0_asof,
    o.optical_boundary_max_gap_days_0_180,
    o.optical_ndvi_mean_0_180,
    o.optical_ndvi_mean_0_asof,
    o.optical_ndvi_mean_181_asof,
    o.optical_ndvi_mean_last30,
    o.optical_ndvi_mean_last60,
    o.optical_ndvi_peak_0_180,
    o.optical_ndvi_peak_0_asof,
    o.optical_ndvi_min_0_180,
    o.optical_ndvi_amplitude_0_180,
    o.optical_ndvi_amplitude_0_asof,
    o.optical_ndvi_slope_0_180,
    o.optical_ndvi_slope_0_asof,
    o.optical_ndvi_slope_181_asof,
    o.optical_ndvi_last_value_before_asof,
    o.optical_evi2_mean_0_180,
    o.optical_evi2_mean_0_asof,
    o.optical_evi2_mean_last30,
    o.optical_evi2_peak_0_asof,
    o.optical_evi2_slope_0_asof,
    o.optical_gndvi_mean_0_180,
    o.optical_gndvi_mean_0_asof,
    o.optical_gndvi_mean_last30,
    o.optical_gndvi_peak_0_asof,
    o.optical_gndvi_slope_0_asof,
    o.optical_ndre_mean_0_180,
    o.optical_ndre_mean_0_asof,
    o.optical_ndre_mean_181_asof,
    o.optical_ndre_mean_last30,
    o.optical_ndre_peak_0_asof,
    o.optical_ndre_slope_0_asof,
    o.optical_lswi_mean_0_asof,
    o.optical_lswi_mean_181_asof,
    o.optical_lswi_mean_last30,
    o.optical_ndvire_mean_0_asof,
    o.optical_ndvire_mean_181_asof,
    o.optical_cire_mean_0_asof,
    o.optical_cire_mean_181_asof,
    o.optical_ndwi11_mean_0_asof,
    o.optical_ndwi11_mean_181_asof,
    o.optical_msi11_mean_0_asof,
    o.optical_msi11_mean_181_asof,

    c.climate_pentad_count_0_asof,
    c.climate_pentad_count_0_180,
    c.climate_pentad_count_181_asof,
    c.climate_precip_acc_0_asof,
    c.climate_precip_acc_0_180,
    c.climate_precip_acc_181_asof,
    c.climate_precip_acc_last30,
    c.climate_precip_acc_last60,
    c.climate_eto_acc_0_asof,
    c.climate_eto_acc_0_180,
    c.climate_rad_acc_0_asof,
    c.climate_rad_acc_0_180,
    c.climate_water_balance_acc_0_asof,
    c.climate_water_balance_acc_0_180,
    c.climate_gdd_10c_acc_0_asof,
    c.climate_gdd_10c_acc_0_180,
    CASE WHEN b.as_of_age_days > 0 THEN c.climate_precip_acc_0_asof / b.as_of_age_days END AS climate_precip_per_day_0_asof,
    CASE WHEN b.as_of_age_days > 0 THEN c.climate_eto_acc_0_asof / b.as_of_age_days END AS climate_eto_per_day_0_asof,
    CASE WHEN b.as_of_age_days > 0 THEN c.climate_rad_acc_0_asof / b.as_of_age_days END AS climate_rad_per_day_0_asof,
    CASE WHEN b.as_of_age_days > 0 THEN c.climate_water_balance_acc_0_asof / b.as_of_age_days END AS climate_water_balance_per_day_0_asof,
    CASE WHEN b.as_of_age_days > 0 THEN c.climate_gdd_10c_acc_0_asof / b.as_of_age_days END AS climate_gdd_10c_per_day_0_asof,
    c.climate_tmean_mean_0_asof,
    c.climate_tmax_mean_0_asof,
    c.climate_tmin_mean_0_asof,
    c.climate_rh_mean_0_asof,
    c.climate_water_balance_slope_0_asof,
    c.climate_precip_slope_0_asof,
    c.climate_rad_slope_0_asof,

    e.enso_month_count_asof,
    e.enso_oni_precycle_mean,
    e.enso_oni_asof_mean,
    e.enso_oni_abs_max_asof,
    e.enso_nino34_precycle_mean,
    e.enso_nino34_asof_mean,
    e.enso_soi_precycle_mean,
    e.enso_soi_asof_mean
FROM eligible_cycles b
LEFT JOIN stac_lote_lookup sl
  ON sl.cod_cg = b.cod_cg
LEFT JOIN climate_lote_lookup cl
  ON cl.cod_cg = b.cod_cg
LEFT JOIN optical_core o USING (cod_cg_zafra)
LEFT JOIN climate_core c USING (cod_cg_zafra)
LEFT JOIN enso_core e USING (cod_cg_zafra)
LEFT JOIN quality_flags q USING (cod_cg_zafra);
