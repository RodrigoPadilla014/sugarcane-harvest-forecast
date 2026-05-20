-- cross_table_feature_diagnostic_v4.sql
--
-- Cross-table diagnostic for pseudo-sequential design decisions.
-- Measures whether source coverage, simple source-level signals, and source
-- interactions suggest core features, ablations, or leakage/covar shift risks.

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
    max(prod_variedad) AS prod_variedad,
    max(prod_no_corte) AS prod_no_corte,
    max(prod_grupo_de_suelo) AS prod_grupo_de_suelo,
    max(prod_grupo_de_humedad) AS prod_grupo_de_humedad,
    count(*) AS raw_obs_count,
    count(stac_ndvi_promedio) AS optical_obs_count,
    count(radar_asc_vv_promedio) AS radar_asc_obs_count,
    count(radar_desc_vv_promedio) AS radar_desc_obs_count,
    count(clima_precipitacion_sum) AS raw_joined_climate_obs_count,
    count(enso_oni) AS enso_joined_obs_count,
    avg(stac_ndvi_promedio)::double precision AS ndvi_mean_raw,
    avg(stac_lswi_promedio)::double precision AS lswi_mean_raw,
    avg(clima_precipitacion_sum)::double precision AS raw_climate_precip_mean,
    avg(clima_eto_sum)::double precision AS raw_climate_eto_mean,
    avg(radar_asc_vv_promedio)::double precision AS radar_asc_vv_mean_raw,
    avg(radar_desc_vv_promedio)::double precision AS radar_desc_vv_mean_raw,
    avg(enso_oni)::double precision AS enso_oni_mean_raw
FROM public.tch_raw_longitudinal_v4
WHERE tch IS NOT NULL
  AND tch BETWEEN 20 AND 150
  AND ciclo_valido = true
  AND cod_cg_zafra IS NOT NULL
GROUP BY cod_cg_zafra;
CREATE INDEX ON base_cycles (cod_cg_zafra);
CREATE INDEX ON base_cycles (zafra_norm);

DROP TABLE IF EXISTS pg_temp.signal_values;
CREATE TEMP TABLE signal_values AS
SELECT
    cod_cg_zafra,
    zafra_norm,
    tch,
    v.feature_family,
    v.feature_name,
    v.feature_value
FROM base_cycles
CROSS JOIN LATERAL (
    VALUES
        ('coverage', 'raw_obs_count', raw_obs_count::double precision),
        ('coverage', 'optical_obs_count', optical_obs_count::double precision),
        ('coverage', 'radar_asc_obs_count', radar_asc_obs_count::double precision),
        ('coverage', 'radar_desc_obs_count', radar_desc_obs_count::double precision),
        ('coverage', 'raw_joined_climate_obs_count', raw_joined_climate_obs_count::double precision),
        ('coverage', 'enso_joined_obs_count', enso_joined_obs_count::double precision),
        ('source_proxy', 'ndvi_mean_raw', ndvi_mean_raw),
        ('source_proxy', 'lswi_mean_raw', lswi_mean_raw),
        ('source_proxy', 'raw_climate_precip_mean', raw_climate_precip_mean),
        ('source_proxy', 'raw_climate_eto_mean', raw_climate_eto_mean),
        ('source_proxy', 'radar_asc_vv_mean_raw', radar_asc_vv_mean_raw),
        ('source_proxy', 'radar_desc_vv_mean_raw', radar_desc_vv_mean_raw),
        ('source_proxy', 'enso_oni_mean_raw', enso_oni_mean_raw),
        ('interaction_proxy', 'lswi_x_precip_mean', lswi_mean_raw * raw_climate_precip_mean),
        ('interaction_proxy', 'ndvi_x_eto_mean', ndvi_mean_raw * raw_climate_eto_mean),
        ('interaction_proxy', 'radar_asc_vv_x_lswi', radar_asc_vv_mean_raw * lswi_mean_raw),
        ('interaction_proxy', 'enso_oni_x_precip_mean', enso_oni_mean_raw * raw_climate_precip_mean)
) AS v(feature_family, feature_name, feature_value);
CREATE INDEX ON signal_values (feature_name);
CREATE INDEX ON signal_values (zafra_norm);

DROP TABLE IF EXISTS pg_temp.signal_ranked;
CREATE TEMP TABLE signal_ranked AS
SELECT
    *,
    rank() OVER (PARTITION BY feature_name ORDER BY feature_value) AS feature_rank,
    rank() OVER (PARTITION BY feature_name ORDER BY tch) AS tch_rank
