#!/usr/bin/env bash
# Installs or updates the BOOST Togo stack on an Ubuntu server straight from
# GitHub: images are built on the server from the upstream code pinned in
# upstream.lock. Run as root:
#
#   sudo ./install-from-git.sh [--dir /opt/boost-togo/boost-togo-deploy]
#        [--ref main] [--workbook FILE.xlsx] [--pefa-dir DIR] [--no-pipeline]
#        [--skip-prerequisites] [--git-ppa] [prerequisites.sh options]
#
# The script can also be downloaded on its own; it clones the repository.
#   1. git 2.38 or later (make fetch uses git merge-tree --write-tree);
#      --git-ppa installs it from ppa:git-core/ppa where Ubuntu's is older
#   2. clone (or update) the repository into --dir
#   3. deploy/prerequisites.sh: Docker, make, Nginx, firewall, account boost
#      (--no-firewall, --ssh-keys-only, --no-swap, --no-nginx are passed on)
#   4. as boost: .env with generated secrets (an existing .env is kept),
#      data/togo and data/pefa, make fetch build up, then make pipeline
#
# GDL_API_TOKEN, if set in the environment, is written into a new .env.
# Needs outbound HTTPS to GitHub, Docker Hub, PyPI and the Ubuntu mirrors;
# make pipeline also reaches the public data sources (guide DevOps, §1.3).
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/anthbel/boost-togo-deploy.git}"
DIR=/opt/boost-togo/boost-togo-deploy
REF=main
WORKBOOK=
PEFA_DIR=
PIPELINE=1
PREREQUISITES=1
GIT_PPA=0
BOOST_USER=boost
PREREQ_ARGS=()

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:?--dir needs a path}"; shift 2 ;;
    --ref) REF="${2:?--ref needs a branch or tag}"; shift 2 ;;
    --workbook) WORKBOOK="${2:?--workbook needs a file}"; shift 2 ;;
    --pefa-dir) PEFA_DIR="${2:?--pefa-dir needs a directory}"; shift 2 ;;
    --no-pipeline) PIPELINE=0; shift ;;
    --skip-prerequisites) PREREQUISITES=0; shift ;;
    --git-ppa) GIT_PPA=1; shift ;;
    --user) BOOST_USER="${2:?--user needs a name}"; PREREQ_ARGS+=(--user "$2"); shift 2 ;;
    --no-firewall|--ssh-keys-only|--no-swap|--no-nginx) PREREQ_ARGS+=("$1"); shift ;;
    -h|--help) usage 0 ;;
    *) echo "option inconnue : $1" >&2; usage 2 ;;
  esac
done

