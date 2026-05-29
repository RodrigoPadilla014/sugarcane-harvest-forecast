"""Run as-of-180 feature diagnostics and export CSV artifacts.

This script creates only PostgreSQL temporary tables. It does not create or
modify permanent database objects and does not upload datasets.
"""
from __future__ import annotations

import argparse
import os
import time
from pathlib import Path

import pandas as pd
import psycopg2
from dotenv import load_dotenv
from sshtunnel import SSHTunnelForwarder


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_OUTPUT_DIR = ROOT / ".tmp" / "asof_180_feature_diagnostics"


def connect_with_tunnel():
    load_dotenv(ROOT / "credentials" / ".env")
    ssh_key = ROOT / "credentials" / "eagriculturai_key.pem"

    tunnel = SSHTunnelForwarder(
        (os.environ["SSH_HOST"], int(os.environ["SSH_PORT"])),
        ssh_username=os.environ["SSH_USER"],
        ssh_pkey=str(ssh_key),
        remote_bind_address=(os.environ["DB_HOST"], int(os.environ["DB_PORT"])),
    )
    tunnel.start()
    conn = psycopg2.connect(
        host="127.0.0.1",
        port=tunnel.local_bind_port,
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )
    return tunnel, conn


def execute(cur, sql: str, label: str) -> None:
    t0 = time.time()
    cur.execute(sql)
    print(f"{label}: {time.time() - t0:.1f}s", flush=True)


def export_query(conn, sql: str, path: Path) -> None:
    t0 = time.time()
    df = pd.read_sql_query(sql, conn)
    df.to_csv(path, index=False)
    print(f"wrote {path} rows={len(df):,} t={time.time() - t0:.1f}s", flush=True)