FROM signal_values
WHERE feature_value IS NOT NULL
  AND tch IS NOT NULL;

SELECT
    '01_source_coverage_by_zafra' AS diagnostic_block,
    zafra_norm,
    count(*) AS lote_zafras,
    round(avg(optical_obs_count)::numeric, 2) AS avg_optical_obs,
    round(avg(radar_asc_obs_count)::numeric, 2) AS avg_radar_asc_obs,
    round(avg(radar_desc_obs_count)::numeric, 2) AS avg_radar_desc_obs,
    round(avg(raw_joined_climate_obs_count)::numeric, 2) AS avg_joined_climate_obs,
    round(avg(enso_joined_obs_count)::numeric, 2) AS avg_enso_obs,
    round(avg(tch)::numeric, 2) AS avg_tch
FROM base_cycles
GROUP BY zafra_norm
ORDER BY zafra_norm;

SELECT
    '02_source_combination_coverage' AS diagnostic_block,
    zafra_norm,
    count(*) AS lote_zafras,
    sum((optical_obs_count > 0)::int) AS has_optical,
    sum(((radar_asc_obs_count + radar_desc_obs_count) > 0)::int) AS has_radar,
    sum((raw_joined_climate_obs_count > 0)::int) AS has_joined_climate,
    sum((enso_joined_obs_count > 0)::int) AS has_enso,
    sum((optical_obs_count > 0 AND (radar_asc_obs_count + radar_desc_obs_count) > 0)::int) AS has_optical_and_radar,
    sum((optical_obs_count > 0 AND raw_joined_climate_obs_count > 0)::int) AS has_optical_and_climate,
    sum((optical_obs_count > 0 AND (radar_asc_obs_count + radar_desc_obs_count) > 0 AND raw_joined_climate_obs_count > 0)::int) AS has_optical_radar_climate
FROM base_cycles
GROUP BY zafra_norm
ORDER BY zafra_norm;

SELECT
    '03_proxy_and_interaction_signal' AS diagnostic_block,
    feature_family,
    feature_name,
    count(*) AS rows_non_null,
    round(corr(feature_value, tch)::numeric, 4) AS pearson_tch,
    round(corr(feature_rank::double precision, tch_rank::double precision)::numeric, 4) AS spearman_tch,
    round(abs(corr(feature_rank::double precision, tch_rank::double precision))::numeric, 4) AS spearman_abs
FROM signal_ranked
GROUP BY feature_family, feature_name
HAVING count(*) >= 100
ORDER BY spearman_abs DESC NULLS LAST;

WITH by_group AS (
    SELECT
        'prod_no_corte' AS group_name,
        coalesce(prod_no_corte, '__MISSING__') AS group_value,
        count(*) AS rows_total,
        avg(tch) AS avg_tch,
        avg(ndvi_mean_raw) AS avg_ndvi,
        avg(lswi_mean_raw) AS avg_lswi,
        avg(raw_climate_precip_mean) AS avg_precip,
        avg(radar_asc_vv_mean_raw) AS avg_radar_asc_vv
    FROM base_cycles
    GROUP BY coalesce(prod_no_corte, '__MISSING__')
    HAVING count(*) >= 50

    UNION ALL

    SELECT
        'prod_grupo_de_humedad' AS group_name,
        coalesce(prod_grupo_de_humedad, '__MISSING__') AS group_value,
        count(*) AS rows_total,
        avg(tch) AS avg_tch,
        avg(ndvi_mean_raw) AS avg_ndvi,
        avg(lswi_mean_raw) AS avg_lswi,
        avg(raw_climate_precip_mean) AS avg_precip,
        avg(radar_asc_vv_mean_raw) AS avg_radar_asc_vv
    FROM base_cycles
    GROUP BY coalesce(prod_grupo_de_humedad, '__MISSING__')
    HAVING count(*) >= 50
)
SELECT
    '04_source_context_by_agronomic_group' AS diagnostic_block,
    group_name,
    group_value,
    rows_total,
    round(avg_tch::numeric, 4) AS avg_tch,
    round(avg_ndvi::numeric, 4) AS avg_ndvi,
    round(avg_lswi::numeric, 4) AS avg_lswi,
    round(avg_precip::numeric, 4) AS avg_precip,
    round(avg_radar_asc_vv::numeric, 4) AS avg_radar_asc_vv
FROM by_group
ORDER BY group_name, rows_total DESC;
