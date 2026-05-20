-- climate_pseudo_sequential_diagnostic_v4.sql
--
-- Diagnostic for deciding climate feature engineering for a pseudo-sequential
-- LightGBM-style dataset.
--
-- Goal:
--   Build evidence before choosing climate features. This script summarizes:
--     1) climate coverage and missingness by lot-zafra and zafra
--     2) candidate phase, harvest-window, lag/position, stress, and trend features
--     3) feature association with lot-level TCH
--     4) feature stability by zafra
--     5) climate signal conditioned by agronomic groups
--     6) climate coverage versus optical/SAR coverage already in the maestra
--
-- Source:
--   public.tch_raw_longitudinal_v4 for validated cycles, target, agronomy,
--   and optical/SAR coverage context.
--   public.clima_lote_pentada_new for direct pentadal climate sequences.
--
-- Notes:
--   - This is diagnostics, not final feature SQL.
--   - One row in feature_values = one candidate climate feature per cod_cg_zafra.
--   - TCH aggregation for harvest-season evaluation is handled elsewhere.

DROP TABLE IF EXISTS pg_temp.base_cycles;
CREATE TEMP TABLE base_cycles AS
SELECT
    r.cod_cg_zafra,
    r.cod_cg,
    r.zafra_norm,
    max(r.tch)::double precision AS tch,
    max(r.area)::double precision AS area,
    min(r.fecha_inicio_estimada)::date AS fecha_inicio_ciclo,
    max(r.fecha_fin_objetivo)::date AS fecha_fin_ciclo,
    max(r.edad_de_cultivo)::double precision AS cycle_age_max,
    bool_or(r.ciclo_valido) AS ciclo_valido,

    max(r.prod_variedad) AS prod_variedad,
    max(r.prod_no_corte) AS prod_no_corte,
    max(r.prod_grupo_de_suelo) AS prod_grupo_de_suelo,
    max(r.prod_grupo_de_humedad) AS prod_grupo_de_humedad,
    max(r.prod_codigo_zae) AS prod_codigo_zae,

    count(*) AS raw_obs_count,
    count(r.stac_ndvi_promedio) AS optical_ndvi_obs_count,
    count(r.stac_evi2_promedio) AS optical_evi2_obs_count,
    count(r.radar_asc_vv_promedio) AS radar_asc_vv_obs_count,
    count(r.radar_desc_vv_promedio) AS radar_desc_vv_obs_count,
    count(r.clima_precipitacion_sum) AS raw_joined_climate_obs_count
FROM public.tch_raw_longitudinal_v4 r
WHERE r.tch IS NOT NULL
  AND r.tch BETWEEN 20 AND 150
  AND r.ciclo_valido = true
  AND r.cod_cg_zafra IS NOT NULL
GROUP BY
    r.cod_cg_zafra,
    r.cod_cg,
    r.zafra_norm;

CREATE INDEX ON base_cycles (cod_cg_zafra);
CREATE INDEX ON base_cycles (cod_cg);
CREATE INDEX ON base_cycles (zafra_norm);

DROP TABLE IF EXISTS pg_temp.climate_seq;
CREATE TEMP TABLE climate_seq AS
SELECT
    b.cod_cg_zafra,
    b.cod_cg,
    b.zafra_norm,
    b.tch,
    b.area,
    b.fecha_inicio_ciclo,
    b.fecha_fin_ciclo,
    b.cycle_age_max,
    b.prod_variedad,
    b.prod_no_corte,
    b.prod_grupo_de_suelo,
    b.prod_grupo_de_humedad,
    b.prod_codigo_zae,

    c.fecha_inicio::date AS clima_fecha_inicio,
    c.fecha_fin::date AS clima_fecha_fin,
    c.anio AS clima_anio,
    c.mes AS clima_mes,
    c.num_pentada AS clima_num_pentada,

    (c.fecha_inicio::date - b.fecha_inicio_ciclo)::double precision AS edad_dias,
    (b.fecha_fin_ciclo - c.fecha_inicio::date)::double precision AS days_to_harvest,
    CASE
        WHEN b.cycle_age_max > 0
        THEN (c.fecha_inicio::date - b.fecha_inicio_ciclo)::double precision / b.cycle_age_max
        ELSE NULL
    END AS rel_cycle_pos,
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
    NULLIF(c.radiacion_mean::text, 'NaN')::double precision AS rad_mean,
    NULLIF(c.indice_calor_max::text, 'NaN')::double precision AS heat_index,
    NULLIF(c.mojadura_mean::text, 'NaN')::double precision AS mojadura,

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
    END AS heat_pentad,
    CASE
        WHEN NULLIF(c.radiacion_sum::text, 'NaN')::double precision IS NULL THEN NULL
        WHEN NULLIF(c.radiacion_sum::text, 'NaN')::double precision <= 60.0 THEN 1.0
        ELSE 0.0
    END AS low_rad_pentad
