-- radar_pseudo_sequential_diagnostic_v4.sql
--
-- Diagnostic for deciding SAR/radar pseudo-sequential features.
-- Focuses on orbit coverage, ASC/DESC usefulness, compact SAR variables, and
-- whether extras like RVI/RFDI/NRB deserve ablation.

DROP TABLE IF EXISTS pg_temp.base_cycles;
CREATE TEMP TABLE base_cycles AS
SELECT
    cod_cg_zafra,
    max(cod_cg) AS cod_cg,
    max(zafra_norm) AS zafra_norm,
    max(tch)::double precision AS tch,
    min(fecha_inicio_estimada)::date AS fecha_inicio_ciclo,
    max(fecha_fin_objetivo)::date AS fecha_fin_ciclo,
    max(edad_de_cultivo)::double precision AS cycle_age_max,
    count(*) AS raw_obs_count,
    count(radar_asc_vv_promedio) AS radar_asc_vv_obs_count,
    count(radar_desc_vv_promedio) AS radar_desc_vv_obs_count
FROM public.tch_raw_longitudinal_v4
WHERE tch IS NOT NULL
  AND tch BETWEEN 20 AND 150
  AND ciclo_valido = true
  AND cod_cg_zafra IS NOT NULL
  AND edad_de_cultivo IS NOT NULL
GROUP BY cod_cg_zafra;
CREATE INDEX ON base_cycles (cod_cg_zafra);
CREATE INDEX ON base_cycles (zafra_norm);

DROP TABLE IF EXISTS pg_temp.radar_long;
CREATE TEMP TABLE radar_long AS
SELECT
    b.cod_cg_zafra,
    b.zafra_norm,
    b.tch,
    b.cycle_age_max,
    r.edad_de_cultivo::double precision AS age_days,
    (b.fecha_fin_ciclo - r.fecha_stac::date)::double precision AS days_to_harvest,
    CASE
        WHEN r.edad_de_cultivo BETWEEN 0 AND 120 THEN 'early'
        WHEN r.edad_de_cultivo BETWEEN 121 AND 240 THEN 'mid'
        WHEN r.edad_de_cultivo >= 241 THEN 'late'
        ELSE 'outside'
    END AS age_phase,
    v.orbit_name,
    v.metric_name,
    v.days_delta,
    v.metric_value
FROM base_cycles b
JOIN public.tch_raw_longitudinal_v4 r USING (cod_cg_zafra)
CROSS JOIN LATERAL (
    VALUES
        ('asc', 'vh', r.radar_asc_vh_promedio::double precision, r.radar_asc_days_delta::double precision),
        ('asc', 'vv', r.radar_asc_vv_promedio::double precision, r.radar_asc_days_delta::double precision),
        ('asc', 'ratio', r.radar_asc_ratio_promedio::double precision, r.radar_asc_days_delta::double precision),
        ('asc', 'rvi', r.radar_asc_rvi_promedio::double precision, r.radar_asc_days_delta::double precision),
        ('asc', 'nrb', r.radar_asc_nrb_promedio::double precision, r.radar_asc_days_delta::double precision),
        ('asc', 'rfdi', r.radar_asc_rfdi_promedio::double precision, r.radar_asc_days_delta::double precision),
        ('desc', 'vh', r.radar_desc_vh_promedio::double precision, r.radar_desc_days_delta::double precision),
        ('desc', 'vv', r.radar_desc_vv_promedio::double precision, r.radar_desc_days_delta::double precision),
        ('desc', 'ratio', r.radar_desc_ratio_promedio::double precision, r.radar_desc_days_delta::double precision),
        ('desc', 'rvi', r.radar_desc_rvi_promedio::double precision, r.radar_desc_days_delta::double precision),
        ('desc', 'nrb', r.radar_desc_nrb_promedio::double precision, r.radar_desc_days_delta::double precision),
        ('desc', 'rfdi', r.radar_desc_rfdi_promedio::double precision, r.radar_desc_days_delta::double precision)
) AS v(orbit_name, metric_name, metric_value, days_delta)
WHERE r.edad_de_cultivo IS NOT NULL
  AND r.ciclo_valido = true;
CREATE INDEX ON radar_long (cod_cg_zafra);
CREATE INDEX ON radar_long (orbit_name, metric_name);

