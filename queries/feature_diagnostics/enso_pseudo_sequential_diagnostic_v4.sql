-- enso_pseudo_sequential_diagnostic_v4.sql
--
-- Diagnostic for compact ENSO feature decisions.
-- ENSO has only monthly rows, so this tests compact pre-cycle/cycle windows
-- instead of expanding monthly vectors.

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
    max(prod_grupo_de_humedad) AS prod_grupo_de_humedad,
    max(prod_grupo_de_suelo) AS prod_grupo_de_suelo
FROM public.tch_raw_longitudinal_v4
WHERE tch IS NOT NULL
  AND tch BETWEEN 20 AND 150
  AND ciclo_valido = true
  AND cod_cg_zafra IS NOT NULL
GROUP BY cod_cg_zafra;
CREATE INDEX ON base_cycles (cod_cg_zafra);
CREATE INDEX ON base_cycles (zafra_norm);

DROP TABLE IF EXISTS pg_temp.enso_seq;
CREATE TEMP TABLE enso_seq AS
SELECT
    b.cod_cg_zafra,
    b.zafra_norm,
    b.tch,
    b.fecha_inicio_ciclo,
    b.fecha_fin_ciclo,
    e.date::date AS enso_month,
    (e.date::date - b.fecha_inicio_ciclo)::double precision AS age_days,
    CASE
        WHEN e.date::date < b.fecha_inicio_ciclo THEN 'precycle_180d'
        WHEN e.date::date BETWEEN b.fecha_inicio_ciclo AND b.fecha_inicio_ciclo + INTERVAL '120 days' THEN 'early'
        WHEN e.date::date > b.fecha_inicio_ciclo + INTERVAL '120 days'
         AND e.date::date <= b.fecha_inicio_ciclo + INTERVAL '240 days' THEN 'mid'
        WHEN e.date::date > b.fecha_inicio_ciclo + INTERVAL '240 days'
         AND e.date::date <= b.fecha_fin_ciclo THEN 'late'
        ELSE 'outside'
    END AS enso_window,
    e.oni::double precision AS oni,
    e.nino34::double precision AS nino34,
    e.soi::double precision AS soi,
    e.roni::double precision AS roni,
    e.mei::double precision AS mei,
    e.pdo::double precision AS pdo,
    e.amo::double precision AS amo
FROM base_cycles b
JOIN public.enso e
  ON e.date::date >= b.fecha_inicio_ciclo - INTERVAL '180 days'
 AND e.date::date <= b.fecha_fin_ciclo;
CREATE INDEX ON enso_seq (cod_cg_zafra);
CREATE INDEX ON enso_seq (enso_window);

DROP TABLE IF EXISTS pg_temp.candidate_features;
CREATE TEMP TABLE candidate_features AS
SELECT
    cod_cg_zafra,
    max(zafra_norm) AS zafra_norm,
    max(tch) AS tch,
    count(*)::double precision AS enso_month_count,

    avg(oni) FILTER (WHERE enso_window = 'precycle_180d') AS oni_precycle_mean,
    avg(oni) FILTER (WHERE enso_window = 'early') AS oni_early_mean,
    avg(oni) FILTER (WHERE enso_window = 'mid') AS oni_mid_mean,
    avg(oni) FILTER (WHERE enso_window = 'late') AS oni_late_mean,
    max(abs(oni)) FILTER (WHERE enso_window IN ('precycle_180d', 'early')) AS oni_abs_max_precycle_early,
    avg(nino34) FILTER (WHERE enso_window = 'precycle_180d') AS nino34_precycle_mean,
    avg(nino34) FILTER (WHERE enso_window = 'early') AS nino34_early_mean,
    max(abs(nino34)) FILTER (WHERE enso_window IN ('precycle_180d', 'early')) AS nino34_abs_max_precycle_early,

    avg(soi) FILTER (WHERE enso_window = 'precycle_180d') AS soi_precycle_mean,
    avg(soi) FILTER (WHERE enso_window = 'early') AS soi_early_mean,
    avg(soi) FILTER (WHERE enso_window = 'mid') AS soi_mid_mean,
    avg(soi) FILTER (WHERE enso_window = 'late') AS soi_late_mean,
    avg((soi > 0)::int) FILTER (WHERE enso_window = 'precycle_180d')::double precision AS soi_positive_fraction_precycle,
    avg((oni > 0.5)::int) FILTER (WHERE enso_window = 'precycle_180d')::double precision AS el_nino_fraction_precycle,
    avg((oni < -0.5)::int) FILTER (WHERE enso_window = 'precycle_180d')::double precision AS la_nina_fraction_precycle,

    avg(roni) FILTER (WHERE enso_window = 'precycle_180d') AS roni_precycle_mean,
    avg(mei) FILTER (WHERE enso_window = 'precycle_180d') AS mei_precycle_mean,
    avg(pdo) FILTER (WHERE enso_window = 'precycle_180d') AS pdo_precycle_mean,
    avg(amo) FILTER (WHERE enso_window = 'precycle_180d') AS amo_precycle_mean,

    avg(oni) FILTER (WHERE enso_window = 'precycle_180d')
      * avg(soi) FILTER (WHERE enso_window = 'precycle_180d') AS oni_x_soi_precycle
