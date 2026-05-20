-- agronomy_productividad_diagnostic_v4.sql
--
-- Diagnostic for static agronomy/categorical feature decisions.
-- This is not a final encoder. It measures cardinality, missingness, category
-- stability, target spread, unseen-category risk, and numeric leakage risk.

DROP TABLE IF EXISTS pg_temp.base_cycles;
CREATE TEMP TABLE base_cycles AS
SELECT
    cod_cg_zafra,
    max(cod_cg) AS cod_cg,
    max(zafra_norm) AS zafra_norm,
    max(tch)::double precision AS tch,
    max(area)::double precision AS area,
    max(prod_variedad) AS prod_variedad,
    max(prod_no_corte) AS prod_no_corte,
    max(prod_grupo_de_suelo) AS prod_grupo_de_suelo,
    max(prod_grupo_de_humedad) AS prod_grupo_de_humedad,
    max(prod_codigo_zae) AS prod_codigo_zae,
    max(prod_familia_de_suelo) AS prod_familia_de_suelo,
    max(prod_finca) AS prod_finca,
    max(prod_ingenio) AS prod_ingenio,
    max(prod_cosecha) AS prod_cosecha,
    max(area)::double precision AS prod_area,
    max(edad_de_cultivo)::double precision AS cycle_age_max
FROM public.tch_raw_longitudinal_v4
WHERE tch IS NOT NULL
  AND tch BETWEEN 20 AND 150
  AND ciclo_valido = true
  AND cod_cg_zafra IS NOT NULL
GROUP BY cod_cg_zafra;
CREATE INDEX ON base_cycles (cod_cg_zafra);
CREATE INDEX ON base_cycles (zafra_norm);

DROP TABLE IF EXISTS pg_temp.categorical_values;
CREATE TEMP TABLE categorical_values AS
SELECT
    cod_cg_zafra,
    zafra_norm,
    tch,
    v.feature_name,
    v.category_value
FROM base_cycles
CROSS JOIN LATERAL (
    VALUES
        ('prod_variedad', prod_variedad),
        ('prod_no_corte', prod_no_corte),
        ('prod_grupo_de_suelo', prod_grupo_de_suelo),
        ('prod_grupo_de_humedad', prod_grupo_de_humedad),
        ('prod_codigo_zae', prod_codigo_zae),
        ('prod_familia_de_suelo', prod_familia_de_suelo),
        ('prod_finca', prod_finca),
        ('prod_ingenio', prod_ingenio),
        ('prod_cosecha', prod_cosecha)
) AS v(feature_name, category_value);
CREATE INDEX ON categorical_values (feature_name);
CREATE INDEX ON categorical_values (zafra_norm);

DROP TABLE IF EXISTS pg_temp.numeric_values;
CREATE TEMP TABLE numeric_values AS
SELECT
    cod_cg_zafra,
    zafra_norm,
    tch,
    v.feature_name,
    v.feature_value
FROM base_cycles
CROSS JOIN LATERAL (
    VALUES
        ('area', prod_area),
        ('cycle_age_max', cycle_age_max)
) AS v(feature_name, feature_value);

DROP TABLE IF EXISTS pg_temp.numeric_ranked;
CREATE TEMP TABLE numeric_ranked AS
SELECT
    *,
    rank() OVER (PARTITION BY feature_name ORDER BY feature_value) AS feature_rank,
    rank() OVER (PARTITION BY feature_name ORDER BY tch) AS tch_rank
FROM numeric_values
WHERE feature_value IS NOT NULL
  AND tch IS NOT NULL;

SELECT
    '01_categorical_cardinality' AS diagnostic_block,
    feature_name,
    count(*) AS rows_total,
    count(category_value) AS rows_non_null,
    round((1.0 - count(category_value)::numeric / NULLIF(count(*), 0)), 4) AS missing_rate,
    count(DISTINCT category_value) AS distinct_values,
    round(count(*)::numeric / NULLIF(count(DISTINCT category_value), 0), 2) AS avg_rows_per_category
FROM categorical_values
GROUP BY feature_name
ORDER BY distinct_values DESC, missing_rate DESC;

SELECT
    '02_category_target_spread' AS diagnostic_block,
    feature_name,
    count(DISTINCT category_value) AS distinct_values,
    round(stddev_samp(category_tch_mean)::numeric, 4) AS sd_category_tch_mean,
    round(min(category_tch_mean)::numeric, 4) AS min_category_tch_mean,
    round(max(category_tch_mean)::numeric, 4) AS max_category_tch_mean,
    round((max(category_tch_mean) - min(category_tch_mean))::numeric, 4) AS range_category_tch_mean
