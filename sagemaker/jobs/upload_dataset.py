"""
Upload a query result directly from PostgreSQL to S3 as parquet (no local file).

Usage:
    python upload_dataset.py ml_dataset
    python upload_dataset.py mv_maestra_agregada
"""
import argparse
import io
import os
from pathlib import Path

import boto3
import pandas as pd
import psycopg2
from dotenv import load_dotenv
from sshtunnel import SSHTunnelForwarder

ROOT = Path(__file__).resolve().parents[2]
load_dotenv(ROOT / "credentials" / ".env")

BUCKET = "ndvi-extraction"
QUERIES_DIR = ROOT / "queries"
DATASETS_DIR = QUERIES_DIR / "datasets"


def upload(query_name: str) -> None:
    ssh_key = ROOT / "credentials" / "eagriculturai_key.pem"

    with SSHTunnelForwarder(
        (os.environ["SSH_HOST"], int(os.environ["SSH_PORT"])),
        ssh_username=os.environ["SSH_USER"],
        ssh_pkey=str(ssh_key),
        remote_bind_address=(os.environ["DB_HOST"], int(os.environ["DB_PORT"])),
    ) as tunnel:
        conn = psycopg2.connect(
            host="127.0.0.1",
            port=tunnel.local_bind_port,
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
        )
        sql_file = DATASETS_DIR / f"{query_name}.sql"
        if not sql_file.exists():
            sql_file = QUERIES_DIR / f"{query_name}.sql"
        sql = sql_file.read_text()
        df = pd.read_sql(sql, conn)
        conn.close()

    buf = io.BytesIO()
    df.to_parquet(buf, index=False)
    buf.seek(0)

    key = f"datasets/{query_name}.parquet"
    boto3.client("s3", region_name="us-east-1").put_object(
        Bucket=BUCKET, Key=key, Body=buf.getvalue()
    )
    print(f"Uploaded {len(df):,} rows to s3://{BUCKET}/{key}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("query", help="Query filename without .sql (e.g. ml_dataset)")
    args = parser.parse_args()
    upload(args.query)