FROM base_cycles b
LEFT JOIN public.clima_lote_pentada_new c
  ON c.cod_cg = b.cod_cg
 AND c.fecha_inicio::date BETWEEN b.fecha_inicio_ciclo AND b.fecha_fin_ciclo;

CREATE INDEX ON climate_seq (cod_cg_zafra);
CREATE INDEX ON climate_seq (zafra_norm);
CREATE INDEX ON climate_seq (age_phase);
CREATE INDEX ON climate_seq (days_to_harvest);

DROP TABLE IF EXISTS pg_temp.climate_gaps;
CREATE TEMP TABLE climate_gaps AS
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
GROUP BY cod_cg_zafra;

DROP TABLE IF EXISTS pg_temp.dry_spells;
CREATE TEMP TABLE dry_spells AS
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
GROUP BY cod_cg_zafra;

DROP TABLE IF EXISTS pg_temp.candidate_features;
CREATE TEMP TABLE candidate_features AS
WITH agg AS (
    SELECT
        cod_cg_zafra,

        count(clima_fecha_inicio)::double precision AS climate_pentad_count_full,
        count(clima_fecha_inicio) FILTER (WHERE age_phase = 'early')::double precision AS climate_pentad_count_early,
        count(clima_fecha_inicio) FILTER (WHERE age_phase = 'mid')::double precision AS climate_pentad_count_mid,
        count(clima_fecha_inicio) FILTER (WHERE age_phase = 'late')::double precision AS climate_pentad_count_late,

        sum(precip) AS precip_full_acc,
        sum(precip) FILTER (WHERE age_phase = 'early') AS precip_early_acc,
        sum(precip) FILTER (WHERE age_phase = 'mid') AS precip_mid_acc,
        sum(precip) FILTER (WHERE age_phase = 'late') AS precip_late_acc,

        sum(eto) AS eto_full_acc,
        sum(eto) FILTER (WHERE age_phase = 'early') AS eto_early_acc,
        sum(eto) FILTER (WHERE age_phase = 'mid') AS eto_mid_acc,
        sum(eto) FILTER (WHERE age_phase = 'late') AS eto_late_acc,

        sum(water_balance) AS water_balance_full_acc,
        sum(water_balance) FILTER (WHERE age_phase = 'early') AS water_balance_early_acc,
        sum(water_balance) FILTER (WHERE age_phase = 'mid') AS water_balance_mid_acc,
        sum(water_balance) FILTER (WHERE age_phase = 'late') AS water_balance_late_acc,

        sum(precip) / NULLIF(sum(eto), 0) AS water_ratio_full,
        sum(precip) FILTER (WHERE age_phase = 'early')
            / NULLIF(sum(eto) FILTER (WHERE age_phase = 'early'), 0) AS water_ratio_early,
        sum(precip) FILTER (WHERE age_phase = 'mid')
            / NULLIF(sum(eto) FILTER (WHERE age_phase = 'mid'), 0) AS water_ratio_mid,
        sum(precip) FILTER (WHERE age_phase = 'late')
            / NULLIF(sum(eto) FILTER (WHERE age_phase = 'late'), 0) AS water_ratio_late,

        sum(rad) AS rad_full_acc,
        sum(rad) FILTER (WHERE age_phase = 'early') AS rad_early_acc,
        sum(rad) FILTER (WHERE age_phase = 'mid') AS rad_mid_acc,
        sum(rad) FILTER (WHERE age_phase = 'late') AS rad_late_acc,

        sum(gdd_10c) AS gdd_full_acc,
        sum(gdd_10c) FILTER (WHERE age_phase = 'early') AS gdd_early_acc,
        sum(gdd_10c) FILTER (WHERE age_phase = 'mid') AS gdd_mid_acc,
        sum(gdd_10c) FILTER (WHERE age_phase = 'late') AS gdd_late_acc,

        avg(tmean) AS tmean_full_mean,
        avg(tmean) FILTER (WHERE age_phase = 'early') AS tmean_early_mean,
        avg(tmean) FILTER (WHERE age_phase = 'mid') AS tmean_mid_mean,
        avg(tmean) FILTER (WHERE age_phase = 'late') AS tmean_late_mean,

        avg(tmax) AS tmax_full_mean,
        avg(tmax) FILTER (WHERE age_phase = 'early') AS tmax_early_mean,
        avg(tmax) FILTER (WHERE age_phase = 'mid') AS tmax_mid_mean,
        avg(tmax) FILTER (WHERE age_phase = 'late') AS tmax_late_mean,

        avg(tmin) AS tmin_full_mean,
        avg(tmin) FILTER (WHERE age_phase = 'early') AS tmin_early_mean,
        avg(tmin) FILTER (WHERE age_phase = 'mid') AS tmin_mid_mean,
        avg(tmin) FILTER (WHERE age_phase = 'late') AS tmin_late_mean,

        avg(rh) AS rh_full_mean,
        avg(rh) FILTER (WHERE age_phase = 'early') AS rh_early_mean,
        avg(rh) FILTER (WHERE age_phase = 'mid') AS rh_mid_mean,
        avg(rh) FILTER (WHERE age_phase = 'late') AS rh_late_mean,

        avg(mojadura) AS mojadura_full_mean,
        avg(heat_index) AS heat_index_full_mean,

        sum(dry_pentad) AS dry_pentad_count_full,
        sum(dry_pentad) FILTER (WHERE age_phase = 'early') AS dry_pentad_count_early,
        sum(dry_pentad) FILTER (WHERE age_phase = 'mid') AS dry_pentad_count_mid,
        sum(dry_pentad) FILTER (WHERE age_phase = 'late') AS dry_pentad_count_late,
        avg(dry_pentad) AS dry_fraction_full,
        avg(dry_pentad) FILTER (WHERE age_phase = 'early') AS dry_fraction_early,
        avg(dry_pentad) FILTER (WHERE age_phase = 'mid') AS dry_fraction_mid,
        avg(dry_pentad) FILTER (WHERE age_phase = 'late') AS dry_fraction_late,

        sum(heat_pentad) AS heat_pentad_count_full,
        sum(heat_pentad) FILTER (WHERE age_phase = 'early') AS heat_pentad_count_early,
        sum(heat_pentad) FILTER (WHERE age_phase = 'mid') AS heat_pentad_count_mid,
        sum(heat_pentad) FILTER (WHERE age_phase = 'late') AS heat_pentad_count_late,
        sum(low_rad_pentad) AS low_rad_pentad_count_full,

        regr_slope(water_balance, edad_dias) AS water_balance_cycle_slope,
        regr_slope(precip, edad_dias) AS precip_cycle_slope,
        regr_slope(rad, edad_dias) AS rad_cycle_slope,
        regr_slope(tmean, edad_dias) AS tmean_cycle_slope,

        sum(precip) FILTER (WHERE days_to_harvest BETWEEN 0 AND 30) AS precip_last_030_acc,
        sum(precip) FILTER (WHERE days_to_harvest BETWEEN 0 AND 60) AS precip_last_060_acc,
        sum(precip) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS precip_last_090_acc,
        sum(precip) FILTER (WHERE days_to_harvest BETWEEN 0 AND 120) AS precip_last_120_acc,

        sum(water_balance) FILTER (WHERE days_to_harvest BETWEEN 0 AND 30) AS water_balance_last_030_acc,
        sum(water_balance) FILTER (WHERE days_to_harvest BETWEEN 0 AND 60) AS water_balance_last_060_acc,
        sum(water_balance) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS water_balance_last_090_acc,
        sum(water_balance) FILTER (WHERE days_to_harvest BETWEEN 0 AND 120) AS water_balance_last_120_acc,

        sum(eto) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS eto_last_090_acc,
        sum(rad) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS rad_last_090_acc,
        sum(gdd_10c) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS gdd_last_090_acc,
        avg(tmean) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS tmean_last_090_mean,
        avg(rh) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS rh_last_090_mean,
        sum(dry_pentad) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS dry_pentad_last_090_count,
        sum(heat_pentad) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS heat_pentad_last_090_count
    FROM climate_seq
    GROUP BY cod_cg_zafra
)
SELECT
    a.*,
    g.max_climate_gap_days,
    g.avg_climate_gap_days,
    coalesce(d.longest_dry_spell_full, 0.0) AS longest_dry_spell_full,
    coalesce(d.longest_dry_spell_early, 0.0) AS longest_dry_spell_early,
    coalesce(d.longest_dry_spell_mid, 0.0) AS longest_dry_spell_mid,
    coalesce(d.longest_dry_spell_late, 0.0) AS longest_dry_spell_late,

    a.precip_mid_acc - a.precip_early_acc AS precip_mid_minus_early_acc,
    a.precip_late_acc - a.precip_mid_acc AS precip_late_minus_mid_acc,
    a.water_balance_mid_acc - a.water_balance_early_acc AS water_balance_mid_minus_early_acc,
    a.water_balance_late_acc - a.water_balance_mid_acc AS water_balance_late_minus_mid_acc,
    a.rad_mid_acc - a.rad_early_acc AS rad_mid_minus_early_acc,
    a.rad_late_acc - a.rad_mid_acc AS rad_late_minus_mid_acc,
    a.dry_fraction_late - a.dry_fraction_early AS dry_fraction_late_minus_early
