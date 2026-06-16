#!/usr/bin/env bash
set -Eeuo pipefail

DATASET_DEFAULT="tch_features_v9_productivity_snapshots"
IMAGE_DEFAULT="920572019712.dkr.ecr.us-east-1.amazonaws.com/tch-sagemaker-training:latest"
BUCKET_DEFAULT="ndvi-extraction"
REGION_DEFAULT="us-east-1"
TRAIN_ZAFRAS_DEFAULT="2020_2021,2021_2022,2022_2023,2023_2024"
EVALUATION_ZAFRAS_DEFAULT="2024_2025,2025_2026"
SCORING_ZAFRAS_DEFAULT="2026_2027"

STAGE=""
DATASET="${TCH_DATASET:-$DATASET_DEFAULT}"
IMAGE="${TCH_IMAGE:-$IMAGE_DEFAULT}"
BUCKET="${TCH_BUCKET:-$BUCKET_DEFAULT}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$REGION_DEFAULT}}"
WORK_ROOT="${TCH_WORK_ROOT:-$HOME/tch-training}"
CPUS="${TCH_CPUS:-4}"
MEMORY="${TCH_MEMORY:-14g}"
SHM_SIZE="${TCH_SHM_SIZE:-2g}"
EXCLUDE_FEATURES="${TCH_EXCLUDE_FEATURES:-}"
TRAIN_ZAFRAS="${TCH_TRAIN_ZAFRAS:-$TRAIN_ZAFRAS_DEFAULT}"
EVALUATION_ZAFRAS="${TCH_EVALUATION_ZAFRAS:-$EVALUATION_ZAFRAS_DEFAULT}"
SCORING_ZAFRAS="${TCH_SCORING_ZAFRAS:-$SCORING_ZAFRAS_DEFAULT}"
AGGREGATE_PENALTY="${TCH_AGGREGATE_PENALTY:-}"
REFRESH_DATASET=false
PARTITIONED=true
SKIP_PULL=false
SKIP_UPLOAD=false
DRY_RUN=false

usage() {
    cat <<'EOF'
Usage:
  ./ec2/run_training.sh <diagnostics|baseline|optuna> [options]

Options:
  --dataset NAME              Dataset key without .parquet.
  --image URI                 Docker image URI.
  --bucket NAME               S3 bucket for datasets and artifacts.
  --region REGION             AWS region. Default: us-east-1.
  --work-root PATH            Host directory for cached data and runs.
  --cpus NUMBER               Docker CPU limit. Default: 4.
  --memory SIZE               Docker memory and memory+swap limit. Default: 14g.
  --shm-size SIZE             Container /dev/shm size. Default: 2g.
  --exclude-features CSV      Comma-separated approved feature exclusions.
  --aggregate-penalty NUMBER  Override the stage aggregate penalty.
  --partitioned               Read parquet parts from datasets/NAME/.
  --refresh-dataset           Download the dataset again from S3.
  --skip-pull                 Use the Docker image already present on the host.
  --skip-upload               Keep artifacts only on the EC2 host.
  --dry-run                   Print the resolved run without AWS or Docker calls.
  -h, --help                  Show this help.

The runner executes exactly one requested stage and never starts the next stage.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while (($#)); do
    case "$1" in
        diagnostics|baseline|optuna)
            [[ -z "$STAGE" ]] || die "Only one stage may be selected"
            STAGE="$1"
            shift
            ;;
        --dataset)
            DATASET="${2:?Missing value for --dataset}"
            shift 2
            ;;
        --image)
            IMAGE="${2:?Missing value for --image}"
            shift 2
            ;;
        --bucket)
            BUCKET="${2:?Missing value for --bucket}"
            shift 2
            ;;
        --region)
            AWS_REGION="${2:?Missing value for --region}"
            shift 2
            ;;
        --work-root)
            WORK_ROOT="${2:?Missing value for --work-root}"
            shift 2
            ;;
        --cpus)
            CPUS="${2:?Missing value for --cpus}"
            shift 2
            ;;
        --memory)
            MEMORY="${2:?Missing value for --memory}"
            shift 2
            ;;
        --shm-size)
            SHM_SIZE="${2:?Missing value for --shm-size}"
            shift 2
            ;;
        --exclude-features)
            EXCLUDE_FEATURES="${2:?Missing value for --exclude-features}"
            shift 2
            ;;
        --aggregate-penalty)
            AGGREGATE_PENALTY="${2:?Missing value for --aggregate-penalty}"
            shift 2
            ;;
        --partitioned)
            PARTITIONED=true
            shift
            ;;
        --refresh-dataset)
            REFRESH_DATASET=true
            shift
            ;;
        --skip-pull)
            SKIP_PULL=true
            shift
            ;;
        --skip-upload)
            SKIP_UPLOAD=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$STAGE" ]] || {
    usage
    die "A stage is required"
}

