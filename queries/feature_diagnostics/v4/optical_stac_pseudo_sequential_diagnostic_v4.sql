-- optical_stac_pseudo_sequential_diagnostic_v4.sql
--
-- Diagnostic for deciding STAC optical pseudo-sequential features.
-- Produces evidence only; creates no permanent model dataset.

DROP TABLE IF EXISTS pg_temp.base_cycles;
CREATE TEMP TABLE base_cycles AS
SELECT
    cod_cg_zafra,
    max(cod_cg) AS cod_cg,
    max(zafra_norm) AS zafra_norm,
    max(tch)::double precision AS tch,
    max(area)::double precision AS area,
    min(fecha_inicio_estimada)::date AS fecha_inicio_ciclo,
    max(fecha_fin_objetivo)::date AS fecha_fin_ciclo,
    max(edad_de_cultivo)::double precision AS cycle_age_max,
    max(prod_variedad) AS prod_variedad,
    max(prod_no_corte) AS prod_no_corte,
    max(prod_grupo_de_suelo) AS prod_grupo_de_suelo,
    max(prod_grupo_de_humedad) AS prod_grupo_de_humedad,
    count(*) AS raw_obs_count,
    count(stac_ndvi_promedio) AS optical_obs_count
FROM public.tch_raw_longitudinal_v4
WHERE tch IS NOT NULL
  AND tch BETWEEN 20 AND 150
  AND ciclo_valido = true
  AND cod_cg_zafra IS NOT NULL
  AND edad_de_cultivo IS NOT NULL
GROUP BY cod_cg_zafra;
CREATE INDEX ON base_cycles (cod_cg_zafra);
CREATE INDEX ON base_cycles (zafra_norm);

DROP TABLE IF EXISTS pg_temp.optical_long;
CREATE TEMP TABLE optical_long AS
SELECT
    b.cod_cg_zafra,
    b.zafra_norm,
    b.tch,
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
        ('ndvi', r.stac_ndvi_promedio::double precision),
        ('evi2', r.stac_evi2_promedio::double precision),
        ('lswi', r.stac_lswi_promedio::double precision),
        ('gndvi', r.stac_gndvi_promedio::double precision),
        ('ndre', r.stac_ndre_promedio::double precision),
        ('ndwi11', r.stac_ndwi11_promedio::double precision),
        ('msi11', r.stac_msi11_promedio::double precision),
        ('ndvire', r.stac_ndvire_promedio::double precision),
        ('cire', r.stac_cire_promedio::double precision)
) AS v(index_name, index_value)
WHERE r.edad_de_cultivo IS NOT NULL
  AND r.ciclo_valido = true;
CREATE INDEX ON optical_long (cod_cg_zafra);
CREATE INDEX ON optical_long (index_name);

DROP TABLE IF EXISTS pg_temp.optical_weighted;
CREATE TEMP TABLE optical_weighted AS
SELECT
    *,
    lag(age_days) OVER (PARTITION BY cod_cg_zafra, index_name ORDER BY age_days, fecha_obs) AS prev_age,
    lead(age_days) OVER (PARTITION BY cod_cg_zafra, index_name ORDER BY age_days, fecha_obs) AS next_age,
    max(index_value) OVER (PARTITION BY cod_cg_zafra, index_name) AS peak_value
FROM optical_long;

