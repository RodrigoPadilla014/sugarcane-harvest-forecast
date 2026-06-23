#!/usr/bin/env bash
set -Eeuo pipefail

DATASET_DEFAULT="tch_features_v10_productivity_history_snapshots"
BUCKET_DEFAULT="ndvi-extraction"
REGION_DEFAULT="us-east-1"
TRAIN_ZAFRAS_DEFAULT="2020_2021,2021_2022,2022_2023,2023_2024"
EVALUATION_ZAFRAS_DEFAULT="2024_2025,2025_2026"
SCORING_ZAFRAS_DEFAULT="2026_2027"
ECR_REPOSITORY_DEFAULT="tch-sagemaker-training"

STAGE=""
DATASET="${TCH_DATASET:-$DATASET_DEFAULT}"
BUCKET="${TCH_BUCKET:-$BUCKET_DEFAULT}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$REGION_DEFAULT}}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
if [[ -z "$AWS_ACCOUNT_ID" && -z "${TCH_IMAGE:-}" ]]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
fi
IMAGE_DEFAULT="${AWS_ACCOUNT_ID:+$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/${TCH_ECR_REPOSITORY:-$ECR_REPOSITORY_DEFAULT}:latest}"
IMAGE="${TCH_IMAGE:-$IMAGE_DEFAULT}"
WORK_ROOT="${TCH_WORK_ROOT:-$HOME/tch-training}"
CPUS="${TCH_CPUS:-4}"
MEMORY="${TCH_MEMORY:-14g}"
SHM_SIZE="${TCH_SHM_SIZE:-2g}"
CODE_DIR="${TCH_CODE_DIR:-}"
EXCLUDE_FEATURES="${TCH_EXCLUDE_FEATURES:-}"
TRAIN_ZAFRAS="${TCH_TRAIN_ZAFRAS:-$TRAIN_ZAFRAS_DEFAULT}"
EVALUATION_ZAFRAS="${TCH_EVALUATION_ZAFRAS:-$EVALUATION_ZAFRAS_DEFAULT}"
SCORING_ZAFRAS="${TCH_SCORING_ZAFRAS:-$SCORING_ZAFRAS_DEFAULT}"
AGGREGATE_PENALTY="${TCH_AGGREGATE_PENALTY:-}"
TARGET_MODE="${TCH_TARGET_MODE:-residual_last_hist_tch}"
MODEL_TYPE="${TCH_MODEL_TYPE:-catboost}"
WEIGHT_MODE="${TCH_WEIGHT_MODE:-snapshot_historical_tch}"
WEIGHT_MAX_MULTIPLIER="${TCH_WEIGHT_MAX_MULTIPLIER:-1.25}"
WEIGHT_DENSITY_BIN_WIDTH="${TCH_WEIGHT_DENSITY_BIN_WIDTH:-5.0}"
HIGH_YIELD_PENALTY="${TCH_HIGH_YIELD_PENALTY:-0.0}"
WORST_ESTRATO_PENALTY="${TCH_WORST_ESTRATO_PENALTY:-0.0}"
FIXED_PARAMS_JSON="${TCH_FIXED_PARAMS_JSON:-}"
FIXED_PARAMS_FILE="${TCH_FIXED_PARAMS_FILE:-}"
SEARCH_PROFILE="${TCH_SEARCH_PROFILE:-default}"
QUANTILES="${TCH_QUANTILES:-true}"
WALK_FORWARD_QUANTILES="${TCH_WALK_FORWARD_QUANTILES:-false}"
SHAP="${TCH_SHAP:-true}"
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
  --code-dir PATH             Mount training code at /opt/ml/code read-only.
  --exclude-features CSV      Comma-separated approved feature exclusions.
  --aggregate-penalty NUMBER  Override the stage aggregate penalty.
  --target-mode MODE          absolute, residual_last_hist_tch, or direct_metric_tons.
  --model-type MODEL          catboost, ridge, lightgbm, random_forest, or xgboost.
  --weight-mode MODE          snapshot, snapshot_sqrt_area, snapshot_density,
                              snapshot_historical_tch, or snapshot_area_density.
  --weight-max-multiplier N   Maximum effective modifier. Default: 1.0.
  --weight-density-bin-width N  Density histogram width in TCH. Default: 5.0.
  --high-yield-penalty N      Optional Optuna high-yield bias penalty. Default: 0.
  --worst-estrato-penalty N   Optional Optuna worst-estrato penalty. Default: 0.
  --fixed-params-json JSON    Fixed model parameters; requires baseline stage.
  --fixed-params-file PATH    Read fixed model parameters from a JSON file.
  --search-profile NAME       Optuna space: default or phase4_catboost.
  --quantiles BOOL            Train final P10/P50/P90 models. Default: true.
  --walk-forward-quantiles BOOL  Save leakage-safe fold P10/P50/P90. Default: false.
  --shap BOOL                 Generate SHAP artifacts. Default: true.
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
        --code-dir)
            CODE_DIR="${2:?Missing value for --code-dir}"
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
        --target-mode)
            TARGET_MODE="${2:?Missing value for --target-mode}"
            shift 2
            ;;
        --model-type)
            MODEL_TYPE="${2:?Missing value for --model-type}"
            shift 2
            ;;
        --weight-mode)
            WEIGHT_MODE="${2:?Missing value for --weight-mode}"
            shift 2
            ;;
        --weight-max-multiplier)
            WEIGHT_MAX_MULTIPLIER="${2:?Missing value for --weight-max-multiplier}"
            shift 2
            ;;
        --weight-density-bin-width)
            WEIGHT_DENSITY_BIN_WIDTH="${2:?Missing value for --weight-density-bin-width}"
            shift 2
            ;;
        --high-yield-penalty)
            HIGH_YIELD_PENALTY="${2:?Missing value for --high-yield-penalty}"
            shift 2
            ;;
        --worst-estrato-penalty)
            WORST_ESTRATO_PENALTY="${2:?Missing value for --worst-estrato-penalty}"
            shift 2
            ;;
        --fixed-params-json)
            FIXED_PARAMS_JSON="${2:?Missing value for --fixed-params-json}"
            shift 2
            ;;
        --fixed-params-file)
            FIXED_PARAMS_FILE="${2:?Missing value for --fixed-params-file}"
            shift 2
            ;;
        --search-profile)
            SEARCH_PROFILE="${2:?Missing value for --search-profile}"
            shift 2
            ;;
        --quantiles)
            QUANTILES="${2:?Missing value for --quantiles}"
            shift 2
            ;;
        --walk-forward-quantiles)
            WALK_FORWARD_QUANTILES="${2:?Missing value for --walk-forward-quantiles}"
            shift 2
            ;;
        --shap)
            SHAP="${2:?Missing value for --shap}"
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
[[ -n "$IMAGE" ]] ||
    die "Docker image URI is required. Set TCH_IMAGE or AWS_ACCOUNT_ID so the default ECR image can be resolved."