case "$STAGE" in
    diagnostics)
        MAX_RUNTIME_SECONDS=14400
        STAGE_ARGS=(
            --diagnostics-only true
            --walk-forward false
            --skip-optuna false
            --n-trials 50
            --objective-mode auto
            --aggregate-penalty 1.0
        )
        ;;
    baseline)
        MAX_RUNTIME_SECONDS=14400
        STAGE_ARGS=(
            --diagnostics-only false
            --walk-forward true
            --skip-optuna true
            --n-trials 50
            --objective-mode aggregate_tch_sum
            --aggregate-penalty 1.5
        )
        ;;
    optuna)
        MAX_RUNTIME_SECONDS=21600
        STAGE_ARGS=(
            --diagnostics-only false
            --walk-forward true
            --skip-optuna false
            --n-trials 20
            --objective-mode aggregate_tch_sum
            --aggregate-penalty 1.5
        )
        ;;
esac

if [[ -n "$AGGREGATE_PENALTY" ]]; then
    for ((i = 0; i < ${#STAGE_ARGS[@]}; i++)); do
        if [[ "${STAGE_ARGS[$i]}" == "--aggregate-penalty" ]]; then
            STAGE_ARGS[$((i + 1))]="$AGGREGATE_PENALTY"
            break
        fi
    done
fi

COMMON_ARGS=(
    --dataset-type feature_table
    --model-type catboost
    --categorical-mode native
    --one-hot-features false
    --light-features false
    --quantiles true
    --shap true
    --diagnostics true
    --train-zafras "$TRAIN_ZAFRAS"
    --evaluation-zafras "$EVALUATION_ZAFRAS"
    --scoring-zafras "$SCORING_ZAFRAS"
)
if [[ -n "$EXCLUDE_FEATURES" ]]; then
    COMMON_ARGS+=(--exclude-features "$EXCLUDE_FEATURES")
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="tch-${DATASET//_/-}-${STAGE}-${TIMESTAMP}"
DATASET_DIR="$WORK_ROOT/datasets"
DATASET_PATH="$DATASET_DIR/$DATASET.parquet"
DATASET_PARTS_DIR="$DATASET_DIR/$DATASET"
RUN_DIR="$WORK_ROOT/runs/$RUN_ID"
INPUT_DIR="$RUN_DIR/input"
OUTPUT_DIR="$RUN_DIR/output"
MODEL_DIR="$RUN_DIR/model"
LOG_DIR="$RUN_DIR/logs"
DATASET_S3_URI="s3://$BUCKET/datasets/$DATASET.parquet"
if $PARTITIONED; then
    DATASET_S3_URI="s3://$BUCKET/datasets/$DATASET/"
fi
OUTPUT_S3_URI="s3://$BUCKET/experiments-ec2/$DATASET/$STAGE/$RUN_ID/"
CONTAINER_NAME="tch-training-active"
LOCK_FILE="$WORK_ROOT/training.lock"
CONTAINER_CREATED=false
MONITOR_PID=""

# Invoked indirectly by the EXIT, INT, and TERM traps below.
# shellcheck disable=SC2329
cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    if [[ -n "$MONITOR_PID" ]]; then
        kill "$MONITOR_PID" >/dev/null 2>&1 || true
        wait "$MONITOR_PID" >/dev/null 2>&1 || true
    fi

    if $CONTAINER_CREATED && docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        if [[ "$state" == "running" ]]; then
            docker stop --time 60 "$CONTAINER_NAME" >/dev/null 2>&1 || true
        fi
        if [[ -d "$LOG_DIR" ]]; then
            docker logs "$CONTAINER_NAME" >"$LOG_DIR/container.log" 2>&1 || true
        fi
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM

DOCKER_COMMAND=(
    docker create
    --name "$CONTAINER_NAME"
    --cpus "$CPUS"
    --memory "$MEMORY"
    --memory-swap "$MEMORY"
    --shm-size "$SHM_SIZE"
    --label "tch.run_id=$RUN_ID"
    --label "tch.stage=$STAGE"
    --label "tch.dataset=$DATASET"
    -v "$INPUT_DIR:/opt/ml/input/data/train:ro"
    -v "$OUTPUT_DIR:/opt/ml/output/data"
    -v "$MODEL_DIR:/opt/ml/model"
    "$IMAGE"
    "${COMMON_ARGS[@]}"
    "${STAGE_ARGS[@]}"
)

print_resolved_run() {
    cat <<EOF
Run ID:          $RUN_ID
Stage:           $STAGE
Dataset:         $DATASET_S3_URI
Image:           $IMAGE
Resources:       cpus=$CPUS memory=$MEMORY shm=$SHM_SIZE
Local run dir:   $RUN_DIR
Artifact target: $OUTPUT_S3_URI
Max runtime:     $MAX_RUNTIME_SECONDS seconds
Excluded:        ${EXCLUDE_FEATURES:-<none>}
Aggregate pen.:  ${AGGREGATE_PENALTY:-<stage default>}
Partitioned:     $PARTITIONED
EOF
    printf 'Container command:'
    printf ' %q' "${DOCKER_COMMAND[@]}"
    printf '\n'
}

print_resolved_run
if $DRY_RUN; then
    exit 0
fi

require_command aws
require_command docker
require_command flock
require_command python3
require_command timeout

mkdir -p "$WORK_ROOT" "$DATASET_DIR" "$INPUT_DIR" "$OUTPUT_DIR" "$MODEL_DIR" "$LOG_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another EC2 training run holds $LOCK_FILE"

if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    existing_state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
    [[ "$existing_state" != "running" ]] || die "Container $CONTAINER_NAME is already running"
    docker rm "$CONTAINER_NAME" >/dev/null
fi

if [[ "$IMAGE" == *.dkr.ecr.*.amazonaws.com/* ]] && ! $SKIP_PULL; then
    ECR_REGISTRY="${IMAGE%%/*}"
    aws ecr get-login-password --region "$AWS_REGION" |
        docker login --username AWS --password-stdin "$ECR_REGISTRY"
fi
if ! $SKIP_PULL; then
    docker pull "$IMAGE"
fi

if $PARTITIONED; then
    if $REFRESH_DATASET || ! compgen -G "$DATASET_PARTS_DIR/*.parquet" >/dev/null; then
        rm -rf "$DATASET_PARTS_DIR"
        mkdir -p "$DATASET_PARTS_DIR"
        aws s3 sync "$DATASET_S3_URI" "$DATASET_PARTS_DIR/" \
            --exclude "*" --include "*.parquet" --region "$AWS_REGION"
    fi
    compgen -G "$DATASET_PARTS_DIR/*.parquet" >/dev/null ||
        die "No parquet parts found under $DATASET_S3_URI"
    for dataset_part in "$DATASET_PARTS_DIR"/*.parquet; do
        ln "$dataset_part" "$INPUT_DIR/$(basename "$dataset_part")" 2>/dev/null ||
            cp "$dataset_part" "$INPUT_DIR/$(basename "$dataset_part")"
    done
else
    if $REFRESH_DATASET || [[ ! -s "$DATASET_PATH" ]]; then
        temp_dataset="$DATASET_PATH.download"
        rm -f "$temp_dataset"
        aws s3 cp "$DATASET_S3_URI" "$temp_dataset" --region "$AWS_REGION"
        mv "$temp_dataset" "$DATASET_PATH"
    fi
    ln "$DATASET_PATH" "$INPUT_DIR/$DATASET.parquet" 2>/dev/null ||
        cp "$DATASET_PATH" "$INPUT_DIR/$DATASET.parquet"
fi

IMAGE_ID="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
IMAGE_DIGEST="$(docker image inspect "$IMAGE" --format '{{join .RepoDigests ","}}')"
GIT_COMMIT="$(git -C "$(dirname "$0")/.." rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY="$(git -C "$(dirname "$0")/.." status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

printf '%q ' "${DOCKER_COMMAND[@]}" >"$RUN_DIR/container_command.txt"
printf '\n' >>"$RUN_DIR/container_command.txt"

export RUN_ID STAGE DATASET DATASET_S3_URI IMAGE IMAGE_ID IMAGE_DIGEST
export CPUS MEMORY SHM_SIZE OUTPUT_S3_URI GIT_COMMIT GIT_DIRTY
export TRAIN_ZAFRAS EVALUATION_ZAFRAS SCORING_ZAFRAS EXCLUDE_FEATURES
export PARTITIONED AGGREGATE_PENALTY
python3 - "$RUN_DIR/run_manifest.json" <<'PY'
import json
import os
import platform
import sys

keys = [
    "RUN_ID", "STAGE", "DATASET", "DATASET_S3_URI", "IMAGE", "IMAGE_ID",
    "IMAGE_DIGEST", "CPUS", "MEMORY", "SHM_SIZE", "OUTPUT_S3_URI",
    "GIT_COMMIT", "GIT_DIRTY", "TRAIN_ZAFRAS", "EVALUATION_ZAFRAS",
    "SCORING_ZAFRAS", "EXCLUDE_FEATURES",
    "PARTITIONED", "AGGREGATE_PENALTY",
]
payload = {key.lower(): os.environ.get(key, "") for key in keys}
payload["host"] = {
    "hostname": platform.node(),
    "platform": platform.platform(),
    "python": platform.python_version(),
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
PY

"${DOCKER_COMMAND[@]}" >/dev/null
CONTAINER_CREATED=true

monitor_resources() {
    while docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; do
        state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
        timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [[ "$state" == "running" ]]; then
            docker stats --no-stream \
                --format "$timestamp,{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.BlockIO}},{{.PIDs}}" \
                "$CONTAINER_NAME" >>"$LOG_DIR/container_resources.csv" 2>/dev/null || true
        fi
        {
            printf '%s,' "$timestamp"
            awk '/MemAvailable/ {printf "%.2f,", $2 / 1024 / 1024}' /proc/meminfo
            cut -d' ' -f1-3 /proc/loadavg
        } >>"$LOG_DIR/host_resources.csv"
        [[ "$state" == "created" || "$state" == "running" ]] || break
        sleep 15
    done
}

echo "timestamp,cpu_percent,memory_usage,memory_percent,block_io,pids" \
    >"$LOG_DIR/container_resources.csv"
echo "timestamp,host_available_memory_gib,load_1m,load_5m,load_15m" \
    >"$LOG_DIR/host_resources.csv"
monitor_resources &
MONITOR_PID=$!

set +e
timeout --signal=TERM --kill-after=60 "$MAX_RUNTIME_SECONDS" \
    docker start -a "$CONTAINER_NAME" 2>&1 |
    tee "$LOG_DIR/training.log"
ATTACH_EXIT=${PIPESTATUS[0]}
set -e

if [[ "$ATTACH_EXIT" -eq 124 || "$ATTACH_EXIT" -eq 137 ]]; then
    echo "Training exceeded the stage runtime limit; stopping container" |
        tee -a "$LOG_DIR/training.log"
    docker stop --time 60 "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=""
CONTAINER_EXIT="$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME")"
FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat >"$RUN_DIR/run_status.json" <<EOF
{
  "run_id": "$RUN_ID",
  "stage": "$STAGE",
  "container_exit_code": $CONTAINER_EXIT,
  "attach_exit_code": $ATTACH_EXIT,
  "finished_at": "$FINISHED_AT",
  "artifact_s3_uri": "$OUTPUT_S3_URI"
}
EOF

docker logs "$CONTAINER_NAME" >"$LOG_DIR/container.log" 2>&1 || true
docker rm "$CONTAINER_NAME" >/dev/null
CONTAINER_CREATED=false

UPLOAD_EXIT=0
if ! $SKIP_UPLOAD; then
    set +e
    aws s3 cp "$OUTPUT_DIR" "${OUTPUT_S3_URI}output/" --recursive --region "$AWS_REGION"
    UPLOAD_EXIT=$?
    if [[ "$UPLOAD_EXIT" -eq 0 ]]; then
        aws s3 cp "$MODEL_DIR" "${OUTPUT_S3_URI}model/" --recursive --region "$AWS_REGION"
        UPLOAD_EXIT=$?
    fi
    if [[ "$UPLOAD_EXIT" -eq 0 ]]; then
        aws s3 cp "$LOG_DIR" "${OUTPUT_S3_URI}logs/" --recursive --region "$AWS_REGION"
        UPLOAD_EXIT=$?
    fi
    if [[ "$UPLOAD_EXIT" -eq 0 ]]; then
        aws s3 cp "$RUN_DIR/run_manifest.json" "${OUTPUT_S3_URI}run_manifest.json" \
            --region "$AWS_REGION"
        UPLOAD_EXIT=$?
    fi
    if [[ "$UPLOAD_EXIT" -eq 0 ]]; then
        aws s3 cp "$RUN_DIR/run_status.json" "${OUTPUT_S3_URI}run_status.json" \
            --region "$AWS_REGION"
        UPLOAD_EXIT=$?
    fi
    if [[ "$UPLOAD_EXIT" -eq 0 ]]; then
        aws s3 cp "$RUN_DIR/container_command.txt" "${OUTPUT_S3_URI}container_command.txt" \
            --region "$AWS_REGION"
        UPLOAD_EXIT=$?
    fi
    set -e
fi

echo "Run finished: $RUN_ID"
echo "Container exit code: $CONTAINER_EXIT"
echo "Local artifacts: $RUN_DIR"
if ! $SKIP_UPLOAD; then
    echo "S3 artifacts: $OUTPUT_S3_URI"
fi

[[ "$UPLOAD_EXIT" -eq 0 ]] || die "Training finished, but artifact upload failed"
exit "$CONTAINER_EXIT"
