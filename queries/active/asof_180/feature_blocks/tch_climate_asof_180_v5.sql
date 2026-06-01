-- Climate block for v5 as-of-180.
-- Uses clima_lote_pentada_new only up to fecha_inicio_ciclo + 180 days.

WITH base_cycles AS (
    SELECT *
    FROM (
        SELECT
            r.cod_cg_zafra,
            max(r.cod_cg) AS cod_cg,
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
climate_seq AS (
    SELECT
        b.cod_cg_zafra,
        c.fecha_inicio::date AS clima_fecha_inicio,
        (c.fecha_inicio::date - b.fecha_inicio_ciclo)::double precision AS age_days,
        CASE
            WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 0 AND 90 THEN 'age_000_090'
            WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 91 AND 180 THEN 'age_091_180'
            ELSE 'outside'
        END AS age_window,
        NULLIF(c.precipitacion_sum::text, 'NaN')::double precision AS precip,
        NULLIF(c.eto_sum::text, 'NaN')::double precision AS eto,
        NULLIF(c.temperatura_mean::text, 'NaN')::double precision AS tmean,
        NULLIF(c.radiacion_sum::text, 'NaN')::double precision AS rad,
        NULLIF(c.precipitacion_sum::text, 'NaN')::double precision
            - NULLIF(c.eto_sum::text, 'NaN')::double precision AS water_balance
    FROM base_cycles b
    LEFT JOIN public.clima_lote_pentada_new c
      ON c.cod_cg = b.cod_cg
     AND c.fecha_inicio::date BETWEEN b.fecha_inicio_ciclo
                                  AND (b.fecha_inicio_ciclo + INTERVAL '180 days')::date
)
SELECT
    cod_cg_zafra,
    count(clima_fecha_inicio)::double precision AS climate_pentad_count_0_180,
    sum(precip) AS climate_precip_acc_0_180,
    sum(precip) FILTER (WHERE age_window = 'age_000_090') AS climate_precip_acc_0_90,
    sum(precip) FILTER (WHERE age_window = 'age_091_180') AS climate_precip_acc_91_180,
    sum(eto) AS climate_eto_acc_0_180,
    sum(water_balance) AS climate_water_balance_acc_0_180,
    sum(precip) / NULLIF(sum(eto), 0) AS climate_water_ratio_0_180,
    sum(rad) AS climate_rad_acc_0_180,
    sum(greatest(tmean - 10.0, 0.0) * 5.0) AS climate_gdd_10c_acc_0_180,
    avg(tmean) AS climate_tmean_mean_0_180,
    regr_slope(water_balance, age_days) AS climate_water_balance_slope_0_180
FROM climate_seq
GROUP BY cod_cg_zafra;
