-- Runs once, on first start of an empty data volume, after 01_schemas.sh.
-- Empty tables for the indicators whose producers need inputs from outside:
-- a Global Data Lab API token and the PEFA batch downloads. The steps that
-- read them (BOOST aggregates, indicator_data_availability) then run without
-- those inputs; the producing step replaces the table once they are present.
-- Columns and types match the producers' output.

CREATE TABLE IF NOT EXISTS indicator.global_data_lab_hd_index (
    country_name       text,
    adm1_name          text,
    year               integer,
    education_index    double precision,
    health_index       double precision,
    income_index       double precision,
    attendance         double precision,
    attendance_6to17yo double precision
);

CREATE TABLE IF NOT EXISTS indicator.pefa_by_pillar (
    country_name                       text,
    year                               bigint,
    framework                          text,
    pillar1_budget_reliability         double precision,
    pillar2_transparency               double precision,
    pillar3_asset_liability            double precision,
    pillar4_policy_based_budget        double precision,
    pillar5_predictability_and_control double precision,
    pillar6_accounting_and_reporting   double precision,
    pillar7_external_audit             double precision
);
