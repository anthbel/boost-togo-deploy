#!/usr/bin/env python3
"""Runs the upstream ETL against the PostgreSQL database in POSTGRES_DSN.

Steps, in this order:
  inputs/pefa_bronze           loads $PEFA_DIR/pefa_2011_bronze.csv and
                               pefa_2016_bronze.csv, when present, into the
                               tables of the same name (upstream README,
                               "Required inputs")
  mega-indicators/<notebook>   local_runner.notebooks(): NOTEBOOKS, then the
                               subnational population step of COUNTRY_NAME,
                               in upstream's order
  inputs/togo_revenue_budget   right after the notebook that writes
                               indicator.togo_revenue_budget: when
                               $INPUT_DIR/solde_budgetaire.csv is present, the
                               table is replaced by that file's years
  mega-boost/Togo/<script>     TGO_ETL.py, TGO_aggregate.py, then
                               TGO_execution.py

Each step runs in its own process and a failed step does not stop the
others. After a successful geo/admin_boundaries_extract.py the two boundary
files are copied to DDH_BOUNDARIES_DIR, where upstream's ddh_bytes reads them
instead of downloading on later runs. Afterwards the dashboard's query cache
is cleared. The exit code is 1 when a step failed or the cache could not be
cleared.

  etl-run                  every step
  etl-run --list           the step names
  etl-run --only STEP...   only these steps, in the order above
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

UPSTREAM = os.environ.get("UPSTREAM_DIR", "/opt/upstream")
INDICATORS = os.path.join(UPSTREAM, "mega-indicators")
BOOST_TOGO = os.path.join(UPSTREAM, "mega-boost", "Togo")
PEFA_DIR = os.environ.get("PEFA_DIR", "/data/pefa")
PEFA_TABLES = ["pefa_2011_bronze", "pefa_2016_bronze"]
BOOST_SCRIPTS = ["TGO_ETL.py", "TGO_aggregate.py", "TGO_execution.py"]
BOUNDARIES_EXTRACT = "mega-indicators/geo/admin_boundaries_extract.py"
# Where the extract writes the downloaded GeoJSON files (VOLUME_ROOT_PATH in config.py),
# and the Databricks volume path ddh_bytes checks first (utils.ddh_volume_path of the URLs).
BOUNDARIES_DOWNLOADED = os.path.join(os.environ.get("DATA_ROOT", "/var/lib/etl"), "raw_data",
                                     "auxiliary_data", "admin*geoboundaries", "*.geojson")
DDH_BOUNDARIES_DIR = os.environ.get("DDH_BOUNDARIES_DIR")

# The DGBF's yearly budget figures (revenue, expenditure, tax expenditure, in
# billion XOF), replacing the figures the upstream notebook below writes.
TOGO_FISCAL_FILE = os.path.join(os.environ.get("INPUT_DIR", "/data/togo"), "solde_budgetaire.csv")
TOGO_FISCAL_NOTEBOOK = "mega-indicators/public_finance/togo/togo_finance_report_transform_load_dlt.py"
TOGO_FISCAL_TABLE = "togo_revenue_budget"
TOGO_FISCAL_SOURCE = "Togo DGBF"

# Read as upstream's CSV table store reads a table (utils.read_table).
LOAD_CSV = (
    "import sys, pandas as pd\n"
    "from utils import write_table\n"
    "write_table(pd.read_csv(sys.argv[1], keep_default_na=False, na_values=['', 'null']), sys.argv[2])\n"
)


def read_togo_fiscal(path):
    """The rows of ``path`` as indicator.togo_revenue_budget rows, amounts in whole XOF.

    The file has one row per year: annee, recettes, depenses (billion XOF) and,
    optionally, depenses_fiscales and source. Fields are separated by ';' (decimal
    comma allowed) or ','; spaces inside numbers are ignored. Raises ValueError on a
    missing column, a non-numeric amount, an empty receipt or spending figure, or a
    year given twice.
    """
    import pandas as pd

    with open(path, encoding="utf-8-sig") as f:
        header = f.readline()
    sep = ";" if ";" in header else ","
    raw = pd.read_csv(path, sep=sep, dtype=str, keep_default_na=False, encoding="utf-8-sig")
    raw.columns = [c.strip().lower() for c in raw.columns]
    missing = [c for c in ("annee", "recettes", "depenses") if c not in raw.columns]
    if missing:
        raise ValueError(f"{path}: missing column(s) {', '.join(missing)}")
    raw = raw[raw["annee"].str.strip() != ""]

    def amounts(column, required):
        if column not in raw.columns:
            return pd.Series(float("nan"), index=raw.index)
        text = raw[column].str.replace(r"[\s\u00a0\u202f]", "", regex=True)
        if sep == ";":
            text = text.str.replace(",", ".", regex=False)
        values = pd.to_numeric(text.where(text != ""), errors="coerce")
        bad = raw.loc[(text != "") & values.isna(), column]
        if not bad.empty:
            raise ValueError(f"{path}: {column} is not a number: {', '.join(bad)}")
        if required and values.isna().any():
            years = raw.loc[values.isna(), "annee"].str.strip()
            raise ValueError(f"{path}: {column} is empty for {', '.join(years)}")
        return values * 1e9

    years = pd.to_numeric(raw["annee"].str.strip(), errors="coerce")
    not_years = years.isna() | (years % 1 != 0)
    if not_years.any():
        raise ValueError(f"{path}: annee is not a year: {', '.join(raw.loc[not_years, 'annee'])}")
    duplicated = sorted(years[years.duplicated()].astype(int).unique())
    if duplicated:
        raise ValueError(f"{path}: year(s) given twice: {', '.join(map(str, duplicated))}")
    source = raw["source"].str.strip() if "source" in raw.columns else pd.Series("", index=raw.index)
    return pd.DataFrame({
        "country_name": "Togo",
        "country_code": "TGO",
        "year": years.astype(int),
        "revenue_current_lcu": amounts("recettes", True),
        "expenditure_current_lcu": amounts("depenses", True),
        "tax_expenditure": amounts("depenses_fiscales", False),
        "data_source": source.where(source != "", TOGO_FISCAL_SOURCE),
        "source_url": "",
    }).sort_values("year").reset_index(drop=True)


def load_togo_fiscal():
    if not os.path.isfile(TOGO_FISCAL_FILE):
        print(f"no {TOGO_FISCAL_FILE}; the figures written by {TOGO_FISCAL_NOTEBOOK} are kept", flush=True)
        return "skipped"
    try:
        rows = read_togo_fiscal(TOGO_FISCAL_FILE)
    except ValueError as error:
        print(error, flush=True)
        return "failed"
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as f:
        rows.to_csv(f, index=False)
    try:
        if subprocess.run([sys.executable, "-c", LOAD_CSV, f.name, TOGO_FISCAL_TABLE],
                          cwd=INDICATORS, stdin=subprocess.DEVNULL).returncode:
            return "failed"
    finally:
        os.unlink(f.name)
    print(f"{TOGO_FISCAL_TABLE}: years {', '.join(map(str, rows['year']))} from {TOGO_FISCAL_FILE}", flush=True)
    return "ok"


def notebooks():
    sys.path.insert(0, INDICATORS)
    import local_runner
    return local_runner.notebooks()


def steps():
    """(name, command, working directory) for every step; a command that is a function
    is called in this process instead of being run."""
    out = [("inputs/pefa_bronze", load_pefa, INDICATORS)]
    for nb in notebooks():
        out.append((f"mega-indicators/{nb}", [sys.executable, "local_runner.py", nb], INDICATORS))
        if f"mega-indicators/{nb}" == TOGO_FISCAL_NOTEBOOK:
            out.append(("inputs/togo_revenue_budget", load_togo_fiscal, INDICATORS))
    out += [(f"mega-boost/Togo/{s}", [sys.executable, s], BOOST_TOGO) for s in BOOST_SCRIPTS]
    return out


def load_pefa():
    present = [t for t in PEFA_TABLES if os.path.isfile(os.path.join(PEFA_DIR, f"{t}.csv"))]
    if not present:
        print(f"no {' or '.join(t + '.csv' for t in PEFA_TABLES)} in {PEFA_DIR}; "
              "the PEFA tables already in the database are kept", flush=True)
        return "skipped"
    for table in present:
        path = os.path.join(PEFA_DIR, f"{table}.csv")
        if subprocess.run([sys.executable, "-c", LOAD_CSV, path, table],
                          cwd=INDICATORS, stdin=subprocess.DEVNULL).returncode:
            return "failed"
    return "ok"


def cache_boundaries():
    """Copy the downloaded boundary files to DDH_BOUNDARIES_DIR when not there yet."""
    if not DDH_BOUNDARIES_DIR:
        return
    for source in sorted(glob.glob(BOUNDARIES_DOWNLOADED)):
        target = os.path.join(DDH_BOUNDARIES_DIR, os.path.basename(source))
        if os.path.exists(target):
            continue
        shutil.copyfile(source, target + ".part")
        os.replace(target + ".part", target)
        print(f"cached {os.path.basename(source)} in {DDH_BOUNDARIES_DIR}", flush=True)


def clear_cache():
    url = os.environ.get("DASHBOARD_URL")
    token = os.environ.get("CACHE_REFRESH_TOKEN")
    if not url or not token:
        print("DASHBOARD_URL or CACHE_REFRESH_TOKEN is not set; dashboard cache not cleared", flush=True)
        return False
    request = urllib.request.Request(f"{url.rstrip('/')}/api/cache/clear", method="POST",
                                     headers={"X-Refresh-Token": token})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            print(f"dashboard cache cleared: {response.read().decode().strip()}", flush=True)
            return True
    except OSError as error:
        print(f"dashboard cache not cleared ({url}): {error}", flush=True)
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--list", action="store_true", help="print the step names and exit")
    group.add_argument("--only", nargs="+", metavar="STEP", help="run only these steps")
    args = parser.parse_args()

    # compose passes an unset .env value as an empty string; upstream's get_secret
    # reports a missing token only when the variable is absent.
    if os.environ.get("GDL_API_TOKEN") == "":
        del os.environ["GDL_API_TOKEN"]

    plan = steps()
    if args.list:
        print("\n".join(name for name, _, _ in plan))
        return 0
    if args.only:
        unknown = sorted(set(args.only) - {name for name, _, _ in plan})
        if unknown:
            print(f"unknown step(s): {' '.join(unknown)}; etl-run --list prints the names", file=sys.stderr)
            return 2
        plan = [step for step in plan if step[0] in args.only]

    results = []
    for name, command, cwd in plan:
        print(f"==> {name}", flush=True)
        start = time.monotonic()
        if callable(command):
            status = command()
        else:
            status = "failed" if subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL).returncode else "ok"
        if name == BOUNDARIES_EXTRACT and status == "ok":
            cache_boundaries()
        seconds = time.monotonic() - start
        print(f"<== {name}: {status} ({seconds:.0f} s)", flush=True)
        results.append((name, status, seconds))

    cache_cleared = clear_cache()
    width = max(len(name) for name, _, _ in results)
    print("\nsummary")
    for name, status, seconds in results:
        print(f"  {name:<{width}}  {status:<7}  {seconds:5.0f} s")
    failed = [name for name, status, _ in results if status == "failed"]
    print(f"{len(failed)} step(s) failed of {len(results)}" + (f": {' '.join(failed)}" if failed else ""))
    return 1 if failed or not cache_cleared else 0


if __name__ == "__main__":
    sys.exit(main())
