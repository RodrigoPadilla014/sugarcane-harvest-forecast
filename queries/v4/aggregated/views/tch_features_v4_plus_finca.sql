-- tch_features_v4_plus_finca.sql
--
-- Ablation: core optical+climate dataset plus raw finca.
-- This intentionally keeps finca isolated because v1 generated hundreds of
-- finca dummies and may have learned spatial/management identity.

CREATE OR REPLACE VIEW public.tch_features_v4_plus_finca AS
SELECT
    core.*,
    base.prod_finca
FROM public.tch_features_v4_core_optical_climate core
JOIN public.tch_features_v4_feature_bank base USING (cod_cg_zafra);