DROP TABLE IF EXISTS pg_temp.candidate_features;
CREATE TEMP TABLE candidate_features AS
WITH base AS (
    SELECT
        cod_cg_zafra,
        zafra_norm,
        tch,
        orbit_name,
        metric_name,
        count(metric_value)::double precision AS obs_count,
        avg(abs(days_delta)) AS mean_abs_days_delta,
        avg(metric_value) AS full_mean,
        avg(metric_value) FILTER (WHERE age_phase = 'early') AS early_mean,
        avg(metric_value) FILTER (WHERE age_phase = 'mid') AS mid_mean,
        avg(metric_value) FILTER (WHERE age_phase = 'late') AS late_mean,
        avg(metric_value) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS last_090_mean,
        max(metric_value) AS max_value,
        min(metric_value) AS min_value,
        regr_slope(metric_value, age_days) AS cycle_slope,
        regr_slope(metric_value, age_days) FILTER (WHERE age_days < 240) AS rise_slope,
        regr_slope(metric_value, age_days) FILTER (WHERE age_days >= 240) AS late_slope
    FROM radar_long
    GROUP BY cod_cg_zafra, zafra_norm, tch, orbit_name, metric_name
)
SELECT
    *,
    mid_mean - early_mean AS mid_minus_early_mean,
    late_mean - mid_mean AS late_minus_mid_mean,
    max_value - min_value AS range_value
FROM base;

DROP TABLE IF EXISTS pg_temp.orbit_diff_features;
CREATE TEMP TABLE orbit_diff_features AS
WITH pivoted AS (
    SELECT
        cod_cg_zafra,
        zafra_norm,
        tch,
        metric_name,
        max(full_mean) FILTER (WHERE orbit_name = 'asc') AS asc_full_mean,
        max(full_mean) FILTER (WHERE orbit_name = 'desc') AS desc_full_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'asc') AS asc_mid_mean,
        max(mid_mean) FILTER (WHERE orbit_name = 'desc') AS desc_mid_mean
    FROM candidate_features
    GROUP BY cod_cg_zafra, zafra_norm, tch, metric_name
)
SELECT
    cod_cg_zafra,
    zafra_norm,
    tch,
    metric_name,
    asc_full_mean - desc_full_mean AS orbit_diff_full_mean,
    asc_mid_mean - desc_mid_mean AS orbit_diff_mid_mean
FROM pivoted;

DROP TABLE IF EXISTS pg_temp.feature_values;
CREATE TEMP TABLE feature_values AS
SELECT
    cod_cg_zafra,
    zafra_norm,
    tch,
    CASE
        WHEN metric_name IN ('vh', 'vv', 'ratio') THEN 'core_sar'
        WHEN metric_name = 'rvi' THEN 'secondary_sar'
        ELSE 'experimental_sar'
    END AS feature_family,
    'radar_' || orbit_name || '_' || metric_name || '_' || v.feature_name AS feature_name,
    v.feature_value
FROM candidate_features
CROSS JOIN LATERAL (
    VALUES
        ('obs_count', obs_count),
        ('mean_abs_days_delta', mean_abs_days_delta),
        ('full_mean', full_mean),
        ('early_mean', early_mean),
        ('mid_mean', mid_mean),
        ('late_mean', late_mean),
        ('last_090_mean', last_090_mean),
        ('mid_minus_early_mean', mid_minus_early_mean),
        ('late_minus_mid_mean', late_minus_mid_mean),
        ('range_value', range_value),
        ('cycle_slope', cycle_slope),
        ('rise_slope', rise_slope),
        ('late_slope', late_slope)
) AS v(feature_name, feature_value)

UNION ALL

SELECT
    cod_cg_zafra,
    zafra_norm,
    tch,
    CASE
        WHEN metric_name IN ('vh', 'vv', 'ratio') THEN 'core_sar_orbit_diff'
        ELSE 'experimental_sar_orbit_diff'
    END AS feature_family,
    'radar_' || metric_name || '_' || v.feature_name AS feature_name,
    v.feature_value
FROM orbit_diff_features
CROSS JOIN LATERAL (
    VALUES
        ('orbit_diff_full_mean', orbit_diff_full_mean),
        ('orbit_diff_mid_mean', orbit_diff_mid_mean)
) AS v(feature_name, feature_value);
CREATE INDEX ON feature_values (feature_name);
CREATE INDEX ON feature_values (zafra_norm);

DROP TABLE IF EXISTS pg_temp.feature_ranked;
CREATE TEMP TABLE feature_ranked AS
SELECT
    *,
    rank() OVER (PARTITION BY feature_name ORDER BY feature_value) AS feature_rank,
    rank() OVER (PARTITION BY feature_name ORDER BY tch) AS tch_rank
FROM feature_values
WHERE feature_value IS NOT NULL
  AND tch IS NOT NULL;

