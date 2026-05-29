-- tch_raw_longitudinal_v4.sql
--
-- Candidate raw longitudinal v4 template.
--
-- Builds on v3 (shape-based phenology gate) and rescues contaminated cycles
-- by clipping the window start when a previous cierre exists on the same lote.
--
-- Window logic:
--   baseline_start = cierre_date - prod_edad * 30.44 days
--   fecha_inicio_v4 = MAX(baseline_start, prev_cierre + 21d)   -- if prev exists
--                   = baseline_start                            -- otherwise
--   e1_applied = true when the clip actually moved the start forward.
--
-- Phenology gate (adaptive):
--   If e1_applied = true  → skip ndvi_first_60d check (contamination removed
--                            by the clip; high first_60d is normal regrowth)
--   If e1_applied = false → full v3 E3 gate including ndvi_first_60d < 0.35
--
-- In both cases the remaining shape criteria apply:
--   cycle_ndvi_obs_count >= 7
--   ndvi_max  > 0.60
--   ndvi_amp  > 0.40
--   rel_peak_pos BETWEEN 0.25 AND 0.95
--
-- New output columns vs v3:
--   e1_applied        -- true when window start was clipped by prev_cierre
--   start_contaminado -- true when e1 not applied AND ndvi_first_60d >= 0.35
--
-- Experiment result (queries/diagnostics/v4_rescue_experiment.sql):
--   v3 valid: 29,052  →  v4 valid: 30,874  (+1,822 net; 12,046 rescued)
--   Rescued lots: avg_peak=0.814, avg_amp=0.812, avg_tch=101.6 (no bias)
--
-- TCH bounds unchanged: NOT (tch < 20 OR tch > 150).
--
-- To recreate manually:
-- CREATE MATERIALIZED VIEW public.tch_raw_longitudinal_v4 AS

