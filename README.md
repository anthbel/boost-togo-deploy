# BOOST Togo — deployment

Runs the BOOST dashboard for Togo on a server with PostgreSQL, using the DIME
code at pinned commits. This repository holds only the packaging: no
dashboard or ETL code.

| Upstream repository | Used | Image |
|---|---|---|
| [rpf-country-dash](https://github.com/dime-worldbank/rpf-country-dash) | the dashboard | `boost-togo/dashboard` |
| [mega-indicators](https://github.com/dime-worldbank/mega-indicators) | the notebooks `local_runner.notebooks()` lists | `boost-togo/pipeline` |
| [mega-boost](https://github.com/dime-worldbank/mega-boost) | `Togo/` | `boost-togo/pipeline` |

## Layout

| Path | Content |
|---|---|
| `upstream.lock` | pinned upstream commits |
| `scripts/fetch-upstream.sh` | checks them out under `upstream/` |
| `docker/` | Dockerfiles, ETL runner, ETL Python packages |
| `compose.yaml` | services `db`, `dashboard`, `pipeline` |
| `db/init/` | schemas, roles, empty GDL and PEFA tables |
| `deploy/` | server preparation, offline install, Nginx site |
| `scripts/package-release.sh` | offline installation package |
| `Makefile` | operations; `make` lists the targets |

## Upstream code

`make fetch` checks out the commits in `upstream.lock` under `upstream/`.

- **Dashboard:** a commit on the [anthbel fork](https://github.com/anthbel/rpf-country-dash)
  that merges upstream `main` (PostgreSQL backend), `Togo` (Togo view) and the
  branches `upstream.lock` names, not merged upstream yet. The fetch stops if
  the commit does not give the tree in `DASHBOARD_TREE`.
- **ETL:** mega-indicators `main` and mega-boost `main`, only the folders in
  `INDICATORS_PATHS` and `BOOST_PATHS`.

To move a pin, edit `upstream.lock` (for the dashboard, the new tree is
`git rev-parse <commit>^{tree}` for one commit, `git merge-tree --write-tree
<main> <Togo>` for two), then `make fetch build` and check the dashboard.

## Requirements

- Build machine: Docker with Compose v2, git 2.38 or later, make, and access
  to github.com, Docker Hub and PyPI.
- Server: Ubuntu 22.04 or later, prepared with `deploy/prerequisites.sh`.

## Run

On a new Ubuntu server, one script does every step: git 2.38 or later,
clone into `/opt/boost-togo/boost-togo-deploy`, `deploy/prerequisites.sh`,
`.env` with generated secrets, `make fetch build up` and `make pipeline`,
as the `boost` service account:

```bash
curl -fsSLO https://raw.githubusercontent.com/anthbel/boost-togo-deploy/main/deploy/install-from-git.sh
sudo bash install-from-git.sh --workbook 'BUDGET 2021 to 2025.xlsx' --pefa-dir pefa/
```

Ubuntu 22.04 ships git 2.34: add `--git-ppa` to install a recent git from
`ppa:git-core/ppa`. `--help` lists the other options; running the script
again updates the clone and keeps `.env`.

By hand, from a clone:

```bash
cp .env.example .env    # fill in the secrets
make fetch build up
make pipeline
```

The dashboard listens on `127.0.0.1:8080` (`DASHBOARD_BIND`); serve it
through the Nginx site in `deploy/nginx/`.

A second copy on the same machine needs its own `COMPOSE_PROJECT_NAME` and
`RELEASE`, or it takes over the first copy's containers and images.

## Pipeline

`make pipeline` runs, in order, each step in its own process:

1. `inputs/pefa_bronze`: loads the PEFA CSV files from `data/pefa/`, if any.
2. The mega-indicators notebooks, in upstream's order.
3. `mega-boost/Togo/TGO_ETL.py`, then `TGO_aggregate.py`.

A failed step does not stop the others. At the end the dashboard cache is
cleared and a summary printed; the exit code is 1 if a step failed.
`make steps` lists the steps; `make pipeline STEPS="…"` runs some of them.

The World Bank boundary files (430 MB) are downloaded once and kept in the
`ddhcache` volume. `make refresh-boundaries` downloads them again on the next
run.

Outbound HTTPS needed: `api.worldbank.org`, `api.imf.org`,
`api.uis.unesco.org`, `ghoapi.azureedge.net`, `ddh-openapi.worldbank.org`,
`datacatalogfiles.worldbank.org`, and `globaldatalab.org` with a GDL token.

## Inputs

In `data/` (`INPUT_DIR`):

| File | Content | Source |
|---|---|---|
| `togo/*.xlsx` | BOOST expenditure exports | the authorities |
| `pefa/pefa_2016_bronze.csv` | PEFA scores, 2016 framework | [pefa.org batch downloads](https://www.pefa.org/assessments/batch-downloads): Togo, 2016 Framework, National, Final, then the CSV linked after DOWNLOAD |
| `pefa/pefa_2011_bronze.csv` | PEFA scores, 2011 framework | same, with 2011 Framework |

`GDL_API_TOKEN` in `.env` enables the Global Data Lab indicators. Without the
token or the PEFA files, those tables stay empty and the other steps run.

`END_YEAR` in `.env` (2025 when unset) is the last year with closed accounts:
charts of executed spending stop there, charts of the budget alone do not.
Raise it once the next year's accounts are closed, then `make up`.

## Offline package

`make package` builds `dist/boost-togo-<date>-<sha>.tar.gz` for
`linux/amd64`: images, compose file, Makefile, `db/`, `deploy/`, `.env`
template, a dump of the indicator tables, and `VERSION` with the upstream
commits.

On the server: `sudo ./prerequisites.sh`, then `./install.sh`, then
`make pipeline`.

## Known limitations

- The spending narrative fixes (rpf-country-dash pull request #50) are not
  included.
- Without the PEFA files, the overview says Togo has no PEFA assessment.

## Licence

[MIT](LICENSE)
