-- tch_features_v4_pseudoseq_core_no_radar_light_pruned.sql
--
-- Light-pruned pseudo-sequential/tabular feature table.
--
-- Shape: one row per valid cod_cg_zafra.
-- Sources included: agronomy core, climate core, optical core, ENSO core.
-- Sources intentionally excluded: radar core and all ablation blocks.
-- Light pruning removes constant or redundant coverage/age columns identified
-- by diagnostics-only job tch-tch-features-v4-pseudoseq-core--diagnostics-20260519-151140.
--
-- This query is self-contained for sagemaker/jobs/upload_dataset.py.

WITH
agronomy_core AS (
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
    FROM base_cycles
),
climate_core AS (
    -- tch_climate_core_v4.sql
    --
    -- Climate core feature block for the pseudo-sequential/tabular TCH strategy.
    --
    -- Shape:
    --   one row per valid cod_cg_zafra
    --
    -- Intent:
    --   Keep climate engineering physiologically meaningful and phase-aware:
    --   coverage, water supply/deficit, energy/thermal accumulation, stress, and
    --   a compact set of temporal trend features.
    --
    -- Source rules:
    --   - public.tch_raw_longitudinal_v4 supplies validated cycle bounds, target,
    --     and model metadata.
    --   - public.clima_lote_pentada_new supplies the direct pentadal climate
    --     sequence. Do not sample climate from the optical-date spine.
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
    climate_seq AS (
        SELECT
            b.cod_cg_zafra,
            b.cod_cg,
            b.zafra_norm,
            b.fecha_inicio_ciclo,
            b.fecha_fin_ciclo,
            b.cycle_age_max,
            c.fecha_inicio::date AS clima_fecha_inicio,
            c.fecha_fin::date AS clima_fecha_fin,
            (c.fecha_inicio::date - b.fecha_inicio_ciclo)::double precision AS edad_dias,
            (b.fecha_fin_ciclo - c.fecha_inicio::date)::double precision AS days_to_harvest,
            CASE
                WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 0 AND 120 THEN 'early'
                WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 121 AND 240 THEN 'mid'
                WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) >= 241 THEN 'late'
                ELSE 'outside'
            END AS age_phase,

            NULLIF(c.precipitacion_sum::text, 'NaN')::double precision AS precip,
            NULLIF(c.eto_sum::text, 'NaN')::double precision AS eto,
            NULLIF(c.temperatura_max::text, 'NaN')::double precision AS tmax,
            NULLIF(c.temperatura_min::text, 'NaN')::double precision AS tmin,
            NULLIF(c.temperatura_mean::text, 'NaN')::double precision AS tmean,
            NULLIF(c.humedad_relativa::text, 'NaN')::double precision AS rh,
            NULLIF(c.radiacion_sum::text, 'NaN')::double precision AS rad,

            NULLIF(c.precipitacion_sum::text, 'NaN')::double precision
                - NULLIF(c.eto_sum::text, 'NaN')::double precision AS water_balance,
            CASE
                WHEN NULLIF(c.eto_sum::text, 'NaN')::double precision > 0
                THEN NULLIF(c.precipitacion_sum::text, 'NaN')::double precision
                    / NULLIF(c.eto_sum::text, 'NaN')::double precision
                ELSE NULL
            END AS water_ratio,
            greatest(NULLIF(c.temperatura_mean::text, 'NaN')::double precision - 10.0, 0.0) * 5.0 AS gdd_10c,
            CASE
                WHEN NULLIF(c.precipitacion_sum::text, 'NaN')::double precision IS NULL
                  OR NULLIF(c.eto_sum::text, 'NaN')::double precision IS NULL THEN NULL
                WHEN NULLIF(c.precipitacion_sum::text, 'NaN')::double precision
                   < NULLIF(c.eto_sum::text, 'NaN')::double precision THEN 1.0
                ELSE 0.0
            END AS dry_pentad,
            CASE
                WHEN NULLIF(c.temperatura_max::text, 'NaN')::double precision IS NULL THEN NULL
                WHEN NULLIF(c.temperatura_max::text, 'NaN')::double precision >= 34.0 THEN 1.0
                ELSE 0.0
            END AS heat_pentad
        FROM base_cycles b
        LEFT JOIN public.clima_lote_pentada_new c
          ON c.cod_cg = b.cod_cg
         AND c.fecha_inicio::date BETWEEN b.fecha_inicio_ciclo AND b.fecha_fin_ciclo
    ),
    climate_gaps AS (
        WITH ordered AS (
            SELECT
                cod_cg_zafra,
                clima_fecha_inicio,
                clima_fecha_inicio
                    - lag(clima_fecha_inicio) OVER (
                        PARTITION BY cod_cg_zafra
                        ORDER BY clima_fecha_inicio
                    ) AS gap_days
            FROM climate_seq
            WHERE clima_fecha_inicio IS NOT NULL
        )
        SELECT
            cod_cg_zafra,
            max(gap_days)::double precision AS max_climate_gap_days,
            avg(gap_days)::double precision AS avg_climate_gap_days
        FROM ordered
        GROUP BY cod_cg_zafra
    ),
    dry_spells AS (
        WITH flags AS (
            SELECT
                cod_cg_zafra,
                age_phase,
                clima_fecha_inicio,
                dry_pentad,
                row_number() OVER (
                    PARTITION BY cod_cg_zafra
                    ORDER BY clima_fecha_inicio
                ) AS rn_all,
                row_number() OVER (
                    PARTITION BY cod_cg_zafra, dry_pentad
                    ORDER BY clima_fecha_inicio
                ) AS rn_flag
            FROM climate_seq
            WHERE clima_fecha_inicio IS NOT NULL
        ),
        runs AS (
            SELECT
                cod_cg_zafra,
                age_phase,
                dry_pentad,
                rn_all - rn_flag AS run_id,
                count(*) AS run_len
            FROM flags
            GROUP BY cod_cg_zafra, age_phase, dry_pentad, rn_all - rn_flag
        )
        SELECT
            cod_cg_zafra,
            max(run_len) FILTER (WHERE dry_pentad = 1.0)::double precision AS longest_dry_spell_full,
            max(run_len) FILTER (WHERE dry_pentad = 1.0 AND age_phase = 'early')::double precision AS longest_dry_spell_early,
            max(run_len) FILTER (WHERE dry_pentad = 1.0 AND age_phase = 'mid')::double precision AS longest_dry_spell_mid,
            max(run_len) FILTER (WHERE dry_pentad = 1.0 AND age_phase = 'late')::double precision AS longest_dry_spell_late
        FROM runs
        GROUP BY cod_cg_zafra
    ),
    phase_core AS (
        SELECT
            cod_cg_zafra,

            count(clima_fecha_inicio)::double precision AS climate_pentad_count_full,
            count(clima_fecha_inicio) FILTER (WHERE age_phase = 'early')::double precision AS climate_pentad_count_early,
            count(clima_fecha_inicio) FILTER (WHERE age_phase = 'mid')::double precision AS climate_pentad_count_mid,
            count(clima_fecha_inicio) FILTER (WHERE age_phase = 'late')::double precision AS climate_pentad_count_late,

            sum(precip) AS climate_precip_full_acc,
            sum(precip) FILTER (WHERE age_phase = 'early') AS climate_precip_early_acc,
            sum(precip) FILTER (WHERE age_phase = 'mid') AS climate_precip_mid_acc,
            sum(precip) FILTER (WHERE age_phase = 'late') AS climate_precip_late_acc,

            sum(eto) AS climate_eto_full_acc,
            sum(eto) FILTER (WHERE age_phase = 'early') AS climate_eto_early_acc,
            sum(eto) FILTER (WHERE age_phase = 'mid') AS climate_eto_mid_acc,
            sum(eto) FILTER (WHERE age_phase = 'late') AS climate_eto_late_acc,

            sum(water_balance) AS climate_water_balance_full_acc,
            sum(water_balance) FILTER (WHERE age_phase = 'early') AS climate_water_balance_early_acc,
            sum(water_balance) FILTER (WHERE age_phase = 'mid') AS climate_water_balance_mid_acc,
            sum(water_balance) FILTER (WHERE age_phase = 'late') AS climate_water_balance_late_acc,

            sum(precip) / NULLIF(sum(eto), 0) AS climate_water_ratio_full,
            sum(precip) FILTER (WHERE age_phase = 'early')
                / NULLIF(sum(eto) FILTER (WHERE age_phase = 'early'), 0) AS climate_water_ratio_early,
            sum(precip) FILTER (WHERE age_phase = 'mid')
                / NULLIF(sum(eto) FILTER (WHERE age_phase = 'mid'), 0) AS climate_water_ratio_mid,
            sum(precip) FILTER (WHERE age_phase = 'late')
                / NULLIF(sum(eto) FILTER (WHERE age_phase = 'late'), 0) AS climate_water_ratio_late,

            sum(rad) AS climate_rad_full_acc,
            sum(rad) FILTER (WHERE age_phase = 'early') AS climate_rad_early_acc,
            sum(rad) FILTER (WHERE age_phase = 'mid') AS climate_rad_mid_acc,
            sum(rad) FILTER (WHERE age_phase = 'late') AS climate_rad_late_acc,

            sum(gdd_10c) AS climate_gdd_full_acc,
            sum(gdd_10c) FILTER (WHERE age_phase = 'early') AS climate_gdd_early_acc,
            sum(gdd_10c) FILTER (WHERE age_phase = 'mid') AS climate_gdd_mid_acc,
            sum(gdd_10c) FILTER (WHERE age_phase = 'late') AS climate_gdd_late_acc,

            avg(tmean) AS climate_tmean_full_mean,
            avg(tmean) FILTER (WHERE age_phase = 'early') AS climate_tmean_early_mean,
            avg(tmean) FILTER (WHERE age_phase = 'mid') AS climate_tmean_mid_mean,
            avg(tmean) FILTER (WHERE age_phase = 'late') AS climate_tmean_late_mean,

            avg(tmax) AS climate_tmax_full_mean,
            avg(tmax) FILTER (WHERE age_phase = 'early') AS climate_tmax_early_mean,
            avg(tmax) FILTER (WHERE age_phase = 'mid') AS climate_tmax_mid_mean,
            avg(tmax) FILTER (WHERE age_phase = 'late') AS climate_tmax_late_mean,

            avg(tmin) AS climate_tmin_full_mean,
            avg(tmin) FILTER (WHERE age_phase = 'early') AS climate_tmin_early_mean,
            avg(tmin) FILTER (WHERE age_phase = 'mid') AS climate_tmin_mid_mean,
            avg(tmin) FILTER (WHERE age_phase = 'late') AS climate_tmin_late_mean,

            avg(rh) AS climate_rh_full_mean,
            avg(rh) FILTER (WHERE age_phase = 'early') AS climate_rh_early_mean,
            avg(rh) FILTER (WHERE age_phase = 'mid') AS climate_rh_mid_mean,
            avg(rh) FILTER (WHERE age_phase = 'late') AS climate_rh_late_mean,

            sum(dry_pentad) AS climate_dry_pentad_count_full,
            sum(dry_pentad) FILTER (WHERE age_phase = 'early') AS climate_dry_pentad_count_early,
            sum(dry_pentad) FILTER (WHERE age_phase = 'mid') AS climate_dry_pentad_count_mid,
            sum(dry_pentad) FILTER (WHERE age_phase = 'late') AS climate_dry_pentad_count_late,
            avg(dry_pentad) AS climate_dry_fraction_full,
            avg(dry_pentad) FILTER (WHERE age_phase = 'early') AS climate_dry_fraction_early,
            avg(dry_pentad) FILTER (WHERE age_phase = 'mid') AS climate_dry_fraction_mid,
            avg(dry_pentad) FILTER (WHERE age_phase = 'late') AS climate_dry_fraction_late,

            sum(heat_pentad) AS climate_heat_pentad_count_full,
            sum(heat_pentad) FILTER (WHERE age_phase = 'early') AS climate_heat_pentad_count_early,
            sum(heat_pentad) FILTER (WHERE age_phase = 'mid') AS climate_heat_pentad_count_mid,
            sum(heat_pentad) FILTER (WHERE age_phase = 'late') AS climate_heat_pentad_count_late,

            regr_slope(water_balance, edad_dias) AS climate_water_balance_cycle_slope,
            regr_slope(precip, edad_dias) AS climate_precip_cycle_slope,
            regr_slope(rad, edad_dias) AS climate_rad_cycle_slope,
            regr_slope(tmean, edad_dias) AS climate_tmean_cycle_slope
        FROM climate_seq
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

        p.climate_pentad_count_full,
        p.climate_pentad_count_early,
        p.climate_pentad_count_mid,
        p.climate_pentad_count_late,
        g.max_climate_gap_days,
        g.avg_climate_gap_days,

        p.climate_precip_full_acc,
        p.climate_precip_early_acc,
        p.climate_precip_mid_acc,
        p.climate_precip_late_acc,
        p.climate_eto_full_acc,
        p.climate_eto_early_acc,
        p.climate_eto_mid_acc,
        p.climate_eto_late_acc,
        p.climate_water_balance_full_acc,
        p.climate_water_balance_early_acc,
        p.climate_water_balance_mid_acc,
        p.climate_water_balance_late_acc,
        p.climate_water_ratio_full,
        p.climate_water_ratio_early,
        p.climate_water_ratio_mid,
        p.climate_water_ratio_late,

        p.climate_rad_full_acc,
        p.climate_rad_early_acc,
        p.climate_rad_mid_acc,
        p.climate_rad_late_acc,
        p.climate_gdd_full_acc,
        p.climate_gdd_early_acc,
        p.climate_gdd_mid_acc,
        p.climate_gdd_late_acc,
        p.climate_tmean_full_mean,
        p.climate_tmean_early_mean,
        p.climate_tmean_mid_mean,
        p.climate_tmean_late_mean,
        p.climate_tmax_full_mean,
        p.climate_tmax_early_mean,
        p.climate_tmax_mid_mean,
        p.climate_tmax_late_mean,
        p.climate_tmin_full_mean,
        p.climate_tmin_early_mean,
        p.climate_tmin_mid_mean,
        p.climate_tmin_late_mean,
        p.climate_rh_full_mean,
        p.climate_rh_early_mean,
        p.climate_rh_mid_mean,
        p.climate_rh_late_mean,

        p.climate_dry_pentad_count_full,
        p.climate_dry_pentad_count_early,
        p.climate_dry_pentad_count_mid,
        p.climate_dry_pentad_count_late,
        p.climate_dry_fraction_full,
        p.climate_dry_fraction_early,
        p.climate_dry_fraction_mid,
        p.climate_dry_fraction_late,
        p.climate_heat_pentad_count_full,
        p.climate_heat_pentad_count_early,
        p.climate_heat_pentad_count_mid,
        p.climate_heat_pentad_count_late,
        coalesce(d.longest_dry_spell_full, 0.0) AS climate_longest_dry_spell_full,
        coalesce(d.longest_dry_spell_early, 0.0) AS climate_longest_dry_spell_early,
        coalesce(d.longest_dry_spell_mid, 0.0) AS climate_longest_dry_spell_mid,
        coalesce(d.longest_dry_spell_late, 0.0) AS climate_longest_dry_spell_late,

        p.climate_water_balance_cycle_slope,
        p.climate_precip_cycle_slope,
        p.climate_rad_cycle_slope,
        p.climate_tmean_cycle_slope,
        p.climate_precip_mid_acc - p.climate_precip_early_acc AS climate_precip_mid_minus_early_acc,
        p.climate_precip_late_acc - p.climate_precip_mid_acc AS climate_precip_late_minus_mid_acc,
        p.climate_water_balance_mid_acc - p.climate_water_balance_early_acc AS climate_water_balance_mid_minus_early_acc,
        p.climate_water_balance_late_acc - p.climate_water_balance_mid_acc AS climate_water_balance_late_minus_mid_acc,
        p.climate_rad_mid_acc - p.climate_rad_early_acc AS climate_rad_mid_minus_early_acc,
        p.climate_rad_late_acc - p.climate_rad_mid_acc AS climate_rad_late_minus_mid_acc,
        p.climate_dry_fraction_late - p.climate_dry_fraction_early AS climate_dry_fraction_late_minus_early
    FROM base_cycles b
    LEFT JOIN phase_core p USING (cod_cg_zafra)
    LEFT JOIN climate_gaps g USING (cod_cg_zafra)
    LEFT JOIN dry_spells d USING (cod_cg_zafra)
),
optical_core AS (
    -- tch_optical_core_v4.sql
    --
    -- Optical STAC core feature block for the pseudo-sequential/tabular TCH strategy.
    --
    -- Shape:
    --   one row per valid cod_cg_zafra
    --
    -- Intent:
    --   Preserve crop-response temporal structure with compact phenology and
    --   trajectory features instead of raw temporal bins or blind statistics.
    --
    -- Source rules:
    --   - public.tch_raw_longitudinal_v4 supplies validated cycle bounds, target,
    --     model metadata, and in-window STAC observations.
    --   - Core optical indices are NDVI, EVI2, GNDVI, NDRE, and LSWI.
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
            count(*) AS optical_raw_obs_count,
            count(r.stac_ndvi_promedio) AS optical_ndvi_obs_count
        FROM public.tch_raw_longitudinal_v4 r
        WHERE r.tch IS NOT NULL
          AND r.tch BETWEEN 20 AND 150
          AND r.ciclo_valido = true
          AND r.cod_cg_zafra IS NOT NULL
          AND r.edad_de_cultivo IS NOT NULL
        GROUP BY r.cod_cg_zafra
    ),
    optical_long AS (
        SELECT
            b.cod_cg_zafra,
            b.zafra_norm,
            b.cycle_age_max,
            r.fecha_stac::date AS fecha_obs,
            r.edad_de_cultivo::double precision AS age_days,
            (b.fecha_fin_ciclo - r.fecha_stac::date)::double precision AS days_to_harvest,
            CASE
                WHEN r.edad_de_cultivo BETWEEN 0 AND 120 THEN 'early'
                WHEN r.edad_de_cultivo BETWEEN 121 AND 240 THEN 'mid'
                WHEN r.edad_de_cultivo >= 241 THEN 'late'
                ELSE 'outside'
            END AS age_phase,
            v.index_name,
            v.index_value
        FROM base_cycles b
        JOIN public.tch_raw_longitudinal_v4 r USING (cod_cg_zafra)
        CROSS JOIN LATERAL (
            VALUES
                ('ndvi', NULLIF(r.stac_ndvi_promedio::text, 'NaN')::double precision),
                ('evi2', NULLIF(r.stac_evi2_promedio::text, 'NaN')::double precision),
                ('gndvi', NULLIF(r.stac_gndvi_promedio::text, 'NaN')::double precision),
                ('ndre', NULLIF(r.stac_ndre_promedio::text, 'NaN')::double precision),
                ('lswi', NULLIF(r.stac_lswi_promedio::text, 'NaN')::double precision)
        ) AS v(index_name, index_value)
        WHERE r.ciclo_valido = true
          AND r.edad_de_cultivo IS NOT NULL
    ),
    optical_weighted AS (
        SELECT
            *,
            lag(age_days) OVER (
                PARTITION BY cod_cg_zafra, index_name
                ORDER BY age_days, fecha_obs
            ) AS prev_age,
            lead(age_days) OVER (
                PARTITION BY cod_cg_zafra, index_name
                ORDER BY age_days, fecha_obs
            ) AS next_age,
            max(index_value) OVER (
                PARTITION BY cod_cg_zafra, index_name
            ) AS peak_value_window
        FROM optical_long
    ),
    prepared AS (
        SELECT
            *,
            greatest(0.0, coalesce((prev_age + age_days) / 2.0, age_days - 7.5)) AS obs_start_age,
            least(cycle_age_max, coalesce((age_days + next_age) / 2.0, age_days + 7.5)) AS obs_end_age
        FROM optical_weighted
    ),
    features_long AS (
        SELECT
            cod_cg_zafra,
            index_name,

            count(index_value)::double precision AS obs_count,
            min(age_days) FILTER (WHERE index_value IS NOT NULL) AS first_obs_age,
            max(age_days) FILTER (WHERE index_value IS NOT NULL) AS last_obs_age,
            max(age_days) FILTER (WHERE index_value IS NOT NULL)
                - min(age_days) FILTER (WHERE index_value IS NOT NULL) AS observed_age_span,
            max(age_days - prev_age) FILTER (WHERE index_value IS NOT NULL) AS max_gap_days,

            avg(index_value) AS full_mean,
            avg(index_value) FILTER (WHERE age_phase = 'early') AS early_mean,
            avg(index_value) FILTER (WHERE age_phase = 'mid') AS mid_mean,
            avg(index_value) FILTER (WHERE age_phase = 'late') AS late_mean,
            max(index_value) AS peak_value,
            min(index_value) AS min_value,
            max(index_value) - min(index_value) AS amplitude,
            (array_agg(age_days ORDER BY index_value DESC NULLS LAST, age_days)
                FILTER (WHERE index_value IS NOT NULL))[1] AS age_at_peak,

            sum(index_value * greatest(0.0, obs_end_age - obs_start_age)) AS auc_full,
            sum(index_value * greatest(0.0, least(obs_end_age, 120.0) - greatest(obs_start_age, 0.0))) AS auc_early,
            sum(index_value * greatest(0.0, least(obs_end_age, 240.0) - greatest(obs_start_age, 120.0))) AS auc_mid,
            sum(index_value * greatest(0.0, obs_end_age - greatest(obs_start_age, 240.0))) AS auc_late,

            regr_slope(index_value, age_days) FILTER (WHERE age_days < 240) AS rise_slope,
            regr_slope(index_value, age_days) FILTER (WHERE age_days >= 240) AS late_slope,
            sum(greatest(0.0, obs_end_age - obs_start_age))
                FILTER (WHERE index_value >= 0.8 * peak_value_window) AS duration_above_80pct_peak
        FROM prepared
        GROUP BY cod_cg_zafra, index_name
    ),
    features_with_derived AS (
        SELECT
            f.*,
            f.mid_mean - f.early_mean AS mid_minus_early_mean,
            f.late_mean - f.mid_mean AS late_minus_mid_mean,
            CASE
                WHEN b.cycle_age_max > 0 THEN f.age_at_peak / b.cycle_age_max
                ELSE NULL
            END AS rel_age_at_peak
        FROM features_long f
        JOIN base_cycles b USING (cod_cg_zafra)
    ),
    features_wide AS (
        SELECT
            cod_cg_zafra,

            max(obs_count) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_obs_count,
            max(first_obs_age) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_first_obs_age,
            max(last_obs_age) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_last_obs_age,
            max(observed_age_span) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_observed_age_span,
            max(max_gap_days) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_max_gap_days,
            max(full_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_full_mean,
            max(early_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_early_mean,
            max(mid_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mid_mean,
            max(late_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_late_mean,
            max(mid_minus_early_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_mid_minus_early_mean,
            max(late_minus_mid_mean) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_late_minus_mid_mean,
            max(peak_value) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_peak_value,
            max(min_value) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_min_value,
            max(amplitude) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_amplitude,
            max(age_at_peak) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_age_at_peak,
            max(rel_age_at_peak) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_rel_age_at_peak,
            max(auc_full) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_auc_full,
            max(auc_early) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_auc_early,
            max(auc_mid) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_auc_mid,
            max(auc_late) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_auc_late,
            max(rise_slope) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_rise_slope,
            max(late_slope) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_late_slope,
            max(duration_above_80pct_peak) FILTER (WHERE index_name = 'ndvi') AS optical_ndvi_duration_above_80pct_peak,

            max(obs_count) FILTER (WHERE index_name = 'evi2') AS optical_evi2_obs_count,
            max(full_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_full_mean,
            max(early_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_early_mean,
            max(mid_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_mid_mean,
            max(late_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_late_mean,
            max(mid_minus_early_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_mid_minus_early_mean,
            max(late_minus_mid_mean) FILTER (WHERE index_name = 'evi2') AS optical_evi2_late_minus_mid_mean,
            max(peak_value) FILTER (WHERE index_name = 'evi2') AS optical_evi2_peak_value,
            max(min_value) FILTER (WHERE index_name = 'evi2') AS optical_evi2_min_value,
            max(amplitude) FILTER (WHERE index_name = 'evi2') AS optical_evi2_amplitude,
            max(age_at_peak) FILTER (WHERE index_name = 'evi2') AS optical_evi2_age_at_peak,
            max(rel_age_at_peak) FILTER (WHERE index_name = 'evi2') AS optical_evi2_rel_age_at_peak,
            max(auc_full) FILTER (WHERE index_name = 'evi2') AS optical_evi2_auc_full,
            max(auc_early) FILTER (WHERE index_name = 'evi2') AS optical_evi2_auc_early,
            max(auc_mid) FILTER (WHERE index_name = 'evi2') AS optical_evi2_auc_mid,
            max(auc_late) FILTER (WHERE index_name = 'evi2') AS optical_evi2_auc_late,
            max(rise_slope) FILTER (WHERE index_name = 'evi2') AS optical_evi2_rise_slope,
            max(late_slope) FILTER (WHERE index_name = 'evi2') AS optical_evi2_late_slope,
            max(duration_above_80pct_peak) FILTER (WHERE index_name = 'evi2') AS optical_evi2_duration_above_80pct_peak,

            max(obs_count) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_obs_count,
            max(full_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_full_mean,
            max(early_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_early_mean,
            max(mid_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_mid_mean,
            max(late_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_late_mean,
            max(mid_minus_early_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_mid_minus_early_mean,
            max(late_minus_mid_mean) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_late_minus_mid_mean,
            max(peak_value) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_peak_value,
            max(min_value) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_min_value,
            max(amplitude) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_amplitude,
            max(age_at_peak) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_age_at_peak,
            max(rel_age_at_peak) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_rel_age_at_peak,
            max(auc_full) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_auc_full,
            max(auc_early) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_auc_early,
            max(auc_mid) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_auc_mid,
            max(auc_late) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_auc_late,
            max(rise_slope) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_rise_slope,
            max(late_slope) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_late_slope,
            max(duration_above_80pct_peak) FILTER (WHERE index_name = 'gndvi') AS optical_gndvi_duration_above_80pct_peak,

            max(obs_count) FILTER (WHERE index_name = 'ndre') AS optical_ndre_obs_count,
            max(full_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_full_mean,
            max(early_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_early_mean,
            max(mid_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_mid_mean,
            max(late_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_late_mean,
            max(mid_minus_early_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_mid_minus_early_mean,
            max(late_minus_mid_mean) FILTER (WHERE index_name = 'ndre') AS optical_ndre_late_minus_mid_mean,
            max(peak_value) FILTER (WHERE index_name = 'ndre') AS optical_ndre_peak_value,
            max(min_value) FILTER (WHERE index_name = 'ndre') AS optical_ndre_min_value,
            max(amplitude) FILTER (WHERE index_name = 'ndre') AS optical_ndre_amplitude,
            max(age_at_peak) FILTER (WHERE index_name = 'ndre') AS optical_ndre_age_at_peak,
            max(rel_age_at_peak) FILTER (WHERE index_name = 'ndre') AS optical_ndre_rel_age_at_peak,
            max(auc_full) FILTER (WHERE index_name = 'ndre') AS optical_ndre_auc_full,
            max(auc_early) FILTER (WHERE index_name = 'ndre') AS optical_ndre_auc_early,
            max(auc_mid) FILTER (WHERE index_name = 'ndre') AS optical_ndre_auc_mid,
            max(auc_late) FILTER (WHERE index_name = 'ndre') AS optical_ndre_auc_late,
            max(rise_slope) FILTER (WHERE index_name = 'ndre') AS optical_ndre_rise_slope,
            max(late_slope) FILTER (WHERE index_name = 'ndre') AS optical_ndre_late_slope,
            max(duration_above_80pct_peak) FILTER (WHERE index_name = 'ndre') AS optical_ndre_duration_above_80pct_peak,

            max(obs_count) FILTER (WHERE index_name = 'lswi') AS optical_lswi_obs_count,
            max(full_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_full_mean,
            max(early_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_early_mean,
            max(mid_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_mid_mean,
            max(late_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_late_mean,
            max(mid_minus_early_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_mid_minus_early_mean,
            max(late_minus_mid_mean) FILTER (WHERE index_name = 'lswi') AS optical_lswi_late_minus_mid_mean,
            max(peak_value) FILTER (WHERE index_name = 'lswi') AS optical_lswi_peak_value,
            max(min_value) FILTER (WHERE index_name = 'lswi') AS optical_lswi_min_value,
            max(amplitude) FILTER (WHERE index_name = 'lswi') AS optical_lswi_amplitude,
            max(age_at_peak) FILTER (WHERE index_name = 'lswi') AS optical_lswi_age_at_peak,
            max(rel_age_at_peak) FILTER (WHERE index_name = 'lswi') AS optical_lswi_rel_age_at_peak,
            max(auc_full) FILTER (WHERE index_name = 'lswi') AS optical_lswi_auc_full,
            max(auc_early) FILTER (WHERE index_name = 'lswi') AS optical_lswi_auc_early,
            max(auc_mid) FILTER (WHERE index_name = 'lswi') AS optical_lswi_auc_mid,
            max(auc_late) FILTER (WHERE index_name = 'lswi') AS optical_lswi_auc_late,
            max(rise_slope) FILTER (WHERE index_name = 'lswi') AS optical_lswi_rise_slope,
            max(late_slope) FILTER (WHERE index_name = 'lswi') AS optical_lswi_late_slope,
            max(duration_above_80pct_peak) FILTER (WHERE index_name = 'lswi') AS optical_lswi_duration_above_80pct_peak
        FROM features_with_derived
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
        b.optical_raw_obs_count,
        b.optical_ndvi_obs_count AS optical_cycle_ndvi_obs_count,
        f.optical_ndvi_obs_count,
        f.optical_ndvi_first_obs_age,
        f.optical_ndvi_last_obs_age,
        f.optical_ndvi_observed_age_span,
        f.optical_ndvi_max_gap_days,
        f.optical_ndvi_full_mean,
        f.optical_ndvi_early_mean,
        f.optical_ndvi_mid_mean,
        f.optical_ndvi_late_mean,
        f.optical_ndvi_mid_minus_early_mean,
        f.optical_ndvi_late_minus_mid_mean,
        f.optical_ndvi_peak_value,
        f.optical_ndvi_min_value,
        f.optical_ndvi_amplitude,
        f.optical_ndvi_age_at_peak,
        f.optical_ndvi_rel_age_at_peak,
        f.optical_ndvi_auc_full,
        f.optical_ndvi_auc_early,
        f.optical_ndvi_auc_mid,
        f.optical_ndvi_auc_late,
        f.optical_ndvi_rise_slope,
        f.optical_ndvi_late_slope,
        f.optical_ndvi_duration_above_80pct_peak,
        f.optical_evi2_obs_count,
        f.optical_evi2_full_mean,
        f.optical_evi2_early_mean,
        f.optical_evi2_mid_mean,
        f.optical_evi2_late_mean,
        f.optical_evi2_mid_minus_early_mean,
        f.optical_evi2_late_minus_mid_mean,
        f.optical_evi2_peak_value,
        f.optical_evi2_min_value,
        f.optical_evi2_amplitude,
        f.optical_evi2_age_at_peak,
        f.optical_evi2_rel_age_at_peak,
        f.optical_evi2_auc_full,
        f.optical_evi2_auc_early,
        f.optical_evi2_auc_mid,
        f.optical_evi2_auc_late,
        f.optical_evi2_rise_slope,
        f.optical_evi2_late_slope,
        f.optical_evi2_duration_above_80pct_peak,
        f.optical_gndvi_obs_count,
        f.optical_gndvi_full_mean,
        f.optical_gndvi_early_mean,
        f.optical_gndvi_mid_mean,
        f.optical_gndvi_late_mean,
        f.optical_gndvi_mid_minus_early_mean,
        f.optical_gndvi_late_minus_mid_mean,
        f.optical_gndvi_peak_value,
        f.optical_gndvi_min_value,
        f.optical_gndvi_amplitude,
        f.optical_gndvi_age_at_peak,
        f.optical_gndvi_rel_age_at_peak,
        f.optical_gndvi_auc_full,
        f.optical_gndvi_auc_early,
        f.optical_gndvi_auc_mid,
        f.optical_gndvi_auc_late,
        f.optical_gndvi_rise_slope,
        f.optical_gndvi_late_slope,
        f.optical_gndvi_duration_above_80pct_peak,
        f.optical_ndre_obs_count,
        f.optical_ndre_full_mean,
        f.optical_ndre_early_mean,
        f.optical_ndre_mid_mean,
        f.optical_ndre_late_mean,
        f.optical_ndre_mid_minus_early_mean,
        f.optical_ndre_late_minus_mid_mean,
        f.optical_ndre_peak_value,
        f.optical_ndre_min_value,
        f.optical_ndre_amplitude,
        f.optical_ndre_age_at_peak,
        f.optical_ndre_rel_age_at_peak,
        f.optical_ndre_auc_full,
        f.optical_ndre_auc_early,
        f.optical_ndre_auc_mid,
        f.optical_ndre_auc_late,
        f.optical_ndre_rise_slope,
        f.optical_ndre_late_slope,
        f.optical_ndre_duration_above_80pct_peak,
        f.optical_lswi_obs_count,
        f.optical_lswi_full_mean,
        f.optical_lswi_early_mean,
        f.optical_lswi_mid_mean,
        f.optical_lswi_late_mean,
        f.optical_lswi_mid_minus_early_mean,
        f.optical_lswi_late_minus_mid_mean,
        f.optical_lswi_peak_value,
        f.optical_lswi_min_value,
        f.optical_lswi_amplitude,
        f.optical_lswi_age_at_peak,
        f.optical_lswi_rel_age_at_peak,
        f.optical_lswi_auc_full,
        f.optical_lswi_auc_early,
        f.optical_lswi_auc_mid,
        f.optical_lswi_auc_late,
        f.optical_lswi_rise_slope,
        f.optical_lswi_late_slope,
        f.optical_lswi_duration_above_80pct_peak
    FROM base_cycles b
    LEFT JOIN features_wide f USING (cod_cg_zafra)
),
enso_core AS (
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
    LEFT JOIN enso_features e USING (cod_cg_zafra)
)
SELECT
    a.cod_cg_zafra,
    a.cod_cg,
    a.zafra_norm,
    a.area,
    a.tch,
    a.tc,
    a.fecha_inicio_ciclo,
    a.fecha_fin_ciclo,
    a.cycle_age_max,
    a.prod_ingenio,
    a.prod_grupo_de_suelo,
    a.prod_grupo_de_humedad,
    a.prod_codigo_zae,
    a.prod_familia_de_suelo,
    a.prod_variedad,
    a.prod_no_corte,
    a.prod_cosecha,
    c.climate_pentad_count_full,
    c.climate_pentad_count_early,
    c.climate_pentad_count_mid,
    c.climate_pentad_count_late,
    c.avg_climate_gap_days,
    c.climate_precip_full_acc,
    c.climate_precip_early_acc,
    c.climate_precip_mid_acc,
    c.climate_precip_late_acc,
    c.climate_eto_full_acc,
    c.climate_eto_early_acc,
    c.climate_eto_mid_acc,
    c.climate_eto_late_acc,
    c.climate_water_balance_full_acc,
    c.climate_water_balance_early_acc,
    c.climate_water_balance_mid_acc,
    c.climate_water_balance_late_acc,
    c.climate_water_ratio_full,
    c.climate_water_ratio_early,
    c.climate_water_ratio_mid,
    c.climate_water_ratio_late,
    c.climate_rad_full_acc,
    c.climate_rad_early_acc,
    c.climate_rad_mid_acc,
    c.climate_rad_late_acc,
    c.climate_gdd_full_acc,
    c.climate_gdd_early_acc,
    c.climate_gdd_mid_acc,
    c.climate_gdd_late_acc,
    c.climate_tmean_full_mean,
    c.climate_tmean_early_mean,
    c.climate_tmean_mid_mean,
    c.climate_tmean_late_mean,
    c.climate_tmax_full_mean,
    c.climate_tmax_early_mean,
    c.climate_tmax_mid_mean,
    c.climate_tmax_late_mean,
    c.climate_tmin_full_mean,
    c.climate_tmin_early_mean,
    c.climate_tmin_mid_mean,
    c.climate_tmin_late_mean,
    c.climate_rh_full_mean,
    c.climate_rh_early_mean,
    c.climate_rh_mid_mean,
    c.climate_rh_late_mean,
    c.climate_dry_pentad_count_full,
    c.climate_dry_pentad_count_early,
    c.climate_dry_pentad_count_mid,
    c.climate_dry_pentad_count_late,
    c.climate_dry_fraction_full,
    c.climate_dry_fraction_early,
    c.climate_dry_fraction_mid,
    c.climate_dry_fraction_late,
    c.climate_heat_pentad_count_full,
    c.climate_heat_pentad_count_early,
    c.climate_heat_pentad_count_mid,
    c.climate_heat_pentad_count_late,
    c.climate_longest_dry_spell_full,
    c.climate_longest_dry_spell_early,
    c.climate_longest_dry_spell_mid,
    c.climate_longest_dry_spell_late,
    c.climate_water_balance_cycle_slope,
    c.climate_precip_cycle_slope,
    c.climate_rad_cycle_slope,
    c.climate_tmean_cycle_slope,
    c.climate_precip_mid_minus_early_acc,
    c.climate_precip_late_minus_mid_acc,
    c.climate_water_balance_mid_minus_early_acc,
    c.climate_water_balance_late_minus_mid_acc,
    c.climate_rad_mid_minus_early_acc,
    c.climate_rad_late_minus_mid_acc,
    c.climate_dry_fraction_late_minus_early,
    o.optical_raw_obs_count,
    o.optical_ndvi_first_obs_age,
    o.optical_ndvi_observed_age_span,
    o.optical_ndvi_max_gap_days,
    o.optical_ndvi_full_mean,
    o.optical_ndvi_early_mean,
    o.optical_ndvi_mid_mean,
    o.optical_ndvi_late_mean,
    o.optical_ndvi_mid_minus_early_mean,
    o.optical_ndvi_late_minus_mid_mean,
    o.optical_ndvi_peak_value,
    o.optical_ndvi_min_value,
    o.optical_ndvi_amplitude,
    o.optical_ndvi_age_at_peak,
    o.optical_ndvi_rel_age_at_peak,
    o.optical_ndvi_auc_full,
    o.optical_ndvi_auc_early,
    o.optical_ndvi_auc_mid,
    o.optical_ndvi_auc_late,
    o.optical_ndvi_rise_slope,
    o.optical_ndvi_late_slope,
    o.optical_ndvi_duration_above_80pct_peak,
    o.optical_evi2_full_mean,
    o.optical_evi2_early_mean,
    o.optical_evi2_mid_mean,
    o.optical_evi2_late_mean,
    o.optical_evi2_mid_minus_early_mean,
    o.optical_evi2_late_minus_mid_mean,
    o.optical_evi2_peak_value,
    o.optical_evi2_min_value,
    o.optical_evi2_amplitude,
    o.optical_evi2_age_at_peak,
    o.optical_evi2_rel_age_at_peak,
    o.optical_evi2_auc_full,
    o.optical_evi2_auc_early,
    o.optical_evi2_auc_mid,
    o.optical_evi2_auc_late,
    o.optical_evi2_rise_slope,
    o.optical_evi2_late_slope,
    o.optical_evi2_duration_above_80pct_peak,
    o.optical_gndvi_full_mean,
    o.optical_gndvi_early_mean,
    o.optical_gndvi_mid_mean,
    o.optical_gndvi_late_mean,
    o.optical_gndvi_mid_minus_early_mean,
    o.optical_gndvi_late_minus_mid_mean,
    o.optical_gndvi_peak_value,
    o.optical_gndvi_min_value,
    o.optical_gndvi_amplitude,
    o.optical_gndvi_age_at_peak,
    o.optical_gndvi_rel_age_at_peak,
    o.optical_gndvi_auc_full,
    o.optical_gndvi_auc_early,
    o.optical_gndvi_auc_mid,
    o.optical_gndvi_auc_late,
    o.optical_gndvi_rise_slope,
    o.optical_gndvi_late_slope,
    o.optical_gndvi_duration_above_80pct_peak,
    o.optical_ndre_full_mean,
    o.optical_ndre_early_mean,
    o.optical_ndre_mid_mean,
    o.optical_ndre_late_mean,
    o.optical_ndre_mid_minus_early_mean,
    o.optical_ndre_late_minus_mid_mean,
    o.optical_ndre_peak_value,
    o.optical_ndre_min_value,
    o.optical_ndre_amplitude,
    o.optical_ndre_age_at_peak,
    o.optical_ndre_rel_age_at_peak,
    o.optical_ndre_auc_full,
    o.optical_ndre_auc_early,
    o.optical_ndre_auc_mid,
    o.optical_ndre_auc_late,
    o.optical_ndre_rise_slope,
    o.optical_ndre_late_slope,
    o.optical_ndre_duration_above_80pct_peak,
    o.optical_lswi_full_mean,
    o.optical_lswi_early_mean,
    o.optical_lswi_mid_mean,
    o.optical_lswi_late_mean,
    o.optical_lswi_mid_minus_early_mean,
    o.optical_lswi_late_minus_mid_mean,
    o.optical_lswi_peak_value,
    o.optical_lswi_min_value,
    o.optical_lswi_amplitude,
    o.optical_lswi_age_at_peak,
    o.optical_lswi_rel_age_at_peak,
    o.optical_lswi_auc_full,
    o.optical_lswi_auc_early,
    o.optical_lswi_auc_mid,
    o.optical_lswi_auc_late,
    o.optical_lswi_rise_slope,
    o.optical_lswi_late_slope,
    o.optical_lswi_duration_above_80pct_peak,
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
FROM agronomy_core a
LEFT JOIN climate_core c USING (cod_cg_zafra)
LEFT JOIN optical_core o USING (cod_cg_zafra)
LEFT JOIN enso_core e USING (cod_cg_zafra);
