-- tch_features_v4_plus_sar.sql
--
-- Ablation: core optical+climate dataset plus parsimonious Sentinel-1 SAR features.
-- Keeps VH, VV, ratio/CR-like signal, and an ASC/DESC sensitivity check.
-- RVI is retained as experimental but isolated in this SAR ablation.

CREATE OR REPLACE VIEW public.tch_features_v4_plus_sar AS
SELECT
    core.*,
    base.sar_obs_count,
    base.sar_missing_rate,
    base.sar_vh_early_mean,
    base.sar_vh_mid_mean,
    base.sar_vh_late_mean,
    base.sar_vh_slope,
    base.sar_vv_early_mean,
    base.sar_vv_mid_mean,
    base.sar_vv_late_mean,
    base.sar_vv_slope,
    base.sar_ratio_early_mean,
    base.sar_ratio_mid_mean,
    base.sar_ratio_late_mean,
    base.sar_ratio_slope,
    base.sar_asc_vh_mean,
    base.sar_desc_vh_mean,
    base.sar_vh_asc_desc_diff,
    base.sar_rvi_early_mean,
    base.sar_rvi_mid_mean,
    base.sar_rvi_late_mean,
    base.sar_rvi_slope
FROM public.tch_features_v4_core_optical_climate core
JOIN public.tch_features_v4_feature_bank base USING (cod_cg_zafra);
