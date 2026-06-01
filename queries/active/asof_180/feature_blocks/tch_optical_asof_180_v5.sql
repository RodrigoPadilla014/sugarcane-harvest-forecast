-- Optical/STAC block for v5 as-of-180.
-- The final training query embeds this block and pivots selected candidate
-- summaries to wide columns. This standalone file keeps the intended source
-- boundary explicit.

WITH base_cycles AS (
    SELECT *
    FROM (
        SELECT
            r.cod_cg_zafra,
            min(r.fecha_inicio_estimada)::date AS fecha_inicio_ciclo,
            max(r.edad_de_cultivo)::double precision AS cycle_age_max
        FROM public.tch_raw_longitudinal_v4 r
        WHERE r.tch IS NOT NULL
          AND r.tch BETWEEN 20 AND 150
          AND r.ciclo_valido = true
          AND r.cod_cg_zafra IS NOT NULL
          AND r.zafra_norm <> '2019_2020'
        GROUP BY r.cod_cg_zafra
    ) b
    WHERE cycle_age_max >= 180
),
optical_long AS (
    SELECT
        b.cod_cg_zafra,
        r.fecha_stac::date AS fecha_obs,
        r.edad_de_cultivo::double precision AS age_days,
        CASE
            WHEN r.edad_de_cultivo BETWEEN 0 AND 90 THEN 'age_000_090'
            WHEN r.edad_de_cultivo BETWEEN 91 AND 180 THEN 'age_091_180'
            ELSE 'outside'
        END AS age_window,
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
            ('lswi', NULLIF(r.stac_lswi_promedio::text, 'NaN')::double precision),
            ('ndvire', NULLIF(r.stac_ndvire_promedio::text, 'NaN')::double precision),
            ('cire', NULLIF(r.stac_cire_promedio::text, 'NaN')::double precision),
            ('ndwi11', NULLIF(r.stac_ndwi11_promedio::text, 'NaN')::double precision),
            ('msi11', NULLIF(r.stac_msi11_promedio::text, 'NaN')::double precision)
    ) AS v(index_name, index_value)
    WHERE r.ciclo_valido = true
      AND r.edad_de_cultivo BETWEEN 0 AND 180
)
SELECT
    cod_cg_zafra,
    index_name,
    count(index_value)::double precision AS obs_count_0_180,
    avg(index_value) AS mean_0_180,
    avg(index_value) FILTER (WHERE age_window = 'age_000_090') AS mean_0_90,
    avg(index_value) FILTER (WHERE age_window = 'age_091_180') AS mean_91_180,
    max(index_value) AS peak_0_180,
    min(index_value) AS min_0_180,
    max(index_value) - min(index_value) AS amplitude_0_180,
    regr_slope(index_value, age_days) AS slope_0_180
FROM optical_long
GROUP BY cod_cg_zafra, index_name;