FROM agg a
LEFT JOIN climate_gaps g USING (cod_cg_zafra)
LEFT JOIN dry_spells d USING (cod_cg_zafra);

CREATE INDEX ON candidate_features (cod_cg_zafra);

DROP TABLE IF EXISTS pg_temp.feature_values;
CREATE TEMP TABLE feature_values AS
SELECT
    b.cod_cg_zafra,
    b.cod_cg,
    b.zafra_norm,
    b.tch,
    b.area,
    b.prod_variedad,
    b.prod_no_corte,
    b.prod_grupo_de_suelo,
    b.prod_grupo_de_humedad,
    b.prod_codigo_zae,
    v.feature_family,
    v.feature_name,
    v.feature_value
FROM base_cycles b
JOIN candidate_features f USING (cod_cg_zafra)
CROSS JOIN LATERAL (
    VALUES
        ('coverage', 'climate_pentad_count_full', f.climate_pentad_count_full),
        ('coverage', 'climate_pentad_count_early', f.climate_pentad_count_early),
        ('coverage', 'climate_pentad_count_mid', f.climate_pentad_count_mid),
        ('coverage', 'climate_pentad_count_late', f.climate_pentad_count_late),
        ('coverage', 'max_climate_gap_days', f.max_climate_gap_days),
        ('coverage', 'avg_climate_gap_days', f.avg_climate_gap_days),

        ('phase_acc', 'precip_full_acc', f.precip_full_acc),
        ('phase_acc', 'precip_early_acc', f.precip_early_acc),
        ('phase_acc', 'precip_mid_acc', f.precip_mid_acc),
        ('phase_acc', 'precip_late_acc', f.precip_late_acc),
        ('phase_acc', 'eto_full_acc', f.eto_full_acc),
        ('phase_acc', 'eto_early_acc', f.eto_early_acc),
        ('phase_acc', 'eto_mid_acc', f.eto_mid_acc),
        ('phase_acc', 'eto_late_acc', f.eto_late_acc),
        ('phase_acc', 'water_balance_full_acc', f.water_balance_full_acc),
        ('phase_acc', 'water_balance_early_acc', f.water_balance_early_acc),
        ('phase_acc', 'water_balance_mid_acc', f.water_balance_mid_acc),
        ('phase_acc', 'water_balance_late_acc', f.water_balance_late_acc),
        ('phase_acc', 'rad_full_acc', f.rad_full_acc),
        ('phase_acc', 'rad_early_acc', f.rad_early_acc),
        ('phase_acc', 'rad_mid_acc', f.rad_mid_acc),
        ('phase_acc', 'rad_late_acc', f.rad_late_acc),
        ('phase_acc', 'gdd_full_acc', f.gdd_full_acc),
        ('phase_acc', 'gdd_early_acc', f.gdd_early_acc),
        ('phase_acc', 'gdd_mid_acc', f.gdd_mid_acc),
        ('phase_acc', 'gdd_late_acc', f.gdd_late_acc),

        ('phase_ratio', 'water_ratio_full', f.water_ratio_full),
        ('phase_ratio', 'water_ratio_early', f.water_ratio_early),
        ('phase_ratio', 'water_ratio_mid', f.water_ratio_mid),
        ('phase_ratio', 'water_ratio_late', f.water_ratio_late),

        ('phase_mean', 'tmean_full_mean', f.tmean_full_mean),
        ('phase_mean', 'tmean_early_mean', f.tmean_early_mean),
        ('phase_mean', 'tmean_mid_mean', f.tmean_mid_mean),
        ('phase_mean', 'tmean_late_mean', f.tmean_late_mean),
        ('phase_mean', 'tmax_full_mean', f.tmax_full_mean),
        ('phase_mean', 'tmax_early_mean', f.tmax_early_mean),
        ('phase_mean', 'tmax_mid_mean', f.tmax_mid_mean),
        ('phase_mean', 'tmax_late_mean', f.tmax_late_mean),
        ('phase_mean', 'tmin_full_mean', f.tmin_full_mean),
        ('phase_mean', 'tmin_early_mean', f.tmin_early_mean),
        ('phase_mean', 'tmin_mid_mean', f.tmin_mid_mean),
        ('phase_mean', 'tmin_late_mean', f.tmin_late_mean),
        ('phase_mean', 'rh_full_mean', f.rh_full_mean),
        ('phase_mean', 'rh_early_mean', f.rh_early_mean),
        ('phase_mean', 'rh_mid_mean', f.rh_mid_mean),
        ('phase_mean', 'rh_late_mean', f.rh_late_mean),
        ('phase_mean', 'mojadura_full_mean', f.mojadura_full_mean),
        ('phase_mean', 'heat_index_full_mean', f.heat_index_full_mean),

        ('stress', 'dry_pentad_count_full', f.dry_pentad_count_full),
        ('stress', 'dry_pentad_count_early', f.dry_pentad_count_early),
        ('stress', 'dry_pentad_count_mid', f.dry_pentad_count_mid),
        ('stress', 'dry_pentad_count_late', f.dry_pentad_count_late),
        ('stress', 'dry_fraction_full', f.dry_fraction_full),
        ('stress', 'dry_fraction_early', f.dry_fraction_early),
        ('stress', 'dry_fraction_mid', f.dry_fraction_mid),
        ('stress', 'dry_fraction_late', f.dry_fraction_late),
        ('stress', 'heat_pentad_count_full', f.heat_pentad_count_full),
        ('stress', 'heat_pentad_count_early', f.heat_pentad_count_early),
        ('stress', 'heat_pentad_count_mid', f.heat_pentad_count_mid),
        ('stress', 'heat_pentad_count_late', f.heat_pentad_count_late),
        ('stress', 'low_rad_pentad_count_full', f.low_rad_pentad_count_full),
        ('stress', 'longest_dry_spell_full', f.longest_dry_spell_full),
        ('stress', 'longest_dry_spell_early', f.longest_dry_spell_early),
        ('stress', 'longest_dry_spell_mid', f.longest_dry_spell_mid),
        ('stress', 'longest_dry_spell_late', f.longest_dry_spell_late),

        ('trend', 'water_balance_cycle_slope', f.water_balance_cycle_slope),
        ('trend', 'precip_cycle_slope', f.precip_cycle_slope),
        ('trend', 'rad_cycle_slope', f.rad_cycle_slope),
        ('trend', 'tmean_cycle_slope', f.tmean_cycle_slope),
        ('trend', 'precip_mid_minus_early_acc', f.precip_mid_minus_early_acc),
        ('trend', 'precip_late_minus_mid_acc', f.precip_late_minus_mid_acc),
        ('trend', 'water_balance_mid_minus_early_acc', f.water_balance_mid_minus_early_acc),
        ('trend', 'water_balance_late_minus_mid_acc', f.water_balance_late_minus_mid_acc),
        ('trend', 'rad_mid_minus_early_acc', f.rad_mid_minus_early_acc),
        ('trend', 'rad_late_minus_mid_acc', f.rad_late_minus_mid_acc),
        ('trend', 'dry_fraction_late_minus_early', f.dry_fraction_late_minus_early),

        ('harvest_window', 'precip_last_030_acc', f.precip_last_030_acc),
        ('harvest_window', 'precip_last_060_acc', f.precip_last_060_acc),
        ('harvest_window', 'precip_last_090_acc', f.precip_last_090_acc),
        ('harvest_window', 'precip_last_120_acc', f.precip_last_120_acc),
        ('harvest_window', 'water_balance_last_030_acc', f.water_balance_last_030_acc),
        ('harvest_window', 'water_balance_last_060_acc', f.water_balance_last_060_acc),
        ('harvest_window', 'water_balance_last_090_acc', f.water_balance_last_090_acc),
        ('harvest_window', 'water_balance_last_120_acc', f.water_balance_last_120_acc),
        ('harvest_window', 'eto_last_090_acc', f.eto_last_090_acc),
        ('harvest_window', 'rad_last_090_acc', f.rad_last_090_acc),
        ('harvest_window', 'gdd_last_090_acc', f.gdd_last_090_acc),
        ('harvest_window', 'tmean_last_090_mean', f.tmean_last_090_mean),
        ('harvest_window', 'rh_last_090_mean', f.rh_last_090_mean),
        ('harvest_window', 'dry_pentad_last_090_count', f.dry_pentad_last_090_count),
        ('harvest_window', 'heat_pentad_last_090_count', f.heat_pentad_last_090_count)
) AS v(feature_family, feature_name, feature_value);

