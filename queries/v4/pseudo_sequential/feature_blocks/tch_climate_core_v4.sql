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
LEFT JOIN dry_spells d USING (cod_cg_zafra);
