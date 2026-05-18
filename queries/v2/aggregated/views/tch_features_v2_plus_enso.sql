-- tch_features_v2_plus_enso.sql
--
-- Ablation: core optical+climate dataset plus compact ENSO context.

CREATE OR REPLACE VIEW public.tch_features_v2_plus_enso AS
SELECT
    core.*,
    base.nino34_precycle_mean,
    base.nino34_first_180d_mean,
    base.nino34_abs_max_first_180d,
    base.oni_precycle_mean,
    base.oni_first_180d_mean,
    base.soi_precycle_mean,
    base.soi_first_180d_mean,
    base.mei_precycle_mean,
    base.pdo_precycle_mean,
    base.enso_phase_precycle
FROM public.tch_features_v2_core_optical_climate core
JOIN public.tch_features_v2_feature_bank base USING (cod_cg_zafra);