WITH prod_source AS (
         SELECT
            p.*,
            CASE
                WHEN p.cierre::text ~ '^\d{4}-\d{2}-\d{2}$' THEN to_date(p.cierre::text, 'YYYY-MM-DD'::text)
                WHEN p.cierre::text ~ '^\d{2}/\d{2}/\d{4}$' THEN to_date(p.cierre::text, 'DD/MM/YYYY'::text)
                ELSE NULL::date
            END AS cierre_date
           FROM productividad p
        ), prod_windows AS (
         SELECT
            lote,
            cod_cg_zafra,
            tch,
            edad,
            cierre,
            zafra,
            cierre_date,
            (cierre_date
              - make_interval(days => greatest(0, round((edad::double precision * 30.44))::integer))
            )::date AS fecha_inicio_baseline,
            lag(cierre_date)
                OVER (PARTITION BY lote ORDER BY cierre_date)
                AS prev_cierre_date
           FROM prod_source
          WHERE tch IS NOT NULL
            AND NOT (tch < 20 OR tch > 150)
            AND cierre IS NOT NULL
            AND cierre_date IS NOT NULL
            AND edad IS NOT NULL
        ), prod_v4 AS (
         SELECT
            pw.*,
            GREATEST(
                pw.fecha_inicio_baseline,
                COALESCE((pw.prev_cierre_date + INTERVAL '21 day')::date, pw.fecha_inicio_baseline)
            ) AS fecha_inicio_v4,
            (pw.prev_cierre_date IS NOT NULL
             AND (pw.prev_cierre_date + INTERVAL '21 day')::date > pw.fecha_inicio_baseline
            ) AS e1_applied
           FROM prod_windows pw
        ), base AS (
         SELECT p.lote AS cod_cg,
            s.fecha::date AS fecha_stac,
            s.imagen_id AS stac_imagen_id,
            s.zafra AS stac_zafra_norm,
            s.cod_cg_zafra AS stac_cod_cg_zafra,
            replace(regexp_replace(p.zafra, '^Zafra\s+', '', 'i'), '-', '_') AS zafra_norm,
            p.cod_cg_zafra,
            pv.fecha_inicio_v4,
            pv.e1_applied,
            NULLIF(s.ndvi_promedio::text, 'NaN')::double precision AS ndvi_promedio,
            NULLIF(s.ndvi_max::text, 'NaN')::double precision AS ndvi_max,
            NULLIF(s.ndvi_min::text, 'NaN')::double precision AS ndvi_min,
            NULLIF(s.ndvi_std::text, 'NaN')::double precision AS ndvi_std,
            NULLIF(s.ndwi11_promedio::text, 'NaN')::double precision AS ndwi11_promedio,
            NULLIF(s.ndwi11_max::text, 'NaN')::double precision AS ndwi11_max,
            NULLIF(s.ndwi11_min::text, 'NaN')::double precision AS ndwi11_min,
            NULLIF(s.ndwi11_std::text, 'NaN')::double precision AS ndwi11_std,
            NULLIF(s.msi11_promedio::text, 'NaN')::double precision AS msi11_promedio,
            NULLIF(s.msi11_max::text, 'NaN')::double precision AS msi11_max,
            NULLIF(s.msi11_min::text, 'NaN')::double precision AS msi11_min,
            NULLIF(s.msi11_std::text, 'NaN')::double precision AS msi11_std,
            NULLIF(s.evi2_promedio::text, 'NaN')::double precision AS evi2_promedio,
            NULLIF(s.evi2_max::text, 'NaN')::double precision AS evi2_max,
            NULLIF(s.evi2_min::text, 'NaN')::double precision AS evi2_min,
            NULLIF(s.evi2_std::text, 'NaN')::double precision AS evi2_std,
            NULLIF(s.lswi_promedio::text, 'NaN')::double precision AS lswi_promedio,
            NULLIF(s.lswi_max::text, 'NaN')::double precision AS lswi_max,
            NULLIF(s.lswi_min::text, 'NaN')::double precision AS lswi_min,
            NULLIF(s.lswi_std::text, 'NaN')::double precision AS lswi_std,
            NULLIF(s.gndvi_promedio::text, 'NaN')::double precision AS gndvi_promedio,
            NULLIF(s.gndvi_max::text, 'NaN')::double precision AS gndvi_max,
            NULLIF(s.gndvi_min::text, 'NaN')::double precision AS gndvi_min,
            NULLIF(s.gndvi_std::text, 'NaN')::double precision AS gndvi_std,
            NULLIF(s.ndre_promedio::text, 'NaN')::double precision AS ndre_promedio,
            NULLIF(s.ndre_max::text, 'NaN')::double precision AS ndre_max,
            NULLIF(s.ndre_min::text, 'NaN')::double precision AS ndre_min,
            NULLIF(s.ndre_std::text, 'NaN')::double precision AS ndre_std,
            NULLIF(s.ndvire_promedio::text, 'NaN')::double precision AS ndvire_promedio,
            NULLIF(s.ndvire_max::text, 'NaN')::double precision AS ndvire_max,
            NULLIF(s.ndvire_min::text, 'NaN')::double precision AS ndvire_min,
            NULLIF(s.ndvire_std::text, 'NaN')::double precision AS ndvire_std,
            NULLIF(s.cire_promedio::text, 'NaN')::double precision AS cire_promedio,
            NULLIF(s.cire_max::text, 'NaN')::double precision AS cire_max,
            NULLIF(s.cire_min::text, 'NaN')::double precision AS cire_min,
            NULLIF(s.cire_std::text, 'NaN')::double precision AS cire_std,
            p.ingenio AS prod_ingenio,
            p.zafra AS prod_zafra,
            p.zae AS prod_zae,
            p.grupo_de_suelo AS prod_grupo_de_suelo,
            p.grupo_de_humedad AS prod_grupo_de_humedad,
            p.codigo_zae AS prod_codigo_zae,
            p.lote AS prod_lote,
            p.semana AS prod_semana,
            p.finca AS prod_finca,
            p.familia_de_suelo AS prod_familia_de_suelo,
            p.variedad AS prod_variedad,
            p.area,
            p.tc,
            p.tch,
            p.rendimiento AS prod_rendimiento,
            p.tah AS prod_tah,
            p.brix AS prod_brix,
            p.pureza AS prod_pureza,
            p.jugo AS prod_jugo,
            p.ph AS prod_ph,
            p.pol AS prod_pol,
            p.fibra AS prod_fibra,
            p.humedad AS prod_humedad,
            p.edad AS prod_edad,
            p.no_corte AS prod_no_corte,
            p.nitrogeno AS prod_nitrogeno,
            p.potasio AS prod_potasio,
            p.fosforo AS prod_fosforo,
            p.cachaza AS prod_cachaza,
            p.vinaza AS prod_vinaza,
            p.sulfato AS prod_sulfato,
            p.urea_nitro_exted AS prod_urea_nitro_exted,
            p.aplicaciones_foliares AS prod_aplicaciones_foliares,
            p.riego AS prod_riego,
            p.total_riego_aplicado_mm AS prod_total_riego_aplicado_mm,
            p.numero_de_riegos AS prod_numero_de_riegos,
            p.dias_ultimo_riego AS prod_dias_ultimo_riego,
            p.pre_incorporado AS prod_pre_incorporado,
            p.pre_emergente AS prod_pre_emergente,
            p.post_emergente AS prod_post_emergente,
            p.pre_post_emergente AS prod_pre_post_emergente,
            p.ultimo_control_de_malezas AS prod_ultimo_control_de_malezas,
            p.bejuco AS prod_bejuco,
            p.parchoneo AS prod_parchoneo,
            p.arranque AS prod_arranque,
            p.tipo_aplicacion_control_malezas AS prod_tipo_aplicacion_control_malezas,
            p.precipitacion AS prod_precipitacion,
            p.temp_minima AS prod_temp_minima,
            p.radiacion_solar AS prod_radiacion_solar,
            p.inhibidor_de_floracion AS prod_inhibidor_de_floracion,
            p.premadurante AS prod_premadurante,
            p.madurante AS prod_madurante,
            p.tipo_de_aplicacion_madurante AS prod_tipo_de_aplicacion_madurante,
            p.dias_madurantes AS prod_dias_madurantes,
            p.horas_quema AS prod_horas_quema,
            p.tipo_quema AS prod_tipo_quema,
            p.para_cosecha_en_verde AS prod_para_cosecha_en_verde,
            p.cierre,
            pv.cierre_date,
            p.mes_de_cosecha AS prod_mes_de_cosecha,
            p.cosecha AS prod_cosecha,
            p.de_infestacion_barrenador AS prod_de_infestacion_barrenador,
            p.tipo_de_control_para_barrenador AS prod_tipo_de_control_para_barrenador,
            p.de_infestacion_de_roedores AS prod_de_infestacion_de_roedores,
            p.tipo_de_control_para_roedores AS prod_tipo_de_control_para_roedores,
            p.chinche_salivosa_ninfas_tallo AS prod_chinche_salivosa_ninfas_tallo,
            p.chinche_salivosa_adultos_tallo AS prod_chinche_salivosa_adultos_tallo,
            p.tipo_de_control_de_chinche AS prod_tipo_de_control_de_chinche,
            p.latitud AS prod_latitud,
            p.longitud AS prod_longitud,
            p.zona_longitudinal AS prod_zona_longitudinal,
            p.estrato AS prod_estrato,
            p.ultima_imagen AS prod_ultima_imagen
           FROM productividad p
             JOIN prod_v4 pv ON pv.cod_cg_zafra = p.cod_cg_zafra
             JOIN stac_indices s ON s.lote = p.lote
              AND s.fecha::date >= pv.fecha_inicio_v4
              AND s.fecha::date <= pv.cierre_date
          WHERE p.tch IS NOT NULL
            AND NOT (p.tch < 20 OR p.tch > 150)
            AND p.cierre IS NOT NULL
            AND p.edad IS NOT NULL
), windowed AS (
         SELECT b.*,
            b.cierre_date AS fecha_fin_objetivo,
            b.fecha_inicio_v4 AS fecha_inicio_estimada,
            b.fecha_stac <= b.cierre_date AS dentro_de_cierre,
            (b.fecha_stac >= b.fecha_inicio_v4 AND b.fecha_stac <= b.cierre_date) AS dentro_ventana_cultivo
           FROM base b
        ), with_age AS (
         SELECT w.*,
            CASE
                WHEN w.dentro_ventana_cultivo THEN w.fecha_stac - w.fecha_inicio_estimada
                ELSE NULL::integer
            END AS edad_de_cultivo
           FROM windowed w
          WHERE w.dentro_ventana_cultivo
        ), cycle_stats AS (
         SELECT with_age.cod_cg_zafra,
            count(*) AS cycle_obs_count,
            count(with_age.ndvi_promedio) AS cycle_ndvi_obs_count,
            max(with_age.edad_de_cultivo) AS max_edad_de_cultivo,
            max(with_age.fecha_fin_objetivo - with_age.fecha_inicio_estimada) AS window_days,
            bool_or(with_age.e1_applied) AS e1_applied,
            min(with_age.ndvi_promedio) AS ndvi_min,
            max(with_age.ndvi_promedio) AS ndvi_max,
            avg(with_age.ndvi_promedio) FILTER (
                WHERE with_age.edad_de_cultivo IS NOT NULL
                  AND with_age.edad_de_cultivo <= 60
            ) AS ndvi_first_60d,
            avg(with_age.ndvi_promedio) FILTER (
                WHERE with_age.edad_de_cultivo IS NOT NULL
                  AND with_age.edad_de_cultivo
                      >= (with_age.fecha_fin_objetivo - with_age.fecha_inicio_estimada) - 30
            ) AS ndvi_last_30d,
            regr_slope(with_age.ndvi_promedio, with_age.edad_de_cultivo) FILTER (WHERE with_age.edad_de_cultivo BETWEEN 0 AND 240) AS ndvi_rise_slope,
            (array_agg(with_age.edad_de_cultivo ORDER BY with_age.ndvi_promedio DESC NULLS LAST, with_age.fecha_stac) FILTER (WHERE with_age.ndvi_promedio IS NOT NULL))[1] AS edad_en_pico_ndvi
           FROM with_age
          GROUP BY with_age.cod_cg_zafra
        ), phenology AS (
         SELECT cycle_stats.*,
            cycle_stats.ndvi_max - cycle_stats.ndvi_min AS ndvi_amplitud,
            CASE
                WHEN cycle_stats.window_days IS NULL OR cycle_stats.window_days = 0 THEN NULL
                ELSE cycle_stats.edad_en_pico_ndvi::double precision / cycle_stats.window_days::double precision
            END AS rel_peak_pos,
            CASE
                WHEN cycle_stats.cycle_obs_count >= 7 AND cycle_stats.max_edad_de_cultivo >= 150 THEN true
                ELSE false
            END AS ciclo_valido_basico,
            CASE
                WHEN cycle_stats.cycle_ndvi_obs_count >= 7
                 AND cycle_stats.ndvi_max > 0.60::double precision
                 AND (cycle_stats.ndvi_max - cycle_stats.ndvi_min) > 0.40::double precision
                 AND cycle_stats.window_days IS NOT NULL
                 AND cycle_stats.window_days > 0
                 AND (cycle_stats.edad_en_pico_ndvi::double precision
                      / cycle_stats.window_days::double precision)
                     BETWEEN 0.25 AND 0.95
                 AND (cycle_stats.e1_applied
                      OR (cycle_stats.ndvi_first_60d IS NOT NULL
                          AND cycle_stats.ndvi_first_60d < 0.35::double precision))
                THEN true
                ELSE false
            END AS phenology_valid,
            -- start_contaminado: window not clipped (no prev_cierre) but early
            -- NDVI is high, suggesting prior-cycle bleed still present.
            (NOT cycle_stats.e1_applied
             AND cycle_stats.ndvi_first_60d IS NOT NULL
             AND cycle_stats.ndvi_first_60d >= 0.35::double precision
            ) AS start_contaminado
           FROM cycle_stats
        )
 SELECT w.cod_cg,
    w.zafra_norm,
    w.cod_cg_zafra,
    w.fecha_stac,
    w.stac_imagen_id,
    w.tch,
    w.tc,
    w.area,
    w.fecha_fin_objetivo AS cierre_ciclo,
    w.edad_de_cultivo,
    false AS gap_in_data,
    (p.ciclo_valido_basico AND p.phenology_valid) AS ciclo_valido,
    p.ciclo_valido_basico,
    p.phenology_valid,
    p.ndvi_amplitud,
    p.edad_en_pico_ndvi,
    p.ndvi_first_60d,
    p.ndvi_last_30d,
    p.rel_peak_pos,
    p.e1_applied,
    p.start_contaminado,
    w.fecha_inicio_estimada,
    w.fecha_fin_objetivo,
    w.stac_zafra_norm,
    w.stac_cod_cg_zafra,
    w.dentro_ventana_cultivo,
    w.dentro_de_cierre,
    w.ndvi_promedio AS stac_ndvi_promedio,
    w.ndvi_max AS stac_ndvi_max,
    w.ndvi_min AS stac_ndvi_min,
    w.ndvi_std AS stac_ndvi_std,
    w.ndwi11_promedio AS stac_ndwi11_promedio,
    w.ndwi11_max AS stac_ndwi11_max,
    w.ndwi11_min AS stac_ndwi11_min,
    w.ndwi11_std AS stac_ndwi11_std,
    w.msi11_promedio AS stac_msi11_promedio,
    w.msi11_max AS stac_msi11_max,
    w.msi11_min AS stac_msi11_min,
    w.msi11_std AS stac_msi11_std,
    w.evi2_promedio AS stac_evi2_promedio,
    w.evi2_max AS stac_evi2_max,
    w.evi2_min AS stac_evi2_min,
    w.evi2_std AS stac_evi2_std,
    w.lswi_promedio AS stac_lswi_promedio,
    w.lswi_max AS stac_lswi_max,
    w.lswi_min AS stac_lswi_min,
    w.lswi_std AS stac_lswi_std,
    w.gndvi_promedio AS stac_gndvi_promedio,
    w.gndvi_max AS stac_gndvi_max,
    w.gndvi_min AS stac_gndvi_min,
    w.gndvi_std AS stac_gndvi_std,
    w.ndre_promedio AS stac_ndre_promedio,
    w.ndre_max AS stac_ndre_max,
    w.ndre_min AS stac_ndre_min,
    w.ndre_std AS stac_ndre_std,
    w.ndvire_promedio AS stac_ndvire_promedio,
    w.ndvire_max AS stac_ndvire_max,
    w.ndvire_min AS stac_ndvire_min,
    w.ndvire_std AS stac_ndvire_std,
    w.cire_promedio AS stac_cire_promedio,
    w.cire_max AS stac_cire_max,
    w.cire_min AS stac_cire_min,
    w.cire_std AS stac_cire_std,
    c.fecha_inicio AS clima_fecha_inicio,
    c.fecha_fin AS clima_fecha_fin,
    c.anio AS clima_anio,
    c.mes AS clima_mes,
    c.num_pentada AS clima_num_pentada,
    c.precipitacion_sum AS clima_precipitacion_sum,
    c.eto_sum AS clima_eto_sum,
    c.temperatura_max AS clima_temperatura_max,
    c.temperatura_min AS clima_temperatura_min,
    c.temperatura_mean AS clima_temperatura_mean,
    c.humedad_relativa AS clima_humedad_relativa,
    c.radiacion_sum AS clima_radiacion_sum,
    c.radiacion_mean AS clima_radiacion_mean,
    c.indice_calor_max AS clima_indice_calor_max,
    c.mojadura_mean AS clima_mojadura_mean,
    w.fecha_stac - c.fecha_inicio AS clima_days_delta,
    e.date AS enso_date,
    e.roni AS enso_roni,
    e.oni AS enso_oni,
    e.nino34 AS enso_nino34,
    e.nino3 AS enso_nino3,
    e.nino12 AS enso_nino12,
    e.nino4 AS enso_nino4,
    e.soi AS enso_soi,
    e.mei AS enso_mei,
    e.pdo AS enso_pdo,
    e.amo AS enso_amo,
    ra.fecha AS radar_asc_fecha,
    ra.fecha - w.fecha_stac AS radar_asc_days_delta,
    ra.imagen_id AS radar_asc_imagen_id,
    ra.rvi_promedio AS radar_asc_rvi_promedio,
    ra.rvi_max AS radar_asc_rvi_max,
    ra.rvi_min AS radar_asc_rvi_min,
    ra.rvi_std AS radar_asc_rvi_std,
    ra.ratio_promedio AS radar_asc_ratio_promedio,
    ra.ratio_max AS radar_asc_ratio_max,
    ra.ratio_min AS radar_asc_ratio_min,
    ra.ratio_std AS radar_asc_ratio_std,
    ra.nrb_promedio AS radar_asc_nrb_promedio,
    ra.nrb_max AS radar_asc_nrb_max,
    ra.nrb_min AS radar_asc_nrb_min,
    ra.nrb_std AS radar_asc_nrb_std,
    ra.rfdi_promedio AS radar_asc_rfdi_promedio,
    ra.rfdi_max AS radar_asc_rfdi_max,
    ra.rfdi_min AS radar_asc_rfdi_min,
    ra.rfdi_std AS radar_asc_rfdi_std,
    ra.vh_promedio AS radar_asc_vh_promedio,
    ra.vh_max AS radar_asc_vh_max,
    ra.vh_min AS radar_asc_vh_min,
    ra.vh_std AS radar_asc_vh_std,
    ra.vv_promedio AS radar_asc_vv_promedio,
    ra.vv_max AS radar_asc_vv_max,
    ra.vv_min AS radar_asc_vv_min,
    ra.vv_std AS radar_asc_vv_std,
    rd.fecha AS radar_desc_fecha,
    rd.fecha - w.fecha_stac AS radar_desc_days_delta,
    rd.imagen_id AS radar_desc_imagen_id,
    rd.rvi_promedio AS radar_desc_rvi_promedio,
    rd.rvi_max AS radar_desc_rvi_max,
    rd.rvi_min AS radar_desc_rvi_min,
    rd.rvi_std AS radar_desc_rvi_std,
    rd.ratio_promedio AS radar_desc_ratio_promedio,
    rd.ratio_max AS radar_desc_ratio_max,
    rd.ratio_min AS radar_desc_ratio_min,
    rd.ratio_std AS radar_desc_ratio_std,
    rd.nrb_promedio AS radar_desc_nrb_promedio,
    rd.nrb_max AS radar_desc_nrb_max,
    rd.nrb_min AS radar_desc_nrb_min,
    rd.nrb_std AS radar_desc_nrb_std,
    rd.rfdi_promedio AS radar_desc_rfdi_promedio,
    rd.rfdi_max AS radar_desc_rfdi_max,
    rd.rfdi_min AS radar_desc_rfdi_min,
    rd.rfdi_std AS radar_desc_rfdi_std,
    rd.vh_promedio AS radar_desc_vh_promedio,
    rd.vh_max AS radar_desc_vh_max,
    rd.vh_min AS radar_desc_vh_min,
    rd.vh_std AS radar_desc_vh_std,
    rd.vv_promedio AS radar_desc_vv_promedio,
    rd.vv_max AS radar_desc_vv_max,
    rd.vv_min AS radar_desc_vv_min,
    rd.vv_std AS radar_desc_vv_std,
    NULLIF(upper(regexp_replace(trim(w.prod_ingenio), '\s+', ' ', 'g')), '') AS prod_ingenio,
    NULLIF(regexp_replace(trim(w.prod_zafra), '\s+', ' ', 'g'), '') AS prod_zafra,
    w.prod_zae,
    NULLIF(upper(regexp_replace(trim(w.prod_grupo_de_suelo), '\s+', ' ', 'g')), '') AS prod_grupo_de_suelo,
    NULLIF(upper(regexp_replace(trim(w.prod_grupo_de_humedad), '\s+', ' ', 'g')), '') AS prod_grupo_de_humedad,
    NULLIF(upper(regexp_replace(trim(w.prod_codigo_zae), '\s+', ' ', 'g')), '') AS prod_codigo_zae,
    w.prod_lote,
    NULLIF(
        upper(regexp_replace(replace(trim(w.prod_finca), '_', ' '), '\s+', ' ', 'g')),
        ''
    ) AS prod_finca,
    NULLIF(
        regexp_replace(
            regexp_replace(
                trim(regexp_replace(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(
                                regexp_replace(
                                    upper(regexp_replace(trim(w.prod_familia_de_suelo), '\s+', ' ', 'g')),
                                    'ESQULETAL|ESQUETAL|ESQLETAL',
                                    'ESQUELETAL',
                                    'g'
                                ),
                                'FRNACA',
                                'FRANCA',
                                'g'
                            ),
                            '\m(TYPIC|FLUVENTIC|PACHIC|THAPTIC|LITHIC|VERTIC|VERTYC|ANDIC|AQUIC|EUTRIC|FLUVIC|CUMULIC|SALORTHIDIC|SOLORTHIDIC|HAPLUDANDS|HAPPLUDANDS|HAPLUDANS|HAPLUDOLLS|HAPLUSTOLLS|DYSTROPEPTS|PELLUDERTS|FULVUDANDS|HUMITROPEPTS|HUMITROPEPS|EUTROPEPTS|USTIPSAMMENTS|USTIFLUVENTS|TROPORTHENTS|MELANUDANDS|TROPOFLUVENTS|HAPLUDALFS|FINCA)\M',
                            '',
                            'g'
                        ),
                        '\s+Y\s+',
                        ' + ',
                        'g'
                    ),
                    '\s+',
                    ' ',
                    'g'
                )),
                '^\+\s*',
                '',
                'g'
            ),
            '\s*\+$',
            '',
            'g'
        ),
        ''
    ) AS prod_familia_de_suelo,
    NULLIF(upper(regexp_replace(trim(w.prod_variedad), '\s+', ' ', 'g')), '') AS prod_variedad,
    NULLIF(regexp_replace(trim(w.prod_no_corte), '\s+', ' ', 'g'), '') AS prod_no_corte,
    NULLIF(regexp_replace(trim(w.prod_cosecha), '\s+', ' ', 'g'), '') AS prod_cosecha
   FROM with_age w
     JOIN phenology p USING (cod_cg_zafra)
     LEFT JOIN LATERAL ( SELECT c_1.cod_cg,
            c_1.fecha_inicio,
            c_1.fecha_fin,
            c_1.anio,
            c_1.mes,
            c_1.num_pentada,
            c_1.precipitacion_sum,
            c_1.eto_sum,
            c_1.temperatura_max,
            c_1.temperatura_min,
            c_1.temperatura_mean,
            c_1.humedad_relativa,
            c_1.radiacion_sum,
            c_1.radiacion_mean,
            c_1.indice_calor_max,
            c_1.mojadura_mean,
            c_1.fase_enso,
            c_1.oni,
            c_1.cargado_en,
            c_1.zafra,
            c_1.cod_cg_zafra
           FROM clima_lote_pentada_new c_1
          WHERE c_1.cod_cg = w.cod_cg AND c_1.fecha_inicio <= w.fecha_stac
          ORDER BY c_1.fecha_inicio DESC
         LIMIT 1) c ON true
     LEFT JOIN enso e ON e.year = EXTRACT(year FROM w.fecha_stac)::bigint AND e.month = EXTRACT(month FROM w.fecha_stac)::bigint
     LEFT JOIN LATERAL ( SELECT r.lote,
            r.fecha,
            r.imagen_id,
            r.orbit_pass,
            r.rvi_promedio,
            r.rvi_max,
            r.rvi_min,
            r.rvi_std,
            r.ratio_promedio,
            r.ratio_max,
            r.ratio_min,
            r.ratio_std,
            r.nrb_promedio,
            r.nrb_max,
            r.nrb_min,
            r.nrb_std,
            r.rfdi_promedio,
            r.rfdi_max,
            r.rfdi_min,
            r.rfdi_std,
            r.vh_promedio,
            r.vh_max,
            r.vh_min,
            r.vh_std,
            r.vv_promedio,
            r.vv_max,
            r.vv_min,
            r.vv_std,
            r.zafra,
            r.cod_cg_zafra
           FROM radar r
          WHERE r.lote = w.cod_cg AND r.orbit_pass = 'ASCENDING'::text AND r.fecha >= (w.fecha_stac - '6 days'::interval) AND r.fecha <= (w.fecha_stac + '6 days'::interval)
          ORDER BY (abs(r.fecha - w.fecha_stac)), r.fecha DESC
         LIMIT 1) ra ON true
     LEFT JOIN LATERAL ( SELECT r.lote,
            r.fecha,
            r.imagen_id,
            r.orbit_pass,
            r.rvi_promedio,
            r.rvi_max,
            r.rvi_min,
            r.rvi_std,
            r.ratio_promedio,
            r.ratio_max,
            r.ratio_min,
            r.ratio_std,
            r.nrb_promedio,
            r.nrb_max,
            r.nrb_min,
            r.nrb_std,
            r.rfdi_promedio,
            r.rfdi_max,
            r.rfdi_min,
            r.rfdi_std,
            r.vh_promedio,
            r.vh_max,
            r.vh_min,
            r.vh_std,
            r.vv_promedio,
            r.vv_max,
            r.vv_min,
            r.vv_std,
            r.zafra,
            r.cod_cg_zafra
           FROM radar r
          WHERE r.lote = w.cod_cg AND r.orbit_pass = 'DESCENDING'::text AND r.fecha >= (w.fecha_stac - '6 days'::interval) AND r.fecha <= (w.fecha_stac + '6 days'::interval)
          ORDER BY (abs(r.fecha - w.fecha_stac)), r.fecha DESC
         LIMIT 1) rd ON true;
