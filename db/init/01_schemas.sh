#!/usr/bin/env bash
# Runs once, on first start of an empty data volume.
set -euo pipefail

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v dash_password="$DASHBOARD_DB_PASSWORD" <<'SQL'
CREATE SCHEMA IF NOT EXISTS boost_intermediate;
CREATE SCHEMA IF NOT EXISTS boost;
CREATE SCHEMA IF NOT EXISTS indicator;
CREATE SCHEMA IF NOT EXISTS sboost4;

-- Read by the dashboard when AUTH_ENABLED=1; hashes come from
-- rpf-country-dash/scripts/hash_password.py (bcrypt).
CREATE TABLE IF NOT EXISTS sboost4.dashboard_user_credentials (
    username        text PRIMARY KEY,
    salted_password text NOT NULL
);

CREATE ROLE dashboard LOGIN PASSWORD :'dash_password';
GRANT CONNECT ON DATABASE prd_mega TO dashboard;
GRANT USAGE ON SCHEMA boost, indicator, sboost4 TO dashboard;
GRANT SELECT ON ALL TABLES IN SCHEMA boost, indicator, sboost4 TO dashboard;
-- Tables the pipeline creates later are readable without a new grant.
ALTER DEFAULT PRIVILEGES IN SCHEMA boost, indicator, sboost4
    GRANT SELECT ON TABLES TO dashboard;
SQL
