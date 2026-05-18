-- tch_features_v3_plus_cire.sql
--
-- Ablation: core optical+climate dataset plus CIRE phenology.
-- CIRE was strong in diagnostics, but remains isolated because the literature
-- support is weaker than NDRE/GNDVI/LSWI/EVI2.

CREATE OR REPLACE VIEW public.tch_features_v3_plus_cire AS
SELECT
    core.*,
    base.cire_early_mean,
    base.cire_mid_mean,
    base.cire_late_mean,
    base.cire_mid_minus_early_mean,
    base.cire_late_minus_mid_mean,
    base.cire_auc_full,
    base.cire_auc_early,
    base.cire_auc_mid,
    base.cire_auc_late,
    base.cire_peak_value,
    base.cire_age_at_peak,
    base.cire_rise_slope,
    base.cire_senescence_slope,
    base.cire_duration_above_80pct_peak
FROM public.tch_features_v3_core_optical_climate core
JOIN public.tch_features_v3_feature_bank base USING (cod_cg_zafra);
