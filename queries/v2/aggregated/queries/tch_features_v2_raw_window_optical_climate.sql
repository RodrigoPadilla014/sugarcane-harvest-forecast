-- tch_features_v2_raw_window_optical_climate.sql
--
-- One-row-per-lot-zafra feature table sourced from the candidate v2 crop
-- window in queries/template/tch_raw_longitudinal_v2.sql.
--
-- This dataset is intended for the first SageMaker comparison job against
-- the current v1 feature tables. It uses the corrected pre-harvest STAC
-- window and drops anomalous TCH targets with:
--   NOT (tch < 20 OR tch > 150)

WITH raw_v2 AS (
    SELECT *
    FROM (
        -- Inline copy of the v2 raw template core. Keep this file in sync with
        -- queries/template/tch_raw_longitudinal_v2.sql when promoting v2.
        WITH base AS (
            SELECT
                p.lote AS cod_cg,
                s.fecha::date AS fecha_stac,
                s.imagen_id AS stac_imagen_id,
                s.zafra AS stac_zafra_norm,
                s.cod_cg_zafra AS stac_cod_cg_zafra,
                replace(regexp_replace(p.zafra, '^Zafra\s+', '', 'i'), '-', '_') AS zafra_norm,
                p.cod_cg_zafra,
                NULLIF(s.ndvi_promedio::text, 'NaN')::double precision AS stac_ndvi_promedio,
                NULLIF(s.evi2_promedio::text, 'NaN')::double precision AS stac_evi2_promedio,
                NULLIF(s.lswi_promedio::text, 'NaN')::double precision AS stac_lswi_promedio,
                NULLIF(s.gndvi_promedio::text, 'NaN')::double precision AS stac_gndvi_promedio,
                NULLIF(s.ndre_promedio::text, 'NaN')::double precision AS stac_ndre_promedio,
                p.area,
                p.tc,
                p.tch,
                p.variedad AS prod_variedad,
                p.grupo_de_suelo AS prod_grupo_de_suelo,
                p.grupo_de_humedad AS prod_grupo_de_humedad,
                p.codigo_zae AS prod_codigo_zae,
                p.finca AS prod_finca,
                p.familia_de_suelo AS prod_familia_de_suelo,
                p.no_corte AS prod_no_corte,
                p.edad AS prod_edad,
                p.cierre,
                to_date(p.cierre, 'DD/MM/YYYY') AS cierre_date
            FROM public.productividad p
            JOIN public.stac_indices s
              ON s.lote = p.lote
             AND s.fecha::date >= (
                    to_date(p.cierre, 'DD/MM/YYYY')
                    - make_interval(days => greatest(0, round((p.edad::double precision * 30.44))::integer))
                 )::date
             AND s.fecha::date <= to_date(p.cierre, 'DD/MM/YYYY')
            WHERE p.tch IS NOT NULL
              AND NOT (p.tch < 20 OR p.tch > 150)
              AND p.cierre IS NOT NULL
              AND p.edad IS NOT NULL
        ),
        with_age AS (
            SELECT
                b.*,
                (
                    b.cierre_date
                    - make_interval(days => greatest(0, round((b.prod_edad::double precision * 30.44))::integer))
                )::date AS fecha_inicio_estimada,
                b.cierre_date AS fecha_fin_objetivo,
                b.fecha_stac - (
                    b.cierre_date
                    - make_interval(days => greatest(0, round((b.prod_edad::double precision * 30.44))::integer))
                )::date AS edad_de_cultivo
            FROM base b
        ),
        cycle_stats AS (
            SELECT
                cod_cg_zafra,
                count(*) AS cycle_obs_count,
                max(edad_de_cultivo) AS cycle_age_max,
                min(stac_ndvi_promedio) AS ndvi_min,
                max(stac_ndvi_promedio) AS ndvi_max,
                (
                    array_agg(edad_de_cultivo ORDER BY stac_ndvi_promedio DESC NULLS LAST, fecha_stac)
                    FILTER (WHERE stac_ndvi_promedio IS NOT NULL)
                )[1] AS ndvi_age_at_peak
            FROM with_age
            GROUP BY cod_cg_zafra
        )
        SELECT
            w.*,
            w.fecha_fin_objetivo AS cierre_ciclo,
            false AS gap_in_data,
            (
                cs.cycle_obs_count >= 7
                AND cs.cycle_age_max >= 150
                AND (cs.ndvi_max - cs.ndvi_min) >= 0.35
                AND cs.ndvi_age_at_peak BETWEEN 45 AND 360
            ) AS ciclo_valido
        FROM with_age w
        JOIN cycle_stats cs USING (cod_cg_zafra)
    ) q
    WHERE ciclo_valido = true
),
base_cycles AS (
    SELECT
        cod_cg_zafra,
        max(cod_cg) AS cod_cg,
        max(zafra_norm) AS zafra_norm,
        max(area) AS area,
        max(tch) AS tch,
        max(tc) AS tc,
        min(fecha_inicio_estimada) AS fecha_inicio_ciclo,
        max(fecha_fin_objetivo) AS fecha_fin_ciclo,
        max(edad_de_cultivo) AS cycle_age_max,
        max(prod_variedad) AS prod_variedad,
        max(prod_grupo_de_suelo) AS prod_grupo_de_suelo,
        max(prod_grupo_de_humedad) AS prod_grupo_de_humedad,
        max(prod_codigo_zae) AS prod_codigo_zae,
        max(prod_finca) AS prod_finca,
        max(prod_familia_de_suelo) AS prod_familia_de_suelo,
        max(prod_no_corte) AS prod_no_corte,
        count(*) AS cycle_obs_count,
        count(*) FILTER (WHERE edad_de_cultivo < 120) AS early_obs_count,
        count(*) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS mid_obs_count,
        count(*) FILTER (WHERE edad_de_cultivo >= 240) AS late_obs_count,
        count(stac_ndvi_promedio) AS optical_obs_count,
        1.0 - (count(stac_ndvi_promedio)::double precision / nullif(count(*), 0)) AS optical_missing_rate
    FROM raw_v2
    GROUP BY cod_cg_zafra
),
optical_features AS (
    SELECT
        cod_cg_zafra,
        avg(stac_ndvi_promedio) FILTER (WHERE edad_de_cultivo < 120) AS ndvi_early_mean,
        avg(stac_ndvi_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS ndvi_mid_mean,
        avg(stac_ndvi_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS ndvi_late_mean,
        avg(stac_ndvi_promedio) AS ndvi_full_mean,
        max(stac_ndvi_promedio) AS ndvi_peak_value,
        min(stac_ndvi_promedio) AS ndvi_min_value,
        max(stac_ndvi_promedio) - min(stac_ndvi_promedio) AS ndvi_amplitude,
        (
            array_agg(edad_de_cultivo ORDER BY stac_ndvi_promedio DESC NULLS LAST, fecha_stac)
            FILTER (WHERE stac_ndvi_promedio IS NOT NULL)
        )[1] AS ndvi_age_at_peak,
        regr_slope(stac_ndvi_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo < 240) AS ndvi_rise_slope,
        regr_slope(stac_ndvi_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo >= 240) AS ndvi_senescence_slope,
        avg(stac_evi2_promedio) FILTER (WHERE edad_de_cultivo < 120) AS evi2_early_mean,
        avg(stac_evi2_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS evi2_mid_mean,
        avg(stac_evi2_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS evi2_late_mean,
        avg(stac_evi2_promedio) AS evi2_full_mean,
        max(stac_evi2_promedio) AS evi2_peak_value,
        regr_slope(stac_evi2_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo < 240) AS evi2_rise_slope,
        regr_slope(stac_evi2_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo >= 240) AS evi2_senescence_slope,
        avg(stac_lswi_promedio) FILTER (WHERE edad_de_cultivo < 120) AS lswi_early_mean,
        avg(stac_lswi_promedio) FILTER (WHERE edad_de_cultivo >= 120 AND edad_de_cultivo < 240) AS lswi_mid_mean,
        avg(stac_lswi_promedio) FILTER (WHERE edad_de_cultivo >= 240) AS lswi_late_mean,
        avg(stac_lswi_promedio) AS lswi_full_mean,
        max(stac_lswi_promedio) AS lswi_peak_value,
        regr_slope(stac_lswi_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo < 240) AS lswi_rise_slope,
        regr_slope(stac_lswi_promedio, edad_de_cultivo) FILTER (WHERE edad_de_cultivo >= 240) AS lswi_senescence_slope,
        avg(stac_gndvi_promedio) AS gndvi_full_mean,
        max(stac_gndvi_promedio) AS gndvi_peak_value,
        avg(stac_ndre_promedio) AS ndre_full_mean,
        max(stac_ndre_promedio) AS ndre_peak_value
    FROM raw_v2
    GROUP BY cod_cg_zafra
),
climate_features AS (
    SELECT
        b.cod_cg_zafra,
        count(c.*) AS climate_pentad_count,
        sum(c.precipitacion_sum) AS prec_full_total,
        sum(c.eto_sum) AS eto_full_total,
        sum(c.precipitacion_sum - c.eto_sum) AS water_balance_full_total,
        avg(c.temperatura_mean) AS tmean_full_mean,
        avg(c.temperatura_max) AS tmax_full_mean,
        avg(c.temperatura_min) AS tmin_full_mean,
        avg(c.humedad_relativa) AS rh_full_mean,
        sum(c.radiacion_sum) AS rad_full_total,
        count(*) FILTER (WHERE c.precipitacion_sum < 5) AS dry_pentad_count_full,
        count(*) FILTER (WHERE c.temperatura_max >= 34) AS heat_pentad_count_full
    FROM base_cycles b
    LEFT JOIN public.clima_lote_pentada_new c
      ON c.cod_cg = b.cod_cg
     AND c.fecha_inicio >= b.fecha_inicio_ciclo
     AND c.fecha_inicio <= b.fecha_fin_ciclo
    GROUP BY b.cod_cg_zafra
)
SELECT
    b.*,
    o.ndvi_early_mean,
    o.ndvi_mid_mean,
    o.ndvi_late_mean,
    o.ndvi_full_mean,
    o.ndvi_peak_value,
    o.ndvi_min_value,
    o.ndvi_amplitude,
    o.ndvi_age_at_peak,
    o.ndvi_rise_slope,
    o.ndvi_senescence_slope,
    o.evi2_early_mean,
    o.evi2_mid_mean,
    o.evi2_late_mean,
    o.evi2_full_mean,
    o.evi2_peak_value,
    o.evi2_rise_slope,
    o.evi2_senescence_slope,
    o.lswi_early_mean,
    o.lswi_mid_mean,
    o.lswi_late_mean,
    o.lswi_full_mean,
    o.lswi_peak_value,
    o.lswi_rise_slope,
    o.lswi_senescence_slope,
    o.gndvi_full_mean,
    o.gndvi_peak_value,
    o.ndre_full_mean,
    o.ndre_peak_value,
    c.climate_pentad_count,
    c.prec_full_total,
    c.eto_full_total,
    c.water_balance_full_total,
    c.tmean_full_mean,
    c.tmax_full_mean,
    c.tmin_full_mean,
    c.rh_full_mean,
    c.rad_full_total,
    c.dry_pentad_count_full,
    c.heat_pentad_count_full
FROM base_cycles b
JOIN optical_features o USING (cod_cg_zafra)
LEFT JOIN climate_features c USING (cod_cg_zafra);