[[ "$TARGET_MODE" == "absolute" || "$TARGET_MODE" == "residual_last_hist_tch" || "$TARGET_MODE" == "direct_metric_tons" ]] ||
    die "Unknown --target-mode: $TARGET_MODE"
case "$MODEL_TYPE" in
    catboost|ridge|lightgbm|random_forest|xgboost) ;;
    *) die "Unknown --model-type: $MODEL_TYPE" ;;
esac
case "$WEIGHT_MODE" in
    snapshot|snapshot_sqrt_area|snapshot_density|snapshot_historical_tch|snapshot_area_density) ;;
    *) die "Unknown --weight-mode: $WEIGHT_MODE" ;;
esac
case "$SEARCH_PROFILE" in
    default|phase4_catboost) ;;
    *) die "Unknown --search-profile: $SEARCH_PROFILE" ;;
esac
case "$QUANTILES" in
    true|false) ;;
    *) die "Unknown --quantiles value: $QUANTILES" ;;
esac
case "$WALK_FORWARD_QUANTILES" in
    true|false) ;;
    *) die "Unknown --walk-forward-quantiles value: $WALK_FORWARD_QUANTILES" ;;
esac
case "$SHAP" in
    true|false) ;;
    *) die "Unknown --shap value: $SHAP" ;;
esac
if [[ -n "$FIXED_PARAMS_JSON" && -n "$FIXED_PARAMS_FILE" ]]; then
    die "Use only one of --fixed-params-json or --fixed-params-file"
fi
if [[ -n "$FIXED_PARAMS_FILE" ]]; then
    [[ -f "$FIXED_PARAMS_FILE" ]] || die "Fixed params file not found: $FIXED_PARAMS_FILE"
    FIXED_PARAMS_JSON="$(<"$FIXED_PARAMS_FILE")"
fi
if [[ -n "$FIXED_PARAMS_JSON" && "$STAGE" != "baseline" ]]; then
    die "--fixed-params-json currently requires the baseline stage"
fi
if [[ "$MODEL_TYPE" == "catboost" ]]; then
    CATEGORICAL_MODE="native"
    ONE_HOT_FEATURES="false"
else
    CATEGORICAL_MODE="controlled"
    ONE_HOT_FEATURES="true"