FROM enso_seq
GROUP BY cod_cg_zafra;

DROP TABLE IF EXISTS pg_temp.feature_values;
CREATE TEMP TABLE feature_values AS
SELECT
    cod_cg_zafra,
    zafra_norm,
    tch,
    CASE
        WHEN v.feature_name LIKE 'oni_%'
          OR v.feature_name LIKE 'nino34_%'
          OR v.feature_name LIKE 'soi_%'
          OR v.feature_name IN ('el_nino_fraction_precycle', 'la_nina_fraction_precycle')
            THEN 'core_enso'
        ELSE 'experimental_enso'
    END AS feature_family,
    v.feature_name,
    v.feature_value
FROM candidate_features
CROSS JOIN LATERAL (
    VALUES
        ('enso_month_count', enso_month_count),
        ('oni_precycle_mean', oni_precycle_mean),
        ('oni_early_mean', oni_early_mean),
        ('oni_mid_mean', oni_mid_mean),
        ('oni_late_mean', oni_late_mean),
        ('oni_abs_max_precycle_early', oni_abs_max_precycle_early),
        ('nino34_precycle_mean', nino34_precycle_mean),
        ('nino34_early_mean', nino34_early_mean),
        ('nino34_abs_max_precycle_early', nino34_abs_max_precycle_early),
        ('soi_precycle_mean', soi_precycle_mean),
        ('soi_early_mean', soi_early_mean),
        ('soi_mid_mean', soi_mid_mean),
        ('soi_late_mean', soi_late_mean),
        ('soi_positive_fraction_precycle', soi_positive_fraction_precycle),
        ('el_nino_fraction_precycle', el_nino_fraction_precycle),
        ('la_nina_fraction_precycle', la_nina_fraction_precycle),
        ('roni_precycle_mean', roni_precycle_mean),
        ('mei_precycle_mean', mei_precycle_mean),
        ('pdo_precycle_mean', pdo_precycle_mean),
        ('amo_precycle_mean', amo_precycle_mean),
        ('oni_x_soi_precycle', oni_x_soi_precycle)
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
    '01_enso_table_coverage' AS diagnostic_block,
    min(date)::date AS min_enso_month,
    max(date)::date AS max_enso_month,
    count(*) AS enso_rows,
    count(oni) AS oni_rows,
    count(nino34) AS nino34_rows,
    count(soi) AS soi_rows,
    count(mei) AS mei_rows,
    count(pdo) AS pdo_rows
FROM public.enso;

SELECT
    '02_coverage_by_zafra' AS diagnostic_block,
    zafra_norm,
    count(*) AS lote_zafras,
    round(avg(enso_month_count)::numeric, 2) AS avg_enso_month_count,
    percentile_cont(0.50) WITHIN GROUP (ORDER BY enso_month_count) AS p50_enso_month_count,
    round(avg(tch)::numeric, 2) AS avg_tch
FROM candidate_features
GROUP BY zafra_norm
ORDER BY zafra_norm;

SELECT
    '03_candidate_feature_signal' AS diagnostic_block,
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
    '04_feature_stability_across_zafra' AS diagnostic_block,
    feature_family,
    feature_name,
    count(*) AS zafras_with_signal,
    round(avg(zafra_spearman)::numeric, 4) AS mean_zafra_spearman,
    round(stddev_samp(zafra_spearman)::numeric, 4) AS sd_zafra_spearman,
    sum((zafra_spearman > 0)::int) AS positive_zafras,
    sum((zafra_spearman < 0)::int) AS negative_zafras
FROM by_zafra
GROUP BY feature_family, feature_name
ORDER BY abs(avg(zafra_spearman)) DESC NULLS LAST;

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
    '05_decision_shortlist' AS diagnostic_block,
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
    abs(g.spearman_tch) DESC NULLS LAST;