FROM (
    SELECT
        feature_name,
        category_value,
        avg(tch) AS category_tch_mean,
        count(*) AS rows_in_category
    FROM categorical_values
    WHERE category_value IS NOT NULL
    GROUP BY feature_name, category_value
    HAVING count(*) >= 30
) x
GROUP BY feature_name
ORDER BY range_category_tch_mean DESC NULLS LAST;

SELECT
    '03_top_category_levels' AS diagnostic_block,
    feature_name,
    category_value,
    count(*) AS rows_total,
    count(DISTINCT zafra_norm) AS zafras_present,
    round(avg(tch)::numeric, 4) AS avg_tch,
    round(stddev_samp(tch)::numeric, 4) AS sd_tch
FROM categorical_values
WHERE category_value IS NOT NULL
GROUP BY feature_name, category_value
HAVING count(*) >= 30
ORDER BY feature_name, rows_total DESC, avg_tch DESC;

WITH train_levels AS (
    SELECT DISTINCT feature_name, category_value
    FROM categorical_values
    WHERE zafra_norm IN ('2020_2021', '2021_2022', '2022_2023')
      AND category_value IS NOT NULL
),
future_rows AS (
    SELECT
        c.*,
        CASE WHEN t.category_value IS NULL THEN 1 ELSE 0 END AS unseen_in_train
    FROM categorical_values c
    LEFT JOIN train_levels t
      ON t.feature_name = c.feature_name
     AND t.category_value = c.category_value
    WHERE c.zafra_norm IN ('2023_2024', '2024_2025')
      AND c.category_value IS NOT NULL
)
SELECT
    '04_unseen_category_risk' AS diagnostic_block,
    feature_name,
    zafra_norm,
    count(*) AS future_rows,
    sum(unseen_in_train) AS unseen_rows,
    round(avg(unseen_in_train)::numeric, 4) AS unseen_row_rate,
    count(DISTINCT category_value) FILTER (WHERE unseen_in_train = 1) AS unseen_distinct_values
FROM future_rows
GROUP BY feature_name, zafra_norm
ORDER BY feature_name, zafra_norm;

SELECT
    '05_numeric_static_signal' AS diagnostic_block,
    feature_name,
    count(*) AS rows_non_null,
    round(corr(feature_value, tch)::numeric, 4) AS pearson_tch,
    round(corr(feature_rank::double precision, tch_rank::double precision)::numeric, 4) AS spearman_tch,
    round(abs(corr(feature_rank::double precision, tch_rank::double precision))::numeric, 4) AS spearman_abs
FROM numeric_ranked
GROUP BY feature_name
ORDER BY spearman_abs DESC NULLS LAST;

SELECT
    '06_leakage_field_presence' AS diagnostic_block,
    leakage_family,
    field_name,
    count(*) AS raw_rows,
    count(field_value) AS non_null_rows,
    round(count(field_value)::numeric / NULLIF(count(*), 0), 4) AS non_null_rate
FROM (
    SELECT
        b.cod_cg_zafra,
        v.leakage_family,
        v.field_name,
        v.field_value
    FROM base_cycles b
    JOIN public.productividad p
      ON p.cod_cg_zafra = b.cod_cg_zafra
    CROSS JOIN LATERAL (
        VALUES
            ('yield_outcome', 'rendimiento', p.rendimiento::text),
            ('yield_outcome', 'tah', p.tah::text),
            ('quality_outcome', 'brix', p.brix::text),
            ('quality_outcome', 'pureza', p.pureza::text),
            ('quality_outcome', 'pol', p.pol::text),
            ('harvest_operation', 'madurante', p.madurante::text),
            ('harvest_operation', 'dias_madurantes', p.dias_madurantes::text),
            ('harvest_operation', 'horas_quema', p.horas_quema::text),
            ('irrigation_management', 'total_riego_aplicado_mm', p.total_riego_aplicado_mm::text),
            ('fertilization_management', 'nitrogeno', p.nitrogeno::text),
            ('pest_management', 'de_infestacion_barrenador', p.de_infestacion_barrenador::text)
    ) AS v(leakage_family, field_name, field_value)
) x
GROUP BY leakage_family, field_name
ORDER BY leakage_family, field_name;