fi

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
            --objective-mode aggregate_metric_tons
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
            --objective-mode aggregate_metric_tons
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
    --model-type "$MODEL_TYPE"
    --target-mode "$TARGET_MODE"
    --categorical-mode "$CATEGORICAL_MODE"
    --one-hot-features "$ONE_HOT_FEATURES"
    --light-features false
    --quantiles "$QUANTILES"
    --walk-forward-quantiles "$WALK_FORWARD_QUANTILES"
    --shap "$SHAP"
    --diagnostics true
    --train-zafras "$TRAIN_ZAFRAS"
    --evaluation-zafras "$EVALUATION_ZAFRAS"
    --scoring-zafras "$SCORING_ZAFRAS"
    --weight-mode "$WEIGHT_MODE"
    --weight-max-multiplier "$WEIGHT_MAX_MULTIPLIER"
    --weight-density-bin-width "$WEIGHT_DENSITY_BIN_WIDTH"
    --high-yield-penalty "$HIGH_YIELD_PENALTY"
    --worst-estrato-penalty "$WORST_ESTRATO_PENALTY"
    --search-profile "$SEARCH_PROFILE"
)
if [[ -n "$FIXED_PARAMS_JSON" ]]; then
    COMMON_ARGS+=(--fixed-params-json "$FIXED_PARAMS_JSON")
fi
if [[ -n "$EXCLUDE_FEATURES" ]]; then
    COMMON_ARGS+=(--exclude-features "$EXCLUDE_FEATURES")
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TARGET_MODE_SLUG="${TARGET_MODE//_/-}"
MODEL_TYPE_SLUG="${MODEL_TYPE//_/-}"
WEIGHT_MODE_SLUG="${WEIGHT_MODE//_/-}"
RUN_ID="tch-${DATASET//_/-}-${TARGET_MODE_SLUG}-${MODEL_TYPE_SLUG}-${WEIGHT_MODE_SLUG}-${STAGE}-${TIMESTAMP}"
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
    --workdir /tmp
    --label "tch.run_id=$RUN_ID"
    --label "tch.stage=$STAGE"
    --label "tch.dataset=$DATASET"
    -v "$INPUT_DIR:/opt/ml/input/data/train:ro"
    -v "$OUTPUT_DIR:/opt/ml/output/data"
    -v "$MODEL_DIR:/opt/ml/model"
)
if [[ -n "$CODE_DIR" ]]; then
    [[ -d "$CODE_DIR" ]] || die "Code directory does not exist: $CODE_DIR"
    DOCKER_COMMAND+=(-v "$CODE_DIR:/opt/ml/code:ro")
fi
DOCKER_COMMAND+=(
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
Code override:   ${CODE_DIR:-<image contents>}
Local run dir:   $RUN_DIR
Artifact target: $OUTPUT_S3_URI
Max runtime:     $MAX_RUNTIME_SECONDS seconds
Excluded:        ${EXCLUDE_FEATURES:-<none>}
Aggregate pen.:  ${AGGREGATE_PENALTY:-<stage default>}
Target mode:     $TARGET_MODE
Model type:      $MODEL_TYPE
Search profile:  $SEARCH_PROFILE
Quantiles:       $QUANTILES
SHAP:            $SHAP
Weight mode:     $WEIGHT_MODE
Weight cap:      $WEIGHT_MAX_MULTIPLIER
Density bin:     $WEIGHT_DENSITY_BIN_WIDTH
Objective extra: high_yield=$HIGH_YIELD_PENALTY worst_estrato=$WORST_ESTRATO_PENALTY
Fixed params:    ${FIXED_PARAMS_JSON:-<none>}
Fixed file:      ${FIXED_PARAMS_FILE:-<none>}
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
if git -C "$(dirname "$0")/.." rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_DIRTY="$(git -C "$(dirname "$0")/.." status --porcelain | wc -l | tr -d ' ')"
else
    GIT_DIRTY="unknown"
fi

printf '%q ' "${DOCKER_COMMAND[@]}" >"$RUN_DIR/container_command.txt"
printf '\n' >>"$RUN_DIR/container_command.txt"

export RUN_ID STAGE DATASET DATASET_S3_URI IMAGE IMAGE_ID IMAGE_DIGEST
export CPUS MEMORY SHM_SIZE OUTPUT_S3_URI GIT_COMMIT GIT_DIRTY
export TRAIN_ZAFRAS EVALUATION_ZAFRAS SCORING_ZAFRAS EXCLUDE_FEATURES
export PARTITIONED AGGREGATE_PENALTY
export TARGET_MODE MODEL_TYPE CODE_DIR WEIGHT_MODE WEIGHT_MAX_MULTIPLIER
export WEIGHT_DENSITY_BIN_WIDTH HIGH_YIELD_PENALTY WORST_ESTRATO_PENALTY
export FIXED_PARAMS_JSON
export FIXED_PARAMS_FILE SEARCH_PROFILE QUANTILES SHAP
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
    "PARTITIONED", "AGGREGATE_PENALTY", "TARGET_MODE", "MODEL_TYPE", "CODE_DIR",
    "WEIGHT_MODE", "WEIGHT_MAX_MULTIPLIER", "WEIGHT_DENSITY_BIN_WIDTH",
    "HIGH_YIELD_PENALTY", "WORST_ESTRATO_PENALTY", "FIXED_PARAMS_JSON",
    "FIXED_PARAMS_FILE", "SEARCH_PROFILE", "QUANTILES", "SHAP",
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
