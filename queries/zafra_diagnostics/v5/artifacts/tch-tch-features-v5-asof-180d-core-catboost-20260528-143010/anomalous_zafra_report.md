# Diagnostico zafra anomala 2023_2024 - v5 as-of-180

## Lectura corta
- La zafra 2023_2024 tuvo diferencia agregada de 62,058 TCH (9.82%).
- Real agregado: 632,118; predicho agregado: 694,175; filas: 6,202.
- El objetivo del diagnostico es separar si el problema viene de distribucion del target, drift de features, calidad/cobertura o grupos categoricos concretos.
- Nota SHAP: el archivo `shap_values.parquet` guardado por este job contiene muestra de test 2024_2025, no validation 2023_2024; por eso no permite SHAP local directo para la zafra anomala.

## Agregado por zafra
| zafra_norm | split | rows | actual_tch_sum | pred_tch_sum | tch_sum_diff | tch_sum_pct_diff | r2 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2020_2021 | train | 6397 | 632,508.4200 | 633,013.8963 | 505.4763 | 0.0008 | 0.7819 |
| 2021_2022 | train | 6079 | 611,535.2100 | 611,437.3934 | -97.8166 | -0.0002 | 0.8051 |
| 2022_2023 | train | 6228 | 606,105.4600 | 606,129.0681 | 23.6081 | 0.0000 | 0.8087 |
| 2023_2024 | validation | 6202 | 632,117.6900 | 694,175.4991 | 62,057.8091 | 0.0982 | 0.2041 |
| 2024_2025 | test | 6187 | 625,835.3400 | 641,325.4515 | 15,490.1115 | 0.0248 | 0.4353 |
| 2025_2026 | external | 5763 | 613,220.6500 | 599,883.3224 | -13,337.3276 | -0.0217 | 0.4105 |

## Distribucion del target
| zafra_norm | split | rows | actual_tch_mean | actual_tch_median | actual_tch_p10 | actual_tch_p90 | area_sum |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2020_2021 | train | 6397 | 98.8758 | 99.3600 | 69.3500 | 127.9340 | 94,198.9900 |
| 2021_2022 | train | 6079 | 100.5980 | 101.3800 | 69.3460 | 131.0840 | 90,208.3200 |
| 2022_2023 | train | 6228 | 97.3194 | 98.1600 | 66.5850 | 127.6430 | 93,646.6500 |
| 2023_2024 | validation | 6202 | 101.9216 | 102.7900 | 72.7030 | 131.6200 | 98,972.6300 |
| 2024_2025 | test | 6187 | 101.1533 | 102.0700 | 71.9240 | 130.0480 | 100,347.5000 |
| 2025_2026 | external | 5763 | 106.4065 | 107.8600 | 75.5760 | 135.0980 | 94,793.1259 |

## Drift de features top SHAP
| feature | source | anomaly_mean | reference_mean | test_2024_2025_mean | external_2025_2026_mean | std_diff_vs_reference | anomaly_missing_rate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| enso_oni_asof_mean | enso | 0.8290 | -0.5159 | 0.3997 | -0.1642 | 3.9205 | 0.0000 |
| enso_el_nino_fraction_asof | enso | 0.3810 | 0.1255 | 0.6177 | 0.0000 | 1.4201 | 0.0000 |
| optical_ndvi_auc_91_180 | optical | 53.2021 | 44.6556 | 46.9569 | 50.4148 | 1.3323 | 0.0243 |
| climate_heat_pentad_count_0_180 | climate | 31.5743 | 22.4607 | 28.3596 | 24.5188 | 1.2497 | 0.0542 |
| optical_ndvi_mean_0_180 | optical | 0.5029 | 0.4294 | 0.4497 | 0.4965 | 1.2475 | 0.0243 |
| optical_ndvi_auc_0_180 | optical | 90.4646 | 77.4740 | 81.0171 | 88.1073 | 1.2170 | 0.0243 |
| optical_ndre_mean_0_180 | optical | 0.3619 | 0.3026 | 0.3151 | 0.3488 | 1.1946 | 0.0243 |
| climate_tmean_mean_0_180 | climate | 27.6940 | 26.9983 | 27.7269 | 27.2388 | 1.1592 | 0.0542 |
| climate_tmax_mean_0_180 | climate | 35.1258 | 34.3608 | 35.0592 | 34.4447 | 1.1060 | 0.0542 |
| optical_cire_auc_91_180 | optical | 200.4170 | 156.0072 | 165.4747 | 178.7886 | 1.0952 | 0.0243 |

