import numpy as np
import pandas as pd
import re


TARGET = "tch"
GROUP_COL = "cod_cg_zafra"
TIME_COL = "zafra_norm"

ID_COLS = {
    GROUP_COL,
    "cod_cg",
    TIME_COL,
    "fecha_stac",
    "stac_imagen_id",
    "cierre",
    "cierre_date",
    "cierre_ciclo",
    "radar_asc_fecha",
    "radar_asc_imagen_id",
    "radar_desc_fecha",
    "radar_desc_imagen_id",
    "enso_date",
}

TARGET_COLS = {TARGET, "tc"}

FEATURE_TABLE_METADATA_COLS = [
    GROUP_COL,
    "cod_cg",
    TIME_COL,
    "zafra",
    "area",
    "tc",
    "fecha_inicio_ciclo",
    "fecha_fin_ciclo",
]

STATIC_COLS = [
    TIME_COL,
    "area",
    "prod_ingenio",
    "prod_grupo_de_suelo",
    "prod_grupo_de_humedad",
    "prod_codigo_zae",
    "prod_finca",
    "prod_familia_de_suelo",
    "prod_variedad",
    "prod_no_corte",
]

METADATA_STATIC_COLS = ["cod_cg", TIME_COL, "area"]

EXCLUDED_FEATURE_COLS = {
    # Timing/location fields not intended as model inputs.
    "prod_semana",
    "prod_latitud",
    "prod_longitud",
    "prod_zona_longitudinal",
    "prod_estrato",
    # Yield/lab/harvest outcome leakage.
    "prod_rendimiento",
    "prod_brix",
    "prod_pureza",
    "prod_jugo",
    "prod_ph",
    "prod_pol",
    "prod_fibra",
    "prod_humedad",
    "prod_tah",
    "prod_edad",
    # Fertilization.
    "prod_nitrogeno",
    "prod_potasio",
    "prod_fosforo",
    "prod_cachaza",
    "prod_vinaza",
    "prod_sulfato",
    "prod_urea_nitro_exted",
    "prod_aplicaciones_foliares",
    "prod_pre_incorporado",
    # Irrigation.
    "prod_riego",
    "prod_total_riego_aplicado_mm",
    "prod_numero_de_riegos",
    "prod_dias_ultimo_riego",
    # Weed control.
    "prod_pre_emergente",
    "prod_post_emergente",
    "prod_pre_post_emergente",
    "prod_ultimo_control_de_malezas",
    "prod_bejuco",
    "prod_parchoneo",
    "prod_arranque",
    "prod_tipo_aplicacion_control_malezas",
    # Maturation/harvest operations.
    "prod_inhibidor_de_floracion",
    "prod_premadurante",
    "prod_madurante",
    "prod_tipo_de_aplicacion_madurante",
    "prod_dias_madurantes",
    "prod_horas_quema",
    "prod_tipo_quema",
    "prod_para_cosecha_en_verde",
    "cierre",
    "cierre_date",
    "prod_mes_de_cosecha",
    # Productividad spectral fields are intentionally not selected in the raw
    # query; keep these names blocked in case they are added later.
    "prod_ndvi",
    "prod_ndwi_11",
    "prod_ndwi_12",
    "prod_msi_11",
    "prod_msi_12",
    "prod_ultima_imagen",
    # Pest fields.
    "prod_de_infestacion_barrenador",
    "prod_tipo_de_control_para_barrenador",
    "prod_de_infestacion_de_roedores",
    "prod_tipo_de_control_para_roedores",
    "prod_chinche_salivosa_ninfas_tallo",
    "prod_chinche_salivosa_adultos_tallo",
    "prod_tipo_de_control_de_chinche",
    # Productividad climate fields; use clima_lote_pentada_new features instead.
    "prod_precipitacion",
    "prod_temp_minima",
    "prod_radiacion_solar",
    # Same blocked fields without the productividad prefix for SQL feature tables.
    "semana",
    "latitud",
    "longitud",
    "zona_longitudinal",
    "estrato",
    "rendimiento",
    "brix",
    "pureza",
    "jugo",
    "ph",
    "pol",
    "fibra",
    "humedad",
    "tah",
    "edad",
    "nitrogeno",
    "potasio",
    "fosforo",
    "cachaza",
    "vinaza",
    "sulfato",
    "urea_nitro_exted",
    "aplicaciones_foliares",
    "pre_incorporado",
    "riego",
    "total_riego_aplicado_mm",
    "numero_de_riegos",
    "dias_ultimo_riego",
    "pre_emergente",
    "post_emergente",
    "pre_post_emergente",
    "ultimo_control_de_malezas",
    "bejuco",
    "parchoneo",
    "arranque",
    "tipo_aplicacion_control_malezas",
    "inhibidor_de_floracion",
    "premadurante",
    "madurante",
    "tipo_de_aplicacion_madurante",
    "dias_madurantes",
    "horas_quema",
    "tipo_quema",
    "para_cosecha_en_verde",
    "mes_de_cosecha",
    "ndvi",
    "ndwi_11",
    "ndwi_12",
    "msi_11",
    "msi_12",
    "ultima_imagen",
    "de_infestacion_barrenador",
    "tipo_de_control_para_barrenador",
    "de_infestacion_de_roedores",
    "tipo_de_control_para_roedores",
    "chinche_salivosa_ninfas_tallo",
    "chinche_salivosa_adultos_tallo",
    "tipo_de_control_de_chinche",
    "precipitacion",
    "temp_minima",
    "radiacion_solar",
}