SELECT
    '01_coverage_by_zafra' AS diagnostic_block,
    zafra_norm,
    count(*) AS lote_zafras,
    round(avg(raw_obs_count)::numeric, 2) AS avg_raw_obs,
    round(avg(radar_asc_vv_obs_count)::numeric, 2) AS avg_asc_vv_obs,
    round(avg(radar_desc_vv_obs_count)::numeric, 2) AS avg_desc_vv_obs,
    percentile_cont(0.10) WITHIN GROUP (ORDER BY radar_asc_vv_obs_count) AS p10_asc_vv_obs,
    percentile_cont(0.10) WITHIN GROUP (ORDER BY radar_desc_vv_obs_count) AS p10_desc_vv_obs
FROM base_cycles
GROUP BY zafra_norm
ORDER BY zafra_norm;

SELECT
    '02_candidate_feature_signal' AS diagnostic_block,
    feature_family,
    feature_name,
    count(*) AS rows_non_null,
    round(corr(feature_value, tch)::numeric, 4) AS pearson_tch,
    round(corr(feature_rank::double precision, tch_rank::double precision)::numeric, 4) AS spearman_tch,
    round(abs(corr(feature_rank::double precision, tch_rank::double precision))::numeric, 4) AS spearman_abs
FROM feature_ranked
GROUP BY feature_family, feature_name
HAVING count(*) >= 100
ORDER BY spearman_abs DESC NULLS LAST, feature_name;

WITH by_zafra AS (
    SELECT
        feature_family,
        feature_name,
        zafra_norm,
        corr(feature_rank::double precision, tch_rank::double precision) AS zafra_spearman
    FROM feature_ranked
    GROUP BY feature_family, feature_name, zafra_norm
    HAVING count(*) >= 30
)
SELECT
    '03_feature_stability_across_zafra' AS diagnostic_block,
    feature_family,
    feature_name,
    count(*) AS zafras_with_signal,
    round(avg(zafra_spearman)::numeric, 4) AS mean_zafra_spearman,
    round(stddev_samp(zafra_spearman)::numeric, 4) AS sd_zafra_spearman,
    sum((zafra_spearman > 0)::int) AS positive_zafras,
    sum((zafra_spearman < 0)::int) AS negative_zafras
FROM by_zafra
GROUP BY feature_family, feature_name
ORDER BY abs(avg(zafra_spearman)) DESC NULLS LAST, sd_zafra_spearman ASC NULLS LAST;

WITH global_signal AS (
    SELECT feature_family, feature_name, count(*) AS rows_non_null,
        corr(feature_rank::double precision, tch_rank::double precision) AS spearman_tch
    FROM feature_ranked
    GROUP BY feature_family, feature_name
),
by_zafra AS (
    SELECT feature_family, feature_name, zafra_norm,
        corr(feature_rank::double precision, tch_rank::double precision) AS zafra_spearman
    FROM feature_ranked
    GROUP BY feature_family, feature_name, zafra_norm
    HAVING count(*) >= 30
),
stability AS (
    SELECT
        feature_family,
        feature_name,
        greatest(sum((zafra_spearman > 0)::int), sum((zafra_spearman < 0)::int))::numeric
            / NULLIF(count(*), 0) AS direction_consistency,
        avg(zafra_spearman) AS mean_zafra_spearman
    FROM by_zafra
    GROUP BY feature_family, feature_name
)
SELECT
    '04_decision_shortlist' AS diagnostic_block,
    g.feature_family,
    g.feature_name,
    g.rows_non_null,
    round(g.spearman_tch::numeric, 4) AS global_spearman_tch,
    round(abs(g.spearman_tch)::numeric, 4) AS global_spearman_abs,
    round(s.mean_zafra_spearman::numeric, 4) AS mean_zafra_spearman,
    round(s.direction_consistency, 4) AS direction_consistency,
    CASE
        WHEN abs(g.spearman_tch) >= 0.08 AND s.direction_consistency >= 0.70 THEN 'core_candidate'
        WHEN abs(g.spearman_tch) >= 0.05 THEN 'ablation_candidate'
        ELSE 'low_signal_or_unstable'
    END AS decision_hint
FROM global_signal g
LEFT JOIN stability s USING (feature_family, feature_name)
WHERE g.rows_non_null >= 100
ORDER BY
    CASE
        WHEN abs(g.spearman_tch) >= 0.08 AND s.direction_consistency >= 0.70 THEN 1
        WHEN abs(g.spearman_tch) >= 0.05 THEN 2
        ELSE 3
    END,
    abs(g.spearman_tch) DESC NULLS LAST,
    g.feature_name;
