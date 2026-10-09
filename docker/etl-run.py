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
  mega-boost/Togo/<script>     TGO_ETL.py, then TGO_aggregate.py

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
import time
import urllib.request

UPSTREAM = os.environ.get("UPSTREAM_DIR", "/opt/upstream")
INDICATORS = os.path.join(UPSTREAM, "mega-indicators")
BOOST_TOGO = os.path.join(UPSTREAM, "mega-boost", "Togo")
PEFA_DIR = os.environ.get("PEFA_DIR", "/data/pefa")
PEFA_TABLES = ["pefa_2011_bronze", "pefa_2016_bronze"]
BOOST_SCRIPTS = ["TGO_ETL.py", "TGO_aggregate.py"]
BOUNDARIES_EXTRACT = "mega-indicators/geo/admin_boundaries_extract.py"
# Where the extract writes the downloaded GeoJSON files (VOLUME_ROOT_PATH in config.py),
# and the Databricks volume path ddh_bytes checks first (utils.ddh_volume_path of the URLs).
BOUNDARIES_DOWNLOADED = os.path.join(os.environ.get("DATA_ROOT", "/var/lib/etl"), "raw_data",
                                     "auxiliary_data", "admin*geoboundaries", "*.geojson")
DDH_BOUNDARIES_DIR = os.environ.get("DDH_BOUNDARIES_DIR")

# Read as upstream's CSV table store reads a table (utils.read_table).
LOAD_CSV = (
    "import sys, pandas as pd\n"
    "from utils import write_table\n"
    "write_table(pd.read_csv(sys.argv[1], keep_default_na=False, na_values=['', 'null']), sys.argv[2])\n"
)


def notebooks():
    sys.path.insert(0, INDICATORS)
    import local_runner
    return local_runner.notebooks()


def steps():
    """(name, command, working directory) for every step; command None runs load_pefa."""
    out = [("inputs/pefa_bronze", None, INDICATORS)]
    out += [(f"mega-indicators/{nb}", [sys.executable, "local_runner.py", nb], INDICATORS)
            for nb in notebooks()]
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
        if command is None:
            status = load_pefa()
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
