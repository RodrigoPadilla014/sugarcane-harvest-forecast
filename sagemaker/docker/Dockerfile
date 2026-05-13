FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

RUN sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ml/code

COPY docker/requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip \
    && pip install -r /tmp/requirements.txt

COPY training/ /opt/ml/code/

ENTRYPOINT ["python", "/opt/ml/code/train.py"]
