import os
from dotenv import load_dotenv
from pathlib import Path

load_dotenv(Path(__file__).resolve().parents[2] / "credentials" / ".env")

BUCKET = "ndvi-extraction"
REGION = "us-east-1"
ROLE_ARN = os.environ["SAGEMAKER_ROLE_ARN"]
INSTANCE_TYPE = "ml.m5.xlarge"