def _numeric_feature_columns(df: pd.DataFrame):
    numeric_cols = df.select_dtypes(include="number").columns
    return [
        col
        for col in numeric_cols
        if col not in ID_COLS
        and col not in TARGET_COLS
        and col not in EXCLUDED_FEATURE_COLS
    ]


def _log(message: str) -> None:
    print(message, flush=True)


def _sanitize_feature_name(name: object) -> str:
    sanitized = re.sub(r"[^0-9A-Za-z_]+", "_", str(name))
    sanitized = re.sub(r"_+", "_", sanitized).strip("_")
    if not sanitized:
        sanitized = "feature"
    if sanitized[0].isdigit():
        sanitized = f"f_{sanitized}"
    return sanitized


def _sanitize_feature_columns(features: pd.DataFrame) -> pd.DataFrame:
    sanitized_columns = [_sanitize_feature_name(col) for col in features.columns]
    seen = {}
    unique_columns = []
    for col in sanitized_columns:
        count = seen.get(col, 0)
        unique_columns.append(col if count == 0 else f"{col}_{count}")
        seen[col] = count + 1

    changed = sum(old != new for old, new in zip(features.columns, unique_columns))
    if changed:
        _log(f"features: sanitized feature column names={changed:,}")

    features = features.copy()
    features.columns = unique_columns
    return features


def _normalize_feature_table_columns(df: pd.DataFrame) -> pd.DataFrame:
    if TIME_COL in df.columns or "zafra" not in df.columns:
        return df
    return df.rename(columns={"zafra": TIME_COL})


def _add_light_feature_table_features(features: pd.DataFrame) -> pd.DataFrame:
    derived = {}
    for col in features.columns:
        if col.endswith("_late_mean"):
            base = col[: -len("_late_mean")]
            early_col = f"{base}_early_mean"
            mid_col = f"{base}_mid_mean"
            if early_col in features.columns:
                derived[f"{base}_late_minus_early_mean"] = features[col] - features[early_col]
            if mid_col in features.columns:
                derived[f"{base}_late_minus_mid_mean"] = features[col] - features[mid_col]
        if col.endswith("_max"):
            base = col[: -len("_max")]
            min_col = f"{base}_min"
            if min_col in features.columns:
                derived[f"{base}_range"] = features[col] - features[min_col]

    if not derived:
        return features
    _log(f"features: adding light derived columns={len(derived):,}")
    return pd.concat([features, pd.DataFrame(derived, index=features.index)], axis=1)


def _slope(values: pd.Series, ages: pd.Series) -> float:
    valid = values.notna() & ages.notna()
    if valid.sum() < 2:
        return np.nan
    x = ages[valid].astype(float).to_numpy()
    y = values[valid].astype(float).to_numpy()
    if np.unique(x).size < 2:
        return np.nan
    return float(np.polyfit(x, y, 1)[0])


def _window_aggregates(df: pd.DataFrame, columns):
    windows = {
        "early": (0, 120),
        "mid": (121, 240),
        "late": (241, None),
    }
    pieces = []

    for name, (start, end) in windows.items():
        mask = df["edad_de_cultivo"].ge(start)
        if end is not None:
            mask &= df["edad_de_cultivo"].le(end)

        window_df = df.loc[mask, [GROUP_COL, *columns]]
        if window_df.empty:
            continue

        agg = window_df.groupby(GROUP_COL)[columns].agg(["mean", "max", "min"])
        agg.columns = [f"{col}_{name}_{stat}" for col, stat in agg.columns]
        pieces.append(agg)

    if not pieces:
        return pd.DataFrame(index=pd.Index([], name=GROUP_COL))
    return pd.concat(pieces, axis=1)


