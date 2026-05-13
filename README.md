# TCH Prediction Harvest Season

Pipeline para predecir TCH por lote/zafra y estimar produccion total por zafra a partir de datasets agregados en SQL.

## Estado Actual

El flujo principal usa un dataset preagregado:

```text
queries/aggregated/tch_aggregated_features_v1.sql
```

Este SQL genera una fila por `cod_cg_zafra` desde `tch_raw_longitudinal`, conservando la logica de ciclos ya calculada en la vista cruda.

Contrato minimo del dataset:

```text
cod_cg_zafra
cod_cg
zafra_norm
area
tch
tc
fecha_inicio_ciclo
fecha_fin_ciclo
```

`tch` es el target plano. `area` y `tc` se conservan para metadata/reporting y para estimar produccion posterior, no para transformar el target.

## Dataset En S3

Dataset validado:

```text
s3://<bucket>/datasets/tch_aggregated_features_v1.parquet
```

Validacion al momento de crearlo:

```text
filas: 43,630
cod_cg_zafra distintos: 43,630
duplicados: 0
nulos en tch/zafra_norm/area: 0
```

## Imagen De Entrenamiento

La imagen custom de SageMaker esta en ECR:

```text
<account-id>.dkr.ecr.<region>.amazonaws.com/tch-sagemaker-training:latest
```

El digest exacto de la imagen debe obtenerse desde ECR cuando se necesite auditar una corrida:

```powershell
aws ecr describe-images `
  --repository-name tch-sagemaker-training `
  --image-ids imageTag=latest `
  --query "imageDetails[0].imageDigest" `
  --output text
```

Si cambia algo en `sagemaker/training/`, reconstruir y subir:

```powershell
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$REGION = "<region>"
$REPO = "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/tch-sagemaker-training"

docker build -t "$REPO:latest" -f sagemaker/docker/Dockerfile sagemaker
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
docker push "$REPO:latest"
```

## Subir Dataset

`upload_dataset.py` busca SQL en:

```text
queries/datasets/
queries/aggregated/
queries/
```

Para regenerar y subir el dataset:

```powershell
python sagemaker/jobs/upload_dataset.py tch_aggregated_features_v1
```

## Lanzar Entrenamiento

El dataset agregado debe lanzarse con:

```text
--dataset-type feature_table
```

Ejemplo completo con LightGBM, Optuna, SHAP y diagnosticos:

```powershell
python sagemaker/jobs/launch_job.py tch_aggregated_features_v1 `
  --dataset-type feature_table `
  --model-type lightgbm `
  --n-trials 10 `
  --image-uri <account-id>.dkr.ecr.<region>.amazonaws.com/tch-sagemaker-training:latest
```

Para una corrida rapida sin SHAP:

```powershell
python sagemaker/jobs/launch_job.py tch_aggregated_features_v1 `
  --dataset-type feature_table `
  --model-type lightgbm `
  --n-trials 10 `
  --no-shap `
  --image-uri <account-id>.dkr.ecr.<region>.amazonaws.com/tch-sagemaker-training:latest
```

## Artifacts

Los resultados quedan en:

```text
s3://<bucket>/experiments/{dataset}/{model_type}/{job_name}/
```

El job completo validado fue:

```text
tch-tch-aggregated-features-v1-lightgbm-20260513-124334
```

Outputs principales:

```text
output/model.tar.gz
output/output.tar.gz
```

Dentro de `output.tar.gz`:

```text
metrics.json
metrics_by_zafra.csv
split_metadata.json
feature_list.json
feature_importance_shap.csv
shap_values.parquet
feature_missing_rate.csv
feature_stability_by_split.csv
feature_correlation_pairs.csv
feature_pruning_recommendations.csv
best_params.json
```

## Resultado Validado

Job:

```text
tch-tch-aggregated-features-v1-lightgbm-20260513-124334
```

Metricas:

```text
train       R2=0.681  RMSE=14.65  MAE=10.66
validation  R2=0.360  RMSE=20.22  MAE=14.83  bias=-4.13
test        R2=0.303  RMSE=21.26  MAE=15.54  bias=-7.88
```

## Notas De Modelado

El pipeline funciona end-to-end. El siguiente trabajo es mejorar el feature set:

```text
SHAP importance
correlacion entre features
missing rate
estabilidad train vs validation/test
```

El overfit observado sugiere crear una version compacta del dataset o aplicar poda de features basada en los diagnostics.