def build_temp_tables(cur) -> None:
    execute(
        cur,
        """
        DROP TABLE IF EXISTS pg_temp.base_cycles;
        CREATE TEMP TABLE base_cycles AS
        SELECT
            r.cod_cg_zafra,
            max(r.cod_cg) AS cod_cg,
            max(r.zafra_norm) AS zafra_norm,
            max(r.area)::double precision AS area,
            max(r.tch)::double precision AS tch,
            max(r.tc)::double precision AS tc,
            min(r.fecha_inicio_estimada)::date AS fecha_inicio_ciclo,
            max(r.fecha_fin_objetivo)::date AS fecha_fin_ciclo,
            max(r.edad_de_cultivo)::double precision AS cycle_age_max,
            180::integer AS cutoff_age_days,
            (min(r.fecha_inicio_estimada)::date + INTERVAL '180 days')::date AS cutoff_date,

            max(r.prod_ingenio) AS prod_ingenio,
            max(r.prod_grupo_de_suelo) AS prod_grupo_de_suelo,
            max(r.prod_grupo_de_humedad) AS prod_grupo_de_humedad,
            max(r.prod_codigo_zae) AS prod_codigo_zae,
            max(r.prod_familia_de_suelo) AS prod_familia_de_suelo,
            max(r.prod_variedad) AS prod_variedad,
            max(r.prod_no_corte) AS prod_no_corte
        FROM public.tch_raw_longitudinal_v4 r
        WHERE r.tch IS NOT NULL
          AND r.tch BETWEEN 20 AND 150
          AND r.ciclo_valido = true
          AND r.cod_cg_zafra IS NOT NULL
          AND r.zafra_norm <> '2019_2020'
        GROUP BY r.cod_cg_zafra
        HAVING max(r.edad_de_cultivo)::double precision >= 180;

        CREATE INDEX ON base_cycles (cod_cg_zafra);
        CREATE INDEX ON base_cycles (cod_cg);
        CREATE INDEX ON base_cycles (zafra_norm);
        """,
        "base_cycles",
    )

    execute(
        cur,
        """
        DROP TABLE IF EXISTS pg_temp.optical_long;
        CREATE TEMP TABLE optical_long AS
        SELECT
            b.cod_cg_zafra,
            b.zafra_norm,
            b.tch,
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
                ('ndwi11', NULLIF(r.stac_ndwi11_promedio::text, 'NaN')::double precision),
                ('msi11', NULLIF(r.stac_msi11_promedio::text, 'NaN')::double precision),
                ('ndvire', NULLIF(r.stac_ndvire_promedio::text, 'NaN')::double precision),
                ('cire', NULLIF(r.stac_cire_promedio::text, 'NaN')::double precision)
        ) AS v(index_name, index_value)
        WHERE r.ciclo_valido = true
          AND r.edad_de_cultivo BETWEEN 0 AND 180;

        CREATE INDEX ON optical_long (cod_cg_zafra);
        CREATE INDEX ON optical_long (index_name);
        CREATE INDEX ON optical_long (zafra_norm);
        """,
        "optical_long",
    )

    execute(
        cur,
        """
        DROP TABLE IF EXISTS pg_temp.optical_features;
        CREATE TEMP TABLE optical_features AS
        WITH weighted AS (
            SELECT
                *,
                lag(age_days) OVER (
                    PARTITION BY cod_cg_zafra, index_name
                    ORDER BY age_days, fecha_obs
                ) AS prev_age,
                lead(age_days) OVER (
                    PARTITION BY cod_cg_zafra, index_name
                    ORDER BY age_days, fecha_obs
                ) AS next_age,
                max(index_value) OVER (
                    PARTITION BY cod_cg_zafra, index_name
                ) AS peak_value_window
            FROM optical_long
        ),
        prepared AS (
            SELECT
                *,
                greatest(0.0, coalesce((prev_age + age_days) / 2.0, age_days - 7.5)) AS obs_start_age,
                least(180.0, coalesce((age_days + next_age) / 2.0, age_days + 7.5)) AS obs_end_age
            FROM weighted
        )
        SELECT
            cod_cg_zafra,
            zafra_norm,
            tch,
            index_name,
            count(index_value)::double precision AS obs_count_0_180,
            max(age_days) - min(age_days) AS observed_age_span_0_180,
            max(age_days - prev_age) AS max_gap_days_0_180,
            avg(index_value) AS mean_0_180,
            avg(index_value) FILTER (WHERE age_window = 'age_000_090') AS mean_0_90,
            avg(index_value) FILTER (WHERE age_window = 'age_091_180') AS mean_91_180,
            avg(index_value) FILTER (WHERE age_window = 'age_091_180')
                - avg(index_value) FILTER (WHERE age_window = 'age_000_090') AS mean_91_180_minus_0_90,
            max(index_value) AS peak_0_180,
            min(index_value) AS min_0_180,
            max(index_value) - min(index_value) AS amplitude_0_180,
            (array_agg(age_days ORDER BY index_value DESC NULLS LAST, age_days)
                FILTER (WHERE index_value IS NOT NULL))[1] AS age_at_peak_0_180,
            (array_agg(index_value ORDER BY age_days DESC NULLS LAST, fecha_obs DESC)
                FILTER (WHERE index_value IS NOT NULL))[1] AS last_value_before_180,
            (array_agg(age_days ORDER BY age_days DESC NULLS LAST, fecha_obs DESC)
                FILTER (WHERE index_value IS NOT NULL))[1] AS last_obs_age_before_180,
            sum(index_value * greatest(0.0, obs_end_age - obs_start_age)) AS auc_0_180,
            sum(index_value * greatest(0.0, least(obs_end_age, 90.0) - greatest(obs_start_age, 0.0))) AS auc_0_90,
            sum(index_value * greatest(0.0, obs_end_age - greatest(obs_start_age, 91.0))) AS auc_91_180,
            regr_slope(index_value, age_days) AS slope_0_180,
            regr_slope(index_value, age_days) FILTER (WHERE age_window = 'age_000_090') AS slope_0_90,
            regr_slope(index_value, age_days) FILTER (WHERE age_window = 'age_091_180') AS slope_91_180,
            sum(greatest(0.0, obs_end_age - obs_start_age))
                FILTER (WHERE index_value >= 0.8 * peak_value_window) AS duration_above_80pct_peak_0_180
        FROM prepared
        GROUP BY cod_cg_zafra, zafra_norm, tch, index_name;

        CREATE INDEX ON optical_features (cod_cg_zafra);
        CREATE INDEX ON optical_features (index_name);
        """,
        "optical_features",
    )

    execute(
        cur,
        """
        DROP TABLE IF EXISTS pg_temp.climate_seq;
        CREATE TEMP TABLE climate_seq AS
        SELECT
            b.cod_cg_zafra,
            b.zafra_norm,
            b.tch,
            c.fecha_inicio::date AS clima_fecha_inicio,
            (c.fecha_inicio::date - b.fecha_inicio_ciclo)::double precision AS age_days,
            CASE
                WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 0 AND 90 THEN 'age_000_090'
                WHEN (c.fecha_inicio::date - b.fecha_inicio_ciclo) BETWEEN 91 AND 180 THEN 'age_091_180'
                ELSE 'outside'
            END AS age_window,
            NULLIF(c.precipitacion_sum::text, 'NaN')::double precision AS precip,
            NULLIF(c.eto_sum::text, 'NaN')::double precision AS eto,
            NULLIF(c.temperatura_max::text, 'NaN')::double precision AS tmax,
            NULLIF(c.temperatura_min::text, 'NaN')::double precision AS tmin,
            NULLIF(c.temperatura_mean::text, 'NaN')::double precision AS tmean,
            NULLIF(c.humedad_relativa::text, 'NaN')::double precision AS rh,
            NULLIF(c.radiacion_sum::text, 'NaN')::double precision AS rad,
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
            END AS heat_pentad
        FROM base_cycles b
        LEFT JOIN public.clima_lote_pentada_new c
          ON c.cod_cg = b.cod_cg
         AND c.fecha_inicio::date BETWEEN b.fecha_inicio_ciclo AND b.cutoff_date;

        CREATE INDEX ON climate_seq (cod_cg_zafra);
        CREATE INDEX ON climate_seq (zafra_norm);
        """,
        "climate_seq",
    )

    execute(
        cur,
        """
        DROP TABLE IF EXISTS pg_temp.climate_features;
        CREATE TEMP TABLE climate_features AS
        SELECT
            cod_cg_zafra,
            max(zafra_norm) AS zafra_norm,
            max(tch) AS tch,
            count(clima_fecha_inicio)::double precision AS pentad_count_0_180,
            sum(precip) AS precip_acc_0_180,
            sum(precip) FILTER (WHERE age_window = 'age_000_090') AS precip_acc_0_90,
            sum(precip) FILTER (WHERE age_window = 'age_091_180') AS precip_acc_91_180,
            sum(eto) AS eto_acc_0_180,
            sum(water_balance) AS water_balance_acc_0_180,
            sum(water_balance) FILTER (WHERE age_window = 'age_000_090') AS water_balance_acc_0_90,
            sum(water_balance) FILTER (WHERE age_window = 'age_091_180') AS water_balance_acc_91_180,
            sum(precip) / NULLIF(sum(eto), 0) AS water_ratio_0_180,
            sum(rad) AS rad_acc_0_180,
            sum(gdd_10c) AS gdd_10c_acc_0_180,
            avg(tmean) AS tmean_mean_0_180,
            avg(tmax) AS tmax_mean_0_180,
            avg(tmin) AS tmin_mean_0_180,
            avg(rh) AS rh_mean_0_180,
            sum(dry_pentad) AS dry_pentad_count_0_180,
            avg(dry_pentad) AS dry_fraction_0_180,
            sum(heat_pentad) AS heat_pentad_count_0_180,
            regr_slope(water_balance, age_days) AS water_balance_slope_0_180,
            regr_slope(precip, age_days) AS precip_slope_0_180,
            regr_slope(rad, age_days) AS rad_slope_0_180,
            regr_slope(tmean, age_days) AS tmean_slope_0_180
        FROM climate_seq
        GROUP BY cod_cg_zafra;

        CREATE INDEX ON climate_features (cod_cg_zafra);
        """,
        "climate_features",
    )

    execute(
        cur,
        """
        DROP TABLE IF EXISTS pg_temp.enso_features;
        CREATE TEMP TABLE enso_features AS
        WITH seq AS (
            SELECT
                b.cod_cg_zafra,
                b.zafra_norm,
                b.tch,
                CASE
                    WHEN e.date::date < b.fecha_inicio_ciclo THEN 'precycle_180d'
                    ELSE 'asof_0_180d'
                END AS enso_window,
                NULLIF(e.oni::text, 'NaN')::double precision AS oni,
                NULLIF(e.nino34::text, 'NaN')::double precision AS nino34,
                NULLIF(e.soi::text, 'NaN')::double precision AS soi
            FROM base_cycles b
            LEFT JOIN public.enso e
              ON e.date::date >= b.fecha_inicio_ciclo - INTERVAL '180 days'
             AND e.date::date <= b.cutoff_date
        )
        SELECT
            cod_cg_zafra,
            max(zafra_norm) AS zafra_norm,
            max(tch) AS tch,
            count(*)::double precision AS month_count_asof,
            avg(oni) FILTER (WHERE enso_window = 'precycle_180d') AS oni_precycle_mean,
            avg(oni) FILTER (WHERE enso_window = 'asof_0_180d') AS oni_asof_mean,
            max(abs(oni)) AS oni_abs_max_asof,
            avg(nino34) FILTER (WHERE enso_window = 'precycle_180d') AS nino34_precycle_mean,
            avg(nino34) FILTER (WHERE enso_window = 'asof_0_180d') AS nino34_asof_mean,
            avg(soi) FILTER (WHERE enso_window = 'precycle_180d') AS soi_precycle_mean,
            avg(soi) FILTER (WHERE enso_window = 'asof_0_180d') AS soi_asof_mean,
            avg((oni > 0.5)::int) AS el_nino_fraction_asof,
            avg((oni < -0.5)::int) AS la_nina_fraction_asof
        FROM seq
        GROUP BY cod_cg_zafra;

        CREATE INDEX ON enso_features (cod_cg_zafra);
        """,
        "enso_features",
    )

    execute(
        cur,
        """
        DROP TABLE IF EXISTS pg_temp.feature_values;
        CREATE TEMP TABLE feature_values AS
        SELECT
            cod_cg_zafra,
            zafra_norm,
            tch,
            'optical' AS feature_family,
            index_name || '_' || v.feature_name AS feature_name,
            v.feature_value
        FROM optical_features
        CROSS JOIN LATERAL (
            VALUES
                ('obs_count_0_180', obs_count_0_180),
                ('observed_age_span_0_180', observed_age_span_0_180),
                ('max_gap_days_0_180', max_gap_days_0_180),
                ('mean_0_180', mean_0_180),
                ('mean_0_90', mean_0_90),
                ('mean_91_180', mean_91_180),
                ('mean_91_180_minus_0_90', mean_91_180_minus_0_90),
                ('peak_0_180', peak_0_180),
                ('min_0_180', min_0_180),
                ('amplitude_0_180', amplitude_0_180),
                ('age_at_peak_0_180', age_at_peak_0_180),
                ('last_value_before_180', last_value_before_180),
                ('last_obs_age_before_180', last_obs_age_before_180),
                ('auc_0_180', auc_0_180),
                ('auc_0_90', auc_0_90),
                ('auc_91_180', auc_91_180),
                ('slope_0_180', slope_0_180),
                ('slope_0_90', slope_0_90),
                ('slope_91_180', slope_91_180),
                ('duration_above_80pct_peak_0_180', duration_above_80pct_peak_0_180)
        ) AS v(feature_name, feature_value)
        UNION ALL
        SELECT
            cod_cg_zafra,
            zafra_norm,
            tch,
            'climate' AS feature_family,
            v.feature_name,
            v.feature_value
        FROM climate_features
        CROSS JOIN LATERAL (
            VALUES
                ('climate_pentad_count_0_180', pentad_count_0_180),
                ('climate_precip_acc_0_180', precip_acc_0_180),
                ('climate_precip_acc_0_90', precip_acc_0_90),
                ('climate_precip_acc_91_180', precip_acc_91_180),
                ('climate_eto_acc_0_180', eto_acc_0_180),
                ('climate_water_balance_acc_0_180', water_balance_acc_0_180),
                ('climate_water_balance_acc_0_90', water_balance_acc_0_90),
                ('climate_water_balance_acc_91_180', water_balance_acc_91_180),
                ('climate_water_ratio_0_180', water_ratio_0_180),
                ('climate_rad_acc_0_180', rad_acc_0_180),
                ('climate_gdd_10c_acc_0_180', gdd_10c_acc_0_180),
                ('climate_tmean_mean_0_180', tmean_mean_0_180),
                ('climate_tmax_mean_0_180', tmax_mean_0_180),
                ('climate_tmin_mean_0_180', tmin_mean_0_180),
                ('climate_rh_mean_0_180', rh_mean_0_180),
                ('climate_dry_pentad_count_0_180', dry_pentad_count_0_180),
                ('climate_dry_fraction_0_180', dry_fraction_0_180),
                ('climate_heat_pentad_count_0_180', heat_pentad_count_0_180),
                ('climate_water_balance_slope_0_180', water_balance_slope_0_180),
                ('climate_precip_slope_0_180', precip_slope_0_180),
                ('climate_rad_slope_0_180', rad_slope_0_180),
                ('climate_tmean_slope_0_180', tmean_slope_0_180)
        ) AS v(feature_name, feature_value)
        UNION ALL
        SELECT
            cod_cg_zafra,
            zafra_norm,
            tch,
            'enso' AS feature_family,
            v.feature_name,
            v.feature_value
        FROM enso_features
        CROSS JOIN LATERAL (
            VALUES
                ('enso_month_count_asof', month_count_asof),
                ('enso_oni_precycle_mean', oni_precycle_mean),
                ('enso_oni_asof_mean', oni_asof_mean),
                ('enso_oni_abs_max_asof', oni_abs_max_asof),
                ('enso_nino34_precycle_mean', nino34_precycle_mean),
                ('enso_nino34_asof_mean', nino34_asof_mean),
                ('enso_soi_precycle_mean', soi_precycle_mean),
                ('enso_soi_asof_mean', soi_asof_mean),
                ('enso_el_nino_fraction_asof', el_nino_fraction_asof),
                ('enso_la_nina_fraction_asof', la_nina_fraction_asof)
        ) AS v(feature_name, feature_value);

        CREATE INDEX ON feature_values (feature_family);
        CREATE INDEX ON feature_values (feature_name);
        CREATE INDEX ON feature_values (zafra_norm);
        """,
        "feature_values",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    tunnel, conn = connect_with_tunnel()
    try:
        with conn.cursor() as cur:
            build_temp_tables(cur)

        queries = {
            "coverage_by_zafra.csv": """
                SELECT
                    b.zafra_norm,
                    count(*) AS rows,
                    min(b.fecha_inicio_ciclo) AS min_inicio_ciclo,
                    max(b.fecha_inicio_ciclo) AS max_inicio_ciclo,
                    min(b.cutoff_date) AS min_cutoff_date,
                    max(b.cutoff_date) AS max_cutoff_date,
                    min(b.fecha_fin_ciclo) AS min_cierre,
                    max(b.fecha_fin_ciclo) AS max_cierre,
                    round(avg(b.cycle_age_max)::numeric, 1) AS avg_cycle_age_max,
                    round(avg(o.obs_count_0_180)::numeric, 1) AS avg_optical_obs_0_180,
                    percentile_cont(0.5) WITHIN GROUP (ORDER BY o.obs_count_0_180) AS p50_optical_obs_0_180,
                    round(avg(c.pentad_count_0_180)::numeric, 1) AS avg_climate_pentads_0_180,
                    round(avg(e.month_count_asof)::numeric, 1) AS avg_enso_months_asof,
                    round(avg(b.tch)::numeric, 2) AS avg_tch,
                    round(sum(b.tch)::numeric, 2) AS raw_tch_sum
                FROM base_cycles b
                LEFT JOIN (
                    SELECT cod_cg_zafra, max(obs_count_0_180) AS obs_count_0_180
                    FROM optical_features
                    WHERE index_name = 'ndvi'
                    GROUP BY cod_cg_zafra
                ) o USING (cod_cg_zafra)
                LEFT JOIN climate_features c USING (cod_cg_zafra)
                LEFT JOIN enso_features e USING (cod_cg_zafra)
                GROUP BY b.zafra_norm
                ORDER BY b.zafra_norm;
            """,
            "candidate_feature_signal_discovery.csv": """
                WITH valid AS (
                    SELECT
                        *,
                        rank() OVER (PARTITION BY feature_name ORDER BY feature_value) AS feature_rank,
                        rank() OVER (PARTITION BY feature_name ORDER BY tch) AS tch_rank
                    FROM feature_values
                    WHERE feature_value IS NOT NULL
                      AND tch IS NOT NULL
                      AND zafra_norm IN ('2020_2021', '2021_2022', '2022_2023', '2023_2024')
                )
                SELECT
                    feature_family,
                    feature_name,
                    count(*) AS rows_non_null,
                    round(avg(feature_value)::numeric, 4) AS mean_value,
                    round(stddev(feature_value)::numeric, 4) AS std_value,
                    round(corr(feature_value, tch)::numeric, 4) AS pearson_tch,
                    round(corr(feature_rank::double precision, tch_rank::double precision)::numeric, 4) AS spearman_tch,
                    round(abs(corr(feature_rank::double precision, tch_rank::double precision))::numeric, 4) AS spearman_abs
                FROM valid
                GROUP BY feature_family, feature_name
                HAVING count(*) >= 500
                ORDER BY spearman_abs DESC NULLS LAST, feature_family, feature_name;
            """,
            "feature_stability_by_zafra_discovery.csv": """
                WITH valid AS (
                    SELECT
                        *,
                        rank() OVER (PARTITION BY feature_name ORDER BY feature_value) AS feature_rank,
                        rank() OVER (PARTITION BY feature_name ORDER BY tch) AS tch_rank
                    FROM feature_values
                    WHERE feature_value IS NOT NULL
                      AND tch IS NOT NULL
                      AND zafra_norm IN ('2020_2021', '2021_2022', '2022_2023', '2023_2024')
                ),
                by_zafra AS (
                    SELECT
                        feature_family,
                        feature_name,
                        zafra_norm,
                        count(*) AS rows_non_null,
                        corr(feature_rank::double precision, tch_rank::double precision) AS spearman_tch
                    FROM valid
                    GROUP BY feature_family, feature_name, zafra_norm
                    HAVING count(*) >= 300
                )
                SELECT
                    feature_family,
                    feature_name,
                    count(*) AS zafras_with_signal,
                    round(avg(spearman_tch)::numeric, 4) AS avg_zafra_spearman,
                    round(stddev(spearman_tch)::numeric, 4) AS sd_zafra_spearman,
                    round(min(spearman_tch)::numeric, 4) AS min_zafra_spearman,
                    round(max(spearman_tch)::numeric, 4) AS max_zafra_spearman
                FROM by_zafra
                GROUP BY feature_family, feature_name
                ORDER BY abs(avg(spearman_tch)) DESC NULLS LAST, feature_family, feature_name;
            """,
            "drift_2024_2025_vs_discovery.csv": """
                WITH stats AS (
                    SELECT
                        feature_family,
                        feature_name,
                        CASE
                            WHEN zafra_norm IN ('2020_2021', '2021_2022', '2022_2023', '2023_2024') THEN 'discovery'
                            WHEN zafra_norm = '2024_2025' THEN 'test_2024_2025'
                            ELSE 'other'
                        END AS cohort,
                        count(*) AS rows_non_null,
                        avg(feature_value) AS mean_value,
                        stddev(feature_value) AS sd_value,
                        percentile_cont(0.5) WITHIN GROUP (ORDER BY feature_value) AS median_value
                    FROM feature_values
                    WHERE feature_value IS NOT NULL
                      AND zafra_norm IN ('2020_2021', '2021_2022', '2022_2023', '2023_2024', '2024_2025')
                    GROUP BY feature_family, feature_name, cohort
                ),
                paired AS (
                    SELECT
                        h.feature_family,
                        h.feature_name,
                        h.rows_non_null AS discovery_rows,
                        n.rows_non_null AS test_2024_2025_rows,
                        h.mean_value AS discovery_mean,
                        n.mean_value AS test_2024_2025_mean,
                        n.mean_value - h.mean_value AS mean_diff,
                        CASE WHEN h.sd_value > 0 THEN (n.mean_value - h.mean_value) / h.sd_value ELSE NULL END AS standardized_mean_diff,
                        h.median_value AS discovery_median,
                        n.median_value AS test_2024_2025_median,
                        n.median_value - h.median_value AS median_diff
                    FROM stats h
                    JOIN stats n USING (feature_family, feature_name)
                    WHERE h.cohort = 'discovery'
                      AND n.cohort = 'test_2024_2025'
                )
                SELECT
                    feature_family,
                    feature_name,
                    discovery_rows,
                    test_2024_2025_rows,
                    round(discovery_mean::numeric, 4) AS discovery_mean,
                    round(test_2024_2025_mean::numeric, 4) AS test_2024_2025_mean,
                    round(mean_diff::numeric, 4) AS mean_diff,
                    round(standardized_mean_diff::numeric, 4) AS standardized_mean_diff,
                    round(discovery_median::numeric, 4) AS discovery_median,
                    round(test_2024_2025_median::numeric, 4) AS test_2024_2025_median,
                    round(median_diff::numeric, 4) AS median_diff
                FROM paired
                ORDER BY abs(standardized_mean_diff) DESC NULLS LAST, feature_family, feature_name;
            """,
            "drift_2025_2026_vs_discovery.csv": """
                WITH stats AS (
                    SELECT
                        feature_family,
                        feature_name,
                        CASE
                            WHEN zafra_norm IN ('2020_2021', '2021_2022', '2022_2023', '2023_2024') THEN 'discovery'
                            WHEN zafra_norm = '2025_2026' THEN 'external_2025_2026'
                            ELSE 'other'
                        END AS cohort,
                        count(*) AS rows_non_null,
                        avg(feature_value) AS mean_value,
                        stddev(feature_value) AS sd_value,
                        percentile_cont(0.5) WITHIN GROUP (ORDER BY feature_value) AS median_value
                    FROM feature_values
                    WHERE feature_value IS NOT NULL
                      AND zafra_norm IN ('2020_2021', '2021_2022', '2022_2023', '2023_2024', '2025_2026')
                    GROUP BY feature_family, feature_name, cohort
                ),
                paired AS (
                    SELECT
                        h.feature_family,
                        h.feature_name,
                        h.rows_non_null AS discovery_rows,
                        n.rows_non_null AS zafra_2025_2026_rows,
                        h.mean_value AS discovery_mean,
                        n.mean_value AS zafra_2025_2026_mean,
                        n.mean_value - h.mean_value AS mean_diff,
                        CASE WHEN h.sd_value > 0 THEN (n.mean_value - h.mean_value) / h.sd_value ELSE NULL END AS standardized_mean_diff,
                        h.median_value AS discovery_median,
                        n.median_value AS zafra_2025_2026_median,
                        n.median_value - h.median_value AS median_diff
                    FROM stats h
                    JOIN stats n USING (feature_family, feature_name)
                    WHERE h.cohort = 'discovery'
                      AND n.cohort = 'external_2025_2026'
                )
                SELECT
                    feature_family,
                    feature_name,
                    discovery_rows,
                    zafra_2025_2026_rows,
                    round(discovery_mean::numeric, 4) AS discovery_mean,
                    round(zafra_2025_2026_mean::numeric, 4) AS zafra_2025_2026_mean,
                    round(mean_diff::numeric, 4) AS mean_diff,
                    round(standardized_mean_diff::numeric, 4) AS standardized_mean_diff,
                    round(discovery_median::numeric, 4) AS discovery_median,
                    round(zafra_2025_2026_median::numeric, 4) AS zafra_2025_2026_median,
                    round(median_diff::numeric, 4) AS median_diff
                FROM paired
                ORDER BY abs(standardized_mean_diff) DESC NULLS LAST, feature_family, feature_name;
            """,
            "tch_bin_profiles_discovery.csv": """
                WITH bins AS (
                    SELECT
                        b.*,
                        ntile(5) OVER (PARTITION BY zafra_norm ORDER BY tch) AS tch_quintile
                    FROM base_cycles b
                    WHERE zafra_norm IN ('2020_2021', '2021_2022', '2022_2023', '2023_2024')
                ),
                ndvi AS (
                    SELECT
                        cod_cg_zafra,
                        max(mean_0_180) FILTER (WHERE index_name = 'ndvi') AS ndvi_mean_0_180,
                        max(peak_0_180) FILTER (WHERE index_name = 'ndvi') AS ndvi_peak_0_180,
                        max(slope_0_180) FILTER (WHERE index_name = 'ndvi') AS ndvi_slope_0_180,
                        max(mean_91_180_minus_0_90) FILTER (WHERE index_name = 'ndvi') AS ndvi_delta_91_180_vs_0_90,
                        max(mean_0_180) FILTER (WHERE index_name = 'ndre') AS ndre_mean_0_180,
                        max(mean_0_180) FILTER (WHERE index_name = 'lswi') AS lswi_mean_0_180
                    FROM optical_features
                    GROUP BY cod_cg_zafra
                )
                SELECT
                    b.zafra_norm,
                    b.tch_quintile,
                    count(*) AS rows,
                    round(avg(b.tch)::numeric, 2) AS avg_tch,
                    round(avg(n.ndvi_mean_0_180)::numeric, 4) AS avg_ndvi_mean_0_180,
                    round(avg(n.ndvi_peak_0_180)::numeric, 4) AS avg_ndvi_peak_0_180,
                    round(avg(n.ndvi_slope_0_180)::numeric, 6) AS avg_ndvi_slope_0_180,
                    round(avg(n.ndvi_delta_91_180_vs_0_90)::numeric, 4) AS avg_ndvi_delta_91_180_vs_0_90,
                    round(avg(n.ndre_mean_0_180)::numeric, 4) AS avg_ndre_mean_0_180,
                    round(avg(n.lswi_mean_0_180)::numeric, 4) AS avg_lswi_mean_0_180
                FROM bins b
                LEFT JOIN ndvi n USING (cod_cg_zafra)
                GROUP BY b.zafra_norm, b.tch_quintile
                ORDER BY b.zafra_norm, b.tch_quintile;
            """,
            "static_category_signal.csv": """
                WITH static_values AS (
                    SELECT cod_cg_zafra, zafra_norm, tch, 'prod_ingenio' AS feature_name, prod_ingenio::text AS category_value FROM base_cycles
                    UNION ALL SELECT cod_cg_zafra, zafra_norm, tch, 'prod_grupo_de_suelo', prod_grupo_de_suelo::text FROM base_cycles
                    UNION ALL SELECT cod_cg_zafra, zafra_norm, tch, 'prod_grupo_de_humedad', prod_grupo_de_humedad::text FROM base_cycles
                    UNION ALL SELECT cod_cg_zafra, zafra_norm, tch, 'prod_codigo_zae', prod_codigo_zae::text FROM base_cycles
                    UNION ALL SELECT cod_cg_zafra, zafra_norm, tch, 'prod_familia_de_suelo', prod_familia_de_suelo::text FROM base_cycles
                    UNION ALL SELECT cod_cg_zafra, zafra_norm, tch, 'prod_variedad', prod_variedad::text FROM base_cycles
                    UNION ALL SELECT cod_cg_zafra, zafra_norm, tch, 'prod_no_corte', prod_no_corte::text FROM base_cycles
                ),
                category_stats AS (
                    SELECT
                        feature_name,
                        category_value,
                        count(*) AS rows,
                        count(DISTINCT zafra_norm) AS zafra_count,
                        round(avg(tch)::numeric, 2) AS avg_tch,
                        round(stddev(tch)::numeric, 2) AS sd_tch
                    FROM static_values
                    WHERE category_value IS NOT NULL
                    GROUP BY feature_name, category_value
                    HAVING count(*) >= 50
                )
                SELECT *
                FROM category_stats
                ORDER BY feature_name, rows DESC, category_value;
            """,
        }

        for filename, sql in queries.items():
            export_query(conn, sql, args.output_dir / filename)
    finally:
        conn.close()
        tunnel.stop()


if __name__ == "__main__":
    main()
