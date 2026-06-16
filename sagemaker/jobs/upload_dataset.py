"""
Upload a query result from PostgreSQL to S3 as parquet.

Usage:
    python upload_dataset.py maestra_clima
    python upload_dataset.py tch_raw_longitudinal --chunked
"""
import argparse
import io
import os
import re
from pathlib import Path

import boto3
import pandas as pd
import psycopg2
from psycopg2 import sql as pg_sql
from dotenv import load_dotenv
from sshtunnel import SSHTunnelForwarder

ROOT = Path(__file__).resolve().parents[2]
load_dotenv(ROOT / "credentials" / ".env")

BUCKET = "ndvi-extraction"
QUERIES_DIR = ROOT / "queries"
QUERY_SEARCH_DIRS = [
    QUERIES_DIR / "active" / "v9" / "dataset",
    QUERIES_DIR / "active" / "v8" / "dataset",
    QUERIES_DIR / "active" / "v7" / "dataset",
    QUERIES_DIR / "archive" / "v6" / "asof_180" / "dataset",
    QUERIES_DIR / "archive" / "v5" / "asof_180" / "dataset",
    *[
        QUERIES_DIR / "templates" / "raw_longitudinal" / version
        for version in ("v5", "v4", "v3", "v2")
    ],
    QUERIES_DIR,
]
INCLUDE_PATTERN = re.compile(r"\{\{\s*include:([A-Za-z0-9_.-]+)\s*\}\}")


def query_path(query_name: str) -> Path:
    for directory in QUERY_SEARCH_DIRS:
        sql_file = directory / f"{query_name}.sql"
        if sql_file.exists():
            return sql_file
    raise FileNotFoundError(f"No SQL file found for query: {query_name}")


def render_query(query_name: str, stack: tuple[str, ...] = ()) -> str:
    if query_name in stack:
        raise ValueError(f"Circular SQL include detected: {' -> '.join((*stack, query_name))}")
    text = query_path(query_name).read_text()

    def replace_include(match: re.Match) -> str:
        included_name = match.group(1)
        included_sql = render_query(included_name, (*stack, query_name))
        return included_sql.rstrip().rstrip(";")

    return INCLUDE_PATTERN.sub(replace_include, text)


def connect_with_tunnel():
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


def upload(query_name: str) -> None:
    with_s3 = boto3.client("s3", region_name="us-east-1")
    sql = render_query(query_name)

    tunnel, conn = connect_with_tunnel()
    try:
        df = pd.read_sql(sql, conn)
    finally:
        conn.close()
        tunnel.stop()

    buf = io.BytesIO()
    df.to_parquet(buf, index=False)
    buf.seek(0)

    key = f"datasets/{query_name}.parquet"
    with_s3.put_object(Bucket=BUCKET, Key=key, Body=buf.getvalue())
    print(f"Uploaded {len(df):,} rows to s3://{BUCKET}/{key}")


def delete_prefix(s3_client, prefix: str) -> None:
    paginator = s3_client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=prefix):
        objects = [{"Key": obj["Key"]} for obj in page.get("Contents", [])]
        if objects:
            s3_client.delete_objects(Bucket=BUCKET, Delete={"Objects": objects})


def upload_chunked(query_name: str, chunksize: int, replace: bool) -> None:
    s3_client = boto3.client("s3", region_name="us-east-1")
    sql = render_query(query_name).rstrip().rstrip(";")
    prefix = f"datasets/{query_name}/"

    if replace:
        delete_prefix(s3_client, prefix)
        print(f"Cleared s3://{BUCKET}/{prefix}")

    tunnel, conn = connect_with_tunnel()
    total_rows = 0
    part = 0
    cursor_name = f"{query_name}_upload_cursor".replace("-", "_")

    try:
        with conn.cursor(name=cursor_name) as cur:
            cur.itersize = chunksize
            cur.execute(pg_sql.SQL("SELECT * FROM ({}) q").format(pg_sql.SQL(sql)))

            while True:
                rows = cur.fetchmany(chunksize)
                if not rows:
                    break

                columns = [desc.name for desc in cur.description]
                df = pd.DataFrame.from_records(rows, columns=columns)

                buf = io.BytesIO()
                df.to_parquet(buf, index=False)
                buf.seek(0)

                key = f"{prefix}part-{part:05d}.parquet"
                s3_client.put_object(Bucket=BUCKET, Key=key, Body=buf.getvalue())

                total_rows += len(df)
                print(f"Uploaded {len(df):,} rows to s3://{BUCKET}/{key} ({total_rows:,} total)")
                part += 1
    finally:
        conn.close()
        tunnel.stop()

    print(f"Uploaded {total_rows:,} rows in {part:,} parts to s3://{BUCKET}/{prefix}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("query", help="Query filename without .sql (e.g. ml_dataset)")
    parser.add_argument("--chunked", action="store_true", help="Upload multiple parquet parts under datasets/{query}/")
    parser.add_argument("--chunksize", type=int, default=100_000, help="Rows per parquet part for --chunked")
    parser.add_argument("--no-replace", action="store_true", help="Do not clear existing S3 objects under the chunked prefix first")
    args = parser.parse_args()
    if args.chunked:
        upload_chunked(args.query, chunksize=args.chunksize, replace=not args.no_replace)
    else:
        upload(args.query)
