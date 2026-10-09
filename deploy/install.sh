#!/usr/bin/env bash
# Installs or updates the BOOST Togo stack from an extracted release package.
# Run from the package directory:   ./install.sh
#
# Verifies the image archives, loads them, creates .env with generated
# secrets if it does not exist (an existing .env is kept), creates the input
# folders and starts the database and the dashboard. Data loading is a
# separate step: make first-load on a new database, then make pipeline
set -euo pipefail

cd "$(dirname "$0")"

die() { echo "ERREUR : $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

step "Vérification des prérequis"
command -v docker >/dev/null || die "docker introuvable (voir docs/02-installation.md §2.2)"
docker compose version >/dev/null 2>&1 || die "le plugin docker compose est absent"
docker info >/dev/null 2>&1 || die "le démon Docker ne répond pas (droits de l'utilisateur ? service arrêté ?)"
[ -f VERSION ] && [ -f compose.yaml ] || die "à lancer depuis le répertoire extrait du paquet"
platform=$(awk '/^platform:/ {print $2}' VERSION)
case "$(uname -m)/$platform" in
  x86_64/linux/amd64|aarch64/linux/arm64|arm64/linux/arm64) ;;
  *) die "paquet construit pour $platform, serveur $(uname -m)" ;;
esac
echo "paquet $(awk '/^release:/ {print $2}' VERSION) pour $platform"

step "Contrôle des fichiers du paquet"
if command -v sha256sum >/dev/null; then sha256sum -c SHA256SUMS; else shasum -a 256 -c SHA256SUMS; fi

step "Chargement des images"
for archive in images/*.tar.gz; do
  docker load -i "$archive"
done

step "Configuration (.env)"
secret() {
  if command -v openssl >/dev/null; then openssl rand -hex 32
  else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}
release=$(awk '/^release:/ {print $2}' VERSION)
if [ -f .env ]; then
  echo ".env existe déjà : conservé (les mots de passe de la base ne changent qu'avec docs/04-maintenance.md §4.6)"
  # A .env carried over from a previous install still names its release.
  tmp=$(mktemp)
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in RELEASE=*) echo "RELEASE=$release" ;; *) echo "$line" ;; esac
  done < .env > "$tmp"
  cat "$tmp" > .env && rm -f "$tmp"
  echo "RELEASE=$release"
else
  umask 077
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      PIPELINE_DB_PASSWORD=|DASHBOARD_DB_PASSWORD=|CACHE_REFRESH_TOKEN=|SECRET_KEY=)
        echo "${line}$(secret)" ;;
      *) echo "$line" ;;
    esac
  done < .env.example > .env
  chmod 600 .env
  echo ".env créé avec des secrets générés ; à copier avec les sauvegardes"
fi

step "Répertoires d'entrée"
mkdir -p data/togo data/pefa
echo "data/togo : exports BOOST (.xlsx) ; data/pefa : pefa_2011_bronze.csv et pefa_2016_bronze.csv (pefa.org)"

step "Démarrage"
docker compose up -d --wait --no-build
docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'

bind=$(awk -F= '/^DASHBOARD_BIND=/ {print $2}' .env)
bind=${bind:-127.0.0.1:8080}
step "Terminé"
echo "Tableau de bord : http://${bind}/ (sur le serveur ; publication HTTPS : docs/02-installation.md §2.8)"
echo "Premier chargement des données : make first-load (docs/02-installation.md §2.7)"