CREATE INDEX ON feature_values (feature_name);
CREATE INDEX ON feature_values (zafra_norm);

DROP TABLE IF EXISTS pg_temp.feature_ranked;
CREATE TEMP TABLE feature_ranked AS
WITH non_null_feature_ranks AS (
    SELECT
        cod_cg_zafra,
        feature_name,
        rank() OVER (PARTITION BY feature_name ORDER BY feature_value) AS feature_rank
    FROM feature_values
    WHERE feature_value IS NOT NULL
),
non_null_tch_ranks AS (
    SELECT
        cod_cg_zafra,
        feature_name,
        rank() OVER (PARTITION BY feature_name ORDER BY tch) AS tch_rank
    FROM feature_values
    WHERE feature_value IS NOT NULL
      AND tch IS NOT NULL
)
SELECT
    fv.*,
    fr.feature_rank,
    tr.tch_rank
FROM feature_values fv
LEFT JOIN non_null_feature_ranks fr
  ON fr.cod_cg_zafra = fv.cod_cg_zafra
 AND fr.feature_name = fv.feature_name
LEFT JOIN non_null_tch_ranks tr
  ON tr.cod_cg_zafra = fv.cod_cg_zafra
 AND tr.feature_name = fv.feature_name;

CREATE INDEX ON feature_ranked (feature_name);
CREATE INDEX ON feature_ranked (zafra_norm);