def build_aggregated_dataset(df: pd.DataFrame, target: str = TARGET):
    _log("features: dropping rows without target/group/time")
    df = df.dropna(subset=[target, GROUP_COL, TIME_COL]).copy()
    df["fecha_stac"] = pd.to_datetime(df["fecha_stac"], errors="coerce")
    df["edad_de_cultivo"] = pd.to_numeric(df["edad_de_cultivo"], errors="coerce")
    df = df.sort_values([GROUP_COL, "fecha_stac"])
    _log(f"features: usable raw rows={len(df):,}, groups={df[GROUP_COL].nunique():,}")

    numeric_cols = _numeric_feature_columns(df)
    _log(f"features: numeric candidate columns={len(numeric_cols):,}")

    grouped = df.groupby(GROUP_COL, sort=False)
    _log("features: computing base numeric aggregates")
    base = grouped[numeric_cols].agg(["mean", "max", "min", "std", "last", "count"])
    base.columns = [f"{col}_{stat}" for col, stat in base.columns]

    _log("features: computing slope features")
    slopes = {}
    slope_cols = [
        col
        for col in numeric_cols
        if col.startswith(("stac_", "radar_asc_", "radar_desc_", "clima_", "enso_"))
        and not col.endswith("_days_delta")
        and (
            col.endswith("_promedio")
            or col.endswith("_mean")
            or col.endswith("_sum")
            or col.endswith("_oni")
            or col.endswith("_nino34")
            or col.endswith("_soi")
        )
    ]
    for col in slope_cols:
        slopes[f"{col}_slope"] = grouped.apply(lambda g, c=col: _slope(g[c], g["edad_de_cultivo"]))
    slope_df = pd.DataFrame(slopes)

    _log("features: computing age-window aggregates")
    window_cols = [
        col
        for col in slope_cols
        if col.endswith("_promedio")
        or col.endswith("_mean")
        or col.endswith("_sum")
        or col.endswith("_oni")
        or col.endswith("_nino34")
    ]
    window_df = _window_aggregates(df, window_cols)

    _log("features: building static categorical features")
    static = grouped[[col for col in STATIC_COLS if col in df.columns and col not in EXCLUDED_FEATURE_COLS]].first()
    metadata_static = grouped[[col for col in METADATA_STATIC_COLS if col in df.columns]].first()
    labels = grouped[[target, "tc"]].first()

    features = pd.concat([static, base, slope_df, window_df], axis=1)
    _log(f"features: before get_dummies columns={features.shape[1]:,}")
    features = pd.get_dummies(features, dummy_na=True)
    features = _sanitize_feature_columns(features)
    features = features.replace([np.inf, -np.inf], np.nan)
    _log(f"features: final columns={features.shape[1]:,}")

    metadata_cols = [GROUP_COL, "cod_cg", TIME_COL, "area", "tc"]
    metadata = labels.join(metadata_static, how="left").reset_index()
    metadata = metadata[[col for col in metadata_cols if col in metadata.columns]]

    X = features
    y = labels[target]
    return X, y, metadata


def build_feature_table_dataset(
    df: pd.DataFrame,
    target: str = TARGET,
    light_features: bool = True,
):
    df = _normalize_feature_table_columns(df).copy()
    required_cols = {GROUP_COL, TIME_COL, target, "area"}
    missing_cols = sorted(required_cols - set(df.columns))
    if missing_cols:
        raise ValueError(f"Feature table missing required columns: {missing_cols}")

    _log("features: preparing pre-aggregated feature table")
    df = df.dropna(subset=[GROUP_COL, TIME_COL, target]).copy()
    df = df.drop_duplicates(subset=[GROUP_COL], keep="first")
    df = df.set_index(GROUP_COL, drop=False)
    _log(f"features: usable feature rows={len(df):,}")

    metadata_cols = [col for col in FEATURE_TABLE_METADATA_COLS if col in df.columns]
    metadata = df[metadata_cols].copy()
    if GROUP_COL not in metadata.columns:
        metadata[GROUP_COL] = df.index
    metadata = metadata.reset_index(drop=True)

    excluded_cols = (
        set(ID_COLS)
        | TARGET_COLS
        | EXCLUDED_FEATURE_COLS
        | set(FEATURE_TABLE_METADATA_COLS)
        | {target}
    )
    feature_cols = [col for col in df.columns if col not in excluded_cols]
    features = df[feature_cols].copy()
    if light_features:
        numeric_features = features.select_dtypes(include="number")
        features = pd.concat(
            [
                _add_light_feature_table_features(numeric_features),
                features.select_dtypes(exclude="number"),
            ],
            axis=1,
        )

    _log(f"features: before get_dummies columns={features.shape[1]:,}")
    features = pd.get_dummies(features, dummy_na=True)
    features = _sanitize_feature_columns(features)
    features = features.replace([np.inf, -np.inf], np.nan)
    _log(f"features: final columns={features.shape[1]:,}")

    y = df[target].copy()
    return features, y, metadata


def build_dataset(
    df: pd.DataFrame,
    dataset_type: str = "aggregated",
    target: str = TARGET,
    light_features: bool = True,
):
    if dataset_type == "aggregated":
        return build_aggregated_dataset(df, target=target)
    if dataset_type in {"feature_table", "preaggregated"}:
        return build_feature_table_dataset(df, target=target, light_features=light_features)
    if dataset_type == "sequential":
        raise NotImplementedError("Sequential dataset support is planned but not implemented yet.")
    raise ValueError(f"Unknown dataset_type: {dataset_type}")