die() { echo "ERREUR : $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
as_boost() { sudo -u "$BOOST_USER" -H "$@"; }

[ "$(id -u)" -eq 0 ] || die "à lancer en root : sudo $0"
[ -z "$WORKBOOK" ] || [ -f "$WORKBOOK" ] || die "classeur introuvable : $WORKBOOK"
[ -z "$PEFA_DIR" ] || [ -d "$PEFA_DIR" ] || die "répertoire PEFA introuvable : $PEFA_DIR"
export DEBIAN_FRONTEND=noninteractive

step "git (2.38 ou plus récent)"
# True when git exists and is at least 2.38.
git_ok() {
  command -v git >/dev/null || return 1
  local v major minor
  v=$(git --version | awk '{print $3}')
  major=${v%%.*}; minor=${v#*.}; minor=${minor%%.*}
  [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 38 ]; }
}
if ! command -v git >/dev/null; then
  apt-get update -q && apt-get install -y -q git
fi
if ! git_ok && [ "$GIT_PPA" = 1 ]; then
  apt-get install -y -q software-properties-common
  add-apt-repository -y ppa:git-core/ppa
  apt-get update -q && apt-get install -y -q git
fi
git_ok || die "$(git --version) : 2.38 ou plus récent est nécessaire (Ubuntu 22.04 fournit 2.34).
Relancer avec --git-ppa (ppa:git-core/ppa), passer à Ubuntu 24.04, ou installer le paquet hors ligne (guide DevOps, §2)."
git --version

step "Dépôt ($REPO_URL, $REF) dans $DIR"
# The clone belongs to the service account; root works on it through safe.directory.
repo_git() { git -c safe.directory="$DIR" -C "$DIR" "$@"; }
if [ -d "$DIR/.git" ]; then
  repo_git fetch -q origin "$REF"
  repo_git checkout -q "$REF"
  repo_git merge -q --ff-only "origin/$REF" || die "$DIR a des modifications locales : mise à jour impossible en avance rapide"
  echo "dépôt mis à jour"
else
  [ ! -e "$DIR" ] || [ -z "$(ls -A "$DIR")" ] || die "$DIR existe et n'est pas vide"
  mkdir -p "$(dirname "$DIR")"
  git clone -q --branch "$REF" "$REPO_URL" "$DIR"
  echo "dépôt cloné"
fi
repo_git log --oneline -1

if [ "$PREREQUISITES" = 1 ]; then
  step "Préparation du serveur (deploy/prerequisites.sh)"
  "$DIR/deploy/prerequisites.sh" "${PREREQ_ARGS[@]}"
fi
id "$BOOST_USER" >/dev/null 2>&1 || die "compte $BOOST_USER absent : lancer sans --skip-prerequisites"
chown -R "$BOOST_USER:$BOOST_USER" "$DIR"
as_boost docker info >/dev/null 2>&1 || die "le compte $BOOST_USER ne peut pas utiliser Docker (groupe docker ? service arrêté ?)"

step "Configuration (.env)"
cd "$DIR"
if [ -f .env ]; then
  echo ".env existe déjà : conservé (les mots de passe de la base ne changent qu'avec la procédure du guide DevOps, §4.6)"
else
  secret() { openssl rand -hex 32; }
  (
    umask 077
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        PIPELINE_DB_PASSWORD=|DASHBOARD_DB_PASSWORD=|CACHE_REFRESH_TOKEN=|SECRET_KEY=) echo "${line}$(secret)" ;;
        GDL_API_TOKEN=) echo "GDL_API_TOKEN=${GDL_API_TOKEN:-}" ;;
        *) echo "$line" ;;
      esac
    done < .env.example > .env
  )
  chown "$BOOST_USER:$BOOST_USER" .env
  chmod 600 .env
  echo ".env créé avec des secrets générés ; à copier avec les sauvegardes"
fi

step "Répertoires d'entrée"
as_boost mkdir -p data/togo data/pefa
[ -z "$WORKBOOK" ] || install -o "$BOOST_USER" -g "$BOOST_USER" -m 0640 "$WORKBOOK" data/togo/
if [ -n "$PEFA_DIR" ]; then
  for f in pefa_2011_bronze.csv pefa_2016_bronze.csv; do
    [ -f "$PEFA_DIR/$f" ] && install -o "$BOOST_USER" -g "$BOOST_USER" -m 0640 "$PEFA_DIR/$f" data/pefa/
  done
fi
ls data/togo/*.xlsx >/dev/null 2>&1 || echo "ATTENTION : aucun classeur .xlsx dans data/togo : les étapes BOOST échoueront (guide DevOps, §6)"
ls data/pefa/*.csv >/dev/null 2>&1 || echo "ATTENTION : aucun fichier PEFA dans data/pefa : l'étape PEFA échouera (guide DevOps, §2.7)"

step "Code fixé, images et démarrage (make fetch build up)"
as_boost make fetch build up

if [ "$PIPELINE" = 1 ]; then
  step "Chargement des données (make pipeline)"
  as_boost make pipeline || echo "ATTENTION : des étapes ont échoué ; relancer celles du résumé (guide DevOps, §5.3)"
fi

bind=$(awk -F= '/^DASHBOARD_BIND=/ {print $2}' .env)
step "Terminé"
echo "Répertoire : $DIR (compte $BOOST_USER : sudo -iu $BOOST_USER, puis cd $DIR)"
echo "Tableau de bord : http://${bind:-127.0.0.1:8080}/ (sur le serveur ; publication HTTPS : guide DevOps, §2.8)"
[ "$PIPELINE" = 1 ] || echo "Chargement des données : sudo -iu $BOOST_USER sh -c 'cd $DIR && make pipeline'"