-- Block 1: climate coverage and context by zafra.
SELECT
    '01_coverage_by_zafra' AS diagnostic_block,
    b.zafra_norm,
    count(*) AS lote_zafras,
    round(avg(f.climate_pentad_count_full)::numeric, 2) AS avg_climate_pentads,
    percentile_cont(0.50) WITHIN GROUP (ORDER BY f.climate_pentad_count_full) AS p50_climate_pentads,
    percentile_cont(0.10) WITHIN GROUP (ORDER BY f.climate_pentad_count_full) AS p10_climate_pentads,
    round(avg(f.max_climate_gap_days)::numeric, 2) AS avg_max_climate_gap_days,
    round(avg(b.optical_ndvi_obs_count)::numeric, 2) AS avg_optical_ndvi_obs,
    round(avg(b.radar_asc_vv_obs_count + b.radar_desc_vv_obs_count)::numeric, 2) AS avg_radar_vv_obs,
    round(avg(b.raw_joined_climate_obs_count)::numeric, 2) AS avg_raw_joined_climate_obs,
    round(avg(b.tch)::numeric, 2) AS avg_tch
FROM base_cycles b
JOIN candidate_features f USING (cod_cg_zafra)
GROUP BY b.zafra_norm
ORDER BY b.zafra_norm;

