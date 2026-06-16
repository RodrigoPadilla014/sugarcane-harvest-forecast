import pandas as pd


def indexes_for_zafras(metadata: pd.DataFrame, zafras) -> pd.Index:
    zafra = metadata.set_index("cod_cg_zafra")["zafra_norm"]
    return zafra[zafra.isin(zafras)].index


def walk_forward_splits(
    metadata: pd.DataFrame,
    zafras,
):
    zafra_by_group = metadata.set_index("cod_cg_zafra")["zafra_norm"]
    folds = []
    for pos in range(1, len(zafras)):
        train_zafras = zafras[:pos]
        validation_zafra = zafras[pos]
        train_idx = zafra_by_group[zafra_by_group.isin(train_zafras)].index
        validation_idx = zafra_by_group[zafra_by_group == validation_zafra].index
        folds.append((validation_zafra, train_idx, validation_idx))
    return folds
