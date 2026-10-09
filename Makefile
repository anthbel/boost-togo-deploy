# Day-to-day operations on the BOOST Togo stack. Run from the directory that
# holds compose.yaml and .env: the installation directory on the server, or
# the repository for development. `make` alone lists the targets.

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE := docker compose
# An installation package has no source to build from: its images are loaded.
IN_REPO := $(wildcard upstream.lock)
NO_BUILD := $(if $(IN_REPO),,--no-build)

BACKUP_DIR ?= /var/backups/boost-togo
KEEP_DAYS ?= 30
SINCE ?= 1h
SERVICE ?=
STEPS ?=
FILE ?=
CONFIRM ?=

.PHONY: help install up down restart status logs follow pipeline refresh-boundaries steps \
        backup restore cache-clear psql fetch build package

help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z][a-z-]*:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "  Variables: SERVICE=db|dashboard  SINCE=24h  STEPS='mega-indicators/gdp.py ...'"
	@echo "             FILE=<dump>  BACKUP_DIR=$(BACKUP_DIR)  KEEP_DAYS=$(KEEP_DAYS)"

install: ## Check, load and start an extracted package (./install.sh)
	@test -x ./install.sh || { echo "install.sh is only in an extracted package"; exit 2; }
	./install.sh

up: ## Start the database and the dashboard, applying .env changes
	$(COMPOSE) up -d --wait $(NO_BUILD)
	@bind=$${DASHBOARD_BIND:-$$(awk -F= '/^DASHBOARD_BIND=/ {print $$2}' .env 2>/dev/null)}; bind=$${bind:-127.0.0.1:8080}; \
	 for i in $$(seq 1 30); do \
	   [ "$$(curl -s -o /dev/null -w '%{http_code}' "http://$$bind/")" = 200 ] && { echo "dashboard ready: http://$$bind/"; exit 0; }; \
	   sleep 2; \
	 done; echo "dashboard not answering on http://$$bind/ after 60 s: make logs SERVICE=dashboard"; exit 1

down: ## Stop the stack; the database volume is kept
	$(COMPOSE) down

restart: ## Restart the dashboard process
	$(COMPOSE) restart dashboard

status: ## Containers and the dashboard's HTTP status
	@$(COMPOSE) ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'
	@bind=$${DASHBOARD_BIND:-$$(awk -F= '/^DASHBOARD_BIND=/ {print $$2}' .env 2>/dev/null)}; bind=$${bind:-127.0.0.1:8080}; \
	 code=$$(curl -s -o /dev/null -w '%{http_code}' "http://$$bind/"); \
	 echo "dashboard http://$$bind/ -> HTTP $$code"; [ "$$code" = 200 ]

logs: ## Logs since SINCE (default 1h), of SERVICE or all services
	$(COMPOSE) logs --since $(SINCE) $(SERVICE)

follow: ## Follow the logs live (Ctrl+C to stop)
	$(COMPOSE) logs -f --tail 50 $(SERVICE)

pipeline: ## Load the data: every step, or STEPS='step1 step2'
	$(COMPOSE) run --rm pipeline $(if $(STEPS),--only $(STEPS))

refresh-boundaries: ## Download the World Bank boundary files again at the next pipeline run
	$(COMPOSE) run --rm --entrypoint sh pipeline -c 'rm -fv "$$DDH_BOUNDARIES_DIR"/*.geojson'

steps: ## List the pipeline steps
	@$(COMPOSE) run --rm -T pipeline --list

backup: ## Dump prd_mega to BACKUP_DIR; dumps older than KEEP_DAYS are deleted
	@mkdir -p "$(BACKUP_DIR)"
	@f="$(BACKUP_DIR)/prd_mega-$$(date +%Y%m%d).dump"; \
	 $(COMPOSE) exec -T db pg_dump -U pipeline -d prd_mega -Fc > "$$f.part" \
	   || { rm -f "$$f.part"; echo "backup failed"; exit 1; }; \
	 mv "$$f.part" "$$f" && ls -lh "$$f"
	@find "$(BACKUP_DIR)" -name 'prd_mega-*.dump' -mtime +$(KEEP_DAYS) -print -delete

restore: ## Replace the database with FILE=<dump> (asks for confirmation)
	@test -n "$(FILE)" || { echo "usage: make restore FILE=$(BACKUP_DIR)/prd_mega-YYYYMMDD.dump"; exit 2; }
	@test -s "$(FILE)" || { echo "$(FILE): missing or empty"; exit 1; }
	@ls -lh "$(FILE)"
	$(COMPOSE) up -d --wait $(NO_BUILD) db
	@echo "server: PostgreSQL $$($(COMPOSE) exec -T db psql -U pipeline -d prd_mega -Atc 'show server_version')"
	@$(COMPOSE) exec -T db pg_restore --list < "$(FILE)" | head -6
	@if [ "$(CONFIRM)" != yes ]; then \
	   read -r -p "Replace the content of prd_mega with $(FILE)? Type yes: " answer; \
	   [ "$$answer" = yes ] || { echo "cancelled"; exit 1; }; \
	 fi
	$(COMPOSE) stop dashboard
	$(COMPOSE) exec -T db pg_restore -U pipeline -d prd_mega --clean --if-exists < "$(FILE)"
	$(COMPOSE) up -d --wait $(NO_BUILD)
	@$(MAKE) --no-print-directory cache-clear

cache-clear: ## Empty the dashboard's query cache (after changing the database by hand)
	@$(COMPOSE) exec -T dashboard python -c "import os, urllib.request; \
	r = urllib.request.Request('http://localhost:8080/api/cache/clear', method='POST', \
	headers={'X-Refresh-Token': os.environ['CACHE_REFRESH_TOKEN']}); \
	print(urllib.request.urlopen(r).read().decode())"

psql: ## Open a SQL session on prd_mega
	$(COMPOSE) exec db psql -U pipeline -d prd_mega

fetch: ## Check out the upstream code pinned in upstream.lock (repository only)
	@test -n "$(IN_REPO)" || { echo "fetch needs the repository (upstream.lock)"; exit 2; }
	scripts/fetch-upstream.sh

build: ## Build the images from the upstream checkouts (repository only)
	@test -n "$(IN_REPO)" || { echo "build needs the repository (upstream.lock)"; exit 2; }
	@test -f upstream/SOURCES || { echo "no upstream checkout: make fetch"; exit 2; }
	$(COMPOSE) --profile pipeline build

package: ## Build the offline installation package (repository only)
	@test -n "$(IN_REPO)" || { echo "package needs the repository (upstream.lock)"; exit 2; }
	scripts/package-release.sh --indicator-snapshot