-- Block 2: candidate feature diagnostics, ranked by absolute Spearman signal.
SELECT
    '02_candidate_feature_signal' AS diagnostic_block,
    feature_family,
    feature_name,
    count(*) AS rows_total,
    count(feature_value) AS rows_non_null,
    round((1.0 - count(feature_value)::numeric / NULLIF(count(*), 0)), 4) AS missing_rate,
    count(DISTINCT zafra_norm) AS zafras_present,
    round(avg(feature_value)::numeric, 4) AS feature_mean,
    round(stddev_samp(feature_value)::numeric, 4) AS feature_std,
    round(corr(feature_value, tch)::numeric, 4) AS pearson_tch,
    round(corr(feature_rank::double precision, tch_rank::double precision)::numeric, 4) AS spearman_tch,
    round(abs(corr(feature_rank::double precision, tch_rank::double precision))::numeric, 4) AS spearman_abs
FROM feature_ranked
GROUP BY feature_family, feature_name
HAVING count(feature_value) >= 100
ORDER BY spearman_abs DESC NULLS LAST, missing_rate ASC, feature_name;

-- Block 3: same feature signal by zafra, to flag unstable relationships.
SELECT
    '03_signal_by_zafra' AS diagnostic_block,
    feature_family,
    feature_name,
    zafra_norm,
    count(feature_value) AS rows_non_null,
    round(avg(feature_value)::numeric, 4) AS feature_mean,
    round(stddev_samp(feature_value)::numeric, 4) AS feature_std,
    round(corr(feature_value, tch)::numeric, 4) AS pearson_tch,
    round(corr(feature_rank::double precision, tch_rank::double precision)::numeric, 4) AS spearman_tch