## Calidad y cobertura
| zafra_norm | rows | optical_obs_count_0_180_mean | optical_max_gap_days_0_180_mean | climate_pentad_count_0_180_mean | climate_max_gap_days_0_180_mean | cycle_age_max_mean |
| --- | --- | --- | --- | --- | --- | --- |
| 2020_2021 | 6397 | 38.0906 | 7.9191 | 29.0818 | 6.0000 | 343.2711 |
| 2021_2022 | 6079 | 38.6463 | 5.3463 | 31.2604 | 6.0000 | 340.4002 |
| 2022_2023 | 6228 | 38.3661 | 5.7173 | 32.4904 | 6.0000 | 335.6957 |
| 2023_2024 | 6202 | 32.7204 | 13.1913 | 33.7715 | 6.0000 | 343.7007 |
| 2024_2025 | 6187 | 37.9437 | 7.7112 | 34.8185 | 6.0000 | 345.2038 |
| 2025_2026 | 5763 | 44.8859 | 6.8498 | 35.3908 | 6.0000 | 346.2880 |

## Categorias con mayor contribucion al error en la zafra anomala
| feature | category_value | rows | actual_tch_sum | pred_tch_sum | tch_sum_diff | tch_sum_pct_diff | tch_mae |
| --- | --- | --- | --- | --- | --- | --- | --- |
| prod_ingenio | SANTA ANA | 2211 | 233,373.2500 | 262,818.4444 | 29,445.1944 | 0.1262 | 16.9654 |
| prod_variedad | CG02-163 | 2564 | 274,042.3200 | 298,413.3646 | 24,371.0446 | 0.0889 | 15.7354 |
| prod_grupo_de_humedad | nan | 1618 | 165,096.8400 | 184,778.6935 | 19,681.8535 | 0.1192 | 17.0968 |
| prod_familia_de_suelo | FES | 1541 | 157,454.7400 | 176,820.4610 | 19,365.7210 | 0.1230 | 17.1432 |
| prod_grupo_de_suelo | FES | 1541 | 157,454.7400 | 176,820.4610 | 19,365.7210 | 0.1230 | 17.1432 |
| prod_grupo_de_humedad | 2.0 | 1710 | 161,830.4900 | 178,403.4675 | 16,572.9775 | 0.1024 | 15.9506 |
| prod_no_corte | 2 | 1168 | 121,586.3900 | 135,623.8142 | 14,037.4242 | 0.1155 | 17.0781 |
| prod_ingenio | TRINIDAD | 1097 | 110,502.3800 | 124,245.5499 | 13,743.1699 | 0.1244 | 18.0376 |
| prod_variedad | CP72-2086 | 1012 | 102,230.6300 | 114,808.4591 | 12,577.8291 | 0.1230 | 17.0332 |
| prod_no_corte | 3 | 1130 | 118,474.2000 | 129,305.0078 | 10,830.8078 | 0.0914 | 14.6539 |
| prod_grupo_de_humedad | 3.0 | 1206 | 123,990.3500 | 134,660.0697 | 10,669.7197 | 0.0861 | 15.0501 |
| prod_no_corte | 1 | 1077 | 114,526.0600 | 124,593.1653 | 10,067.1053 | 0.0879 | 16.2020 |
| prod_grupo_de_humedad | 4.0 | 967 | 105,458.7400 | 115,063.2595 | 9,604.5195 | 0.0911 | 16.1653 |
| prod_codigo_zae | 46.0 | 697 | 73,923.5400 | 83,216.2978 | 9,292.7578 | 0.1257 | 18.0271 |
| prod_grupo_de_suelo | III/S1 (TQ) (PR) | 972 | 106,417.4800 | 115,573.9690 | 9,156.4890 | 0.0860 | 16.3213 |

## Cobertura SHAP guardada
| split | zafra_norm | shap_rows |
| --- | --- | --- |
| test | 2024_2025 | 5000 |

## Archivos generados
- `target_distribution_by_zafra.csv`
- `aggregate_prediction_by_zafra.csv`
- `feature_drift_top_shap.csv`
- `data_quality_by_zafra.csv`
- `error_by_category.csv`
- `error_by_feature_bins_2023_2024.csv`
- `shap_sample_coverage.csv`
- `shap_importance_saved_sample.csv`