DROP TABLE IF EXISTS pg_temp.candidate_features;
CREATE TEMP TABLE candidate_features AS
WITH prepared AS (
    SELECT
        *,
        greatest(0.0, coalesce((prev_age + age_days) / 2.0, age_days - 7.5)) AS obs_start_age,
        least(cycle_age_max, coalesce((age_days + next_age) / 2.0, age_days + 7.5)) AS obs_end_age
    FROM optical_weighted
),
features AS (
    SELECT
        cod_cg_zafra,
        index_name,
        count(index_value)::double precision AS obs_count,
        max(age_days) - min(age_days) AS observed_age_span,
        max(age_days - prev_age) AS max_gap_days,
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
            FILTER (WHERE index_value >= 0.8 * peak_value) AS duration_above_80pct_peak,
        avg(index_value) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS last_090_mean,
        regr_slope(index_value, days_to_harvest) FILTER (WHERE days_to_harvest BETWEEN 0 AND 90) AS last_090_slope
    FROM prepared
    GROUP BY cod_cg_zafra, index_name
)
SELECT
    *,
    mid_mean - early_mean AS mid_minus_early_mean,
    late_mean - mid_mean AS late_minus_mid_mean,
    CASE WHEN cycle_age_max > 0 THEN age_at_peak / cycle_age_max ELSE NULL END AS rel_age_at_peak
FROM features
JOIN base_cycles USING (cod_cg_zafra);
CREATE INDEX ON candidate_features (cod_cg_zafra);

DROP TABLE IF EXISTS pg_temp.feature_values;
CREATE TEMP TABLE feature_values AS
SELECT
    cod_cg_zafra,
    zafra_norm,
    tch,
    CASE
        WHEN index_name IN ('ndvi', 'evi2', 'lswi', 'gndvi', 'ndre') THEN 'core_optical'
        WHEN index_name IN ('ndwi11', 'msi11', 'ndvire') THEN 'secondary_optical'
        ELSE 'experimental_optical'
    END AS feature_family,
    index_name || '_' || v.feature_name AS feature_name,
    v.feature_value
FROM candidate_features
CROSS JOIN LATERAL (
    VALUES
        ('obs_count', obs_count),
        ('observed_age_span', observed_age_span),
        ('max_gap_days', max_gap_days),
        ('full_mean', full_mean),
        ('early_mean', early_mean),
        ('mid_mean', mid_mean),
        ('late_mean', late_mean),
        ('mid_minus_early_mean', mid_minus_early_mean),
        ('late_minus_mid_mean', late_minus_mid_mean),
        ('peak_value', peak_value),
        ('min_value', min_value),
        ('amplitude', amplitude),
        ('age_at_peak', age_at_peak),
        ('rel_age_at_peak', rel_age_at_peak),
        ('auc_full', auc_full),
        ('auc_early', auc_early),
        ('auc_mid', auc_mid),
        ('auc_late', auc_late),
        ('rise_slope', rise_slope),
        ('late_slope', late_slope),
        ('duration_above_80pct_peak', duration_above_80pct_peak),
        ('last_090_mean', last_090_mean),
        ('last_090_slope', last_090_slope)
) AS v(feature_name, feature_value);
CREATE INDEX ON feature_values (feature_name);
CREATE INDEX ON feature_values (zafra_norm);

DROP TABLE IF EXISTS pg_temp.feature_ranked;
CREATE TEMP TABLE feature_ranked AS
WITH valid AS (
    SELECT
        *,
        rank() OVER (PARTITION BY feature_name ORDER BY feature_value) AS feature_rank,
        rank() OVER (PARTITION BY feature_name ORDER BY tch) AS tch_rank
    FROM feature_values
    WHERE feature_value IS NOT NULL
      AND tch IS NOT NULL
)
SELECT * FROM valid;

SELECT
    '01_coverage_by_zafra' AS diagnostic_block,
    zafra_norm,
    count(*) AS lote_zafras,
    round(avg(raw_obs_count)::numeric, 2) AS avg_raw_obs,
    round(avg(optical_obs_count)::numeric, 2) AS avg_optical_obs,
    percentile_cont(0.10) WITHIN GROUP (ORDER BY optical_obs_count) AS p10_optical_obs,
    percentile_cont(0.50) WITHIN GROUP (ORDER BY optical_obs_count) AS p50_optical_obs,
    round(avg(tch)::numeric, 2) AS avg_tch
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
    SELECT
        feature_family,
        feature_name,
        count(*) AS rows_non_null,
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
