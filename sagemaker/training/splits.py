import pandas as pd


DEFAULT_TRAIN_ZAFRAS = ("2020_2021", "2021_2022", "2022_2023")
DEFAULT_VALIDATION_ZAFRAS = ("2023_2024",)
DEFAULT_TEST_ZAFRAS = ("2024_2025",)


def temporal_split(
    metadata: pd.DataFrame,
    train_zafras=DEFAULT_TRAIN_ZAFRAS,
    validation_zafras=DEFAULT_VALIDATION_ZAFRAS,
    test_zafras=DEFAULT_TEST_ZAFRAS,
):
    zafra = metadata.set_index("cod_cg_zafra")["zafra_norm"]
    train_idx = zafra[zafra.isin(train_zafras)].index
    validation_idx = zafra[zafra.isin(validation_zafras)].index
    test_idx = zafra[zafra.isin(test_zafras)].index
    return train_idx, validation_idx, test_idx


def walk_forward_splits(
    metadata: pd.DataFrame,
    zafras=("2020_2021", "2021_2022", "2022_2023", "2023_2024", "2024_2025"),
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