FROM feature_ranked
GROUP BY feature_family, feature_name, zafra_norm
HAVING count(feature_value) >= 30
ORDER BY feature_family, feature_name, zafra_norm;

-- Block 4: zafra stability summary per feature.
WITH by_zafra AS (
    SELECT
        feature_family,
        feature_name,
        zafra_norm,
        avg(feature_value) AS zafra_feature_mean,
        corr(feature_rank::double precision, tch_rank::double precision) AS zafra_spearman
    FROM feature_ranked
    GROUP BY feature_family, feature_name, zafra_norm
    HAVING count(feature_value) >= 30
)
SELECT
    '04_feature_stability_across_zafra' AS diagnostic_block,
    feature_family,
    feature_name,
    count(*) AS zafras_with_signal,
    round(avg(zafra_feature_mean)::numeric, 4) AS mean_of_zafra_means,
    round(stddev_samp(zafra_feature_mean)::numeric, 4) AS sd_of_zafra_means,
    round(avg(zafra_spearman)::numeric, 4) AS mean_zafra_spearman,
    round(stddev_samp(zafra_spearman)::numeric, 4) AS sd_zafra_spearman,
    sum(CASE WHEN zafra_spearman > 0 THEN 1 ELSE 0 END) AS positive_zafras,
    sum(CASE WHEN zafra_spearman < 0 THEN 1 ELSE 0 END) AS negative_zafras
FROM by_zafra
GROUP BY feature_family, feature_name
ORDER BY abs(avg(zafra_spearman)) DESC NULLS LAST, sd_zafra_spearman ASC NULLS LAST;

-- Block 5: climate signal inside key agronomic groups.
WITH grouped AS (
    SELECT
        feature_family,
        feature_name,
        'prod_no_corte' AS group_name,
        coalesce(prod_no_corte, '__MISSING__') AS group_value,
        count(feature_value) AS rows_non_null,
        corr(feature_rank::double precision, tch_rank::double precision) AS spearman_tch
    FROM feature_ranked
    GROUP BY feature_family, feature_name, coalesce(prod_no_corte, '__MISSING__')
    HAVING count(feature_value) >= 50

    UNION ALL

    SELECT
        feature_family,
        feature_name,
        'prod_grupo_de_humedad' AS group_name,
        coalesce(prod_grupo_de_humedad, '__MISSING__') AS group_value,
        count(feature_value) AS rows_non_null,
        corr(feature_rank::double precision, tch_rank::double precision) AS spearman_tch
    FROM feature_ranked
    GROUP BY feature_family, feature_name, coalesce(prod_grupo_de_humedad, '__MISSING__')
    HAVING count(feature_value) >= 50

    UNION ALL

    SELECT
        feature_family,
        feature_name,
        'prod_grupo_de_suelo' AS group_name,
        coalesce(prod_grupo_de_suelo, '__MISSING__') AS group_value,
        count(feature_value) AS rows_non_null,
        corr(feature_rank::double precision, tch_rank::double precision) AS spearman_tch
    FROM feature_ranked
    GROUP BY feature_family, feature_name, coalesce(prod_grupo_de_suelo, '__MISSING__')
    HAVING count(feature_value) >= 50
)
SELECT
    '05_agronomic_group_signal' AS diagnostic_block,
    feature_family,
    feature_name,
    group_name,
    group_value,
    rows_non_null,
    round(spearman_tch::numeric, 4) AS spearman_tch,
    round(abs(spearman_tch)::numeric, 4) AS spearman_abs
FROM grouped
ORDER BY spearman_abs DESC NULLS LAST, rows_non_null DESC, feature_name
LIMIT 300;

-- Block 6: quick decision candidates. This intentionally favors features that
-- have coverage, non-zero variance, signal, and consistent zafra direction.
WITH global_signal AS (
    SELECT
        feature_family,
        feature_name,
        count(*) AS rows_total,
        count(feature_value) AS rows_non_null,
        1.0 - count(feature_value)::numeric / NULLIF(count(*), 0) AS missing_rate,
        stddev_samp(feature_value) AS feature_std,
        corr(feature_rank::double precision, tch_rank::double precision) AS spearman_tch
    FROM feature_ranked
    GROUP BY feature_family, feature_name
),
by_zafra AS (
    SELECT
        feature_family,
        feature_name,
        zafra_norm,
        corr(feature_rank::double precision, tch_rank::double precision) AS zafra_spearman
    FROM feature_ranked
    GROUP BY feature_family, feature_name, zafra_norm
    HAVING count(feature_value) >= 30
),
stability AS (
    SELECT
        feature_family,
        feature_name,
        count(*) AS zafras_with_signal,
        avg(zafra_spearman) AS mean_zafra_spearman,
        stddev_samp(zafra_spearman) AS sd_zafra_spearman,
        greatest(
            sum(CASE WHEN zafra_spearman > 0 THEN 1 ELSE 0 END),
            sum(CASE WHEN zafra_spearman < 0 THEN 1 ELSE 0 END)
        )::numeric / NULLIF(count(*), 0) AS direction_consistency
    FROM by_zafra
    GROUP BY feature_family, feature_name
)
SELECT
    '06_decision_shortlist' AS diagnostic_block,
    g.feature_family,
    g.feature_name,
    g.rows_non_null,
    round(g.missing_rate, 4) AS missing_rate,
    round(g.feature_std::numeric, 4) AS feature_std,
    round(g.spearman_tch::numeric, 4) AS global_spearman_tch,
    round(abs(g.spearman_tch)::numeric, 4) AS global_spearman_abs,
    s.zafras_with_signal,
    round(s.mean_zafra_spearman::numeric, 4) AS mean_zafra_spearman,
    round(s.sd_zafra_spearman::numeric, 4) AS sd_zafra_spearman,
    round(s.direction_consistency, 4) AS direction_consistency,
    CASE
        WHEN g.missing_rate <= 0.20
         AND abs(g.spearman_tch) >= 0.08
         AND s.direction_consistency >= 0.70
            THEN 'core_candidate'
        WHEN g.missing_rate <= 0.35
         AND abs(g.spearman_tch) >= 0.05
            THEN 'ablation_candidate'
        WHEN g.missing_rate > 0.50
            THEN 'weak_coverage'
        ELSE 'low_signal_or_unstable'
    END AS decision_hint
FROM global_signal g
LEFT JOIN stability s USING (feature_family, feature_name)
WHERE g.rows_non_null >= 100
  AND g.feature_std IS NOT NULL
  AND g.feature_std > 0
ORDER BY
    CASE
        WHEN g.missing_rate <= 0.20
         AND abs(g.spearman_tch) >= 0.08
         AND s.direction_consistency >= 0.70 THEN 1
        WHEN g.missing_rate <= 0.35
         AND abs(g.spearman_tch) >= 0.05 THEN 2
        WHEN g.missing_rate > 0.50 THEN 4
        ELSE 3
    END,
    abs(g.spearman_tch) DESC NULLS LAST,
    s.direction_consistency DESC NULLS LAST,
    g.feature_name;
