#!/usr/bin/env bash
# Builds an offline installation archive: the three Docker images, the
# compose file, Makefile, database initialisation, .env template, server
# preparation script and field docs.
#
#   scripts/package-release.sh [--platform linux/amd64] [--indicator-snapshot]
#
# The upstream code is checked out again from upstream.lock before the build.
# --indicator-snapshot adds a pg_dump of the indicator schema taken from the
# running local stack, for servers without outbound internet access.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="linux/amd64"
SNAPSHOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="$2"; shift 2 ;;
    --indicator-snapshot) SNAPSHOT=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$ROOT"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "uncommitted changes; commit them first" >&2
  exit 1
fi
if [ -z "$(git branch -r --contains HEAD)" ]; then
  echo "HEAD is on no remote branch; push it first" >&2
  exit 1
fi
DEPLOY_SHA="$(git rev-parse --short HEAD)"
RELEASE="$(date +%Y%m%d)-${DEPLOY_SHA}"

scripts/fetch-upstream.sh

NAME="boost-togo-${RELEASE}"
OUT="$ROOT/dist/$NAME"
rm -rf "$OUT"
mkdir -p "$OUT/data/togo" "$OUT/data/pefa" "$OUT/snapshots" "$OUT/images"

echo "== building images for $PLATFORM (release $RELEASE)"
export RELEASE DOCKER_DEFAULT_PLATFORM="$PLATFORM"
docker compose --profile pipeline build

for image in "boost-togo/dashboard:$RELEASE" "boost-togo/pipeline:$RELEASE" "boost-togo/postgres:$RELEASE"; do
  file="$OUT/images/$(echo "${image%%:*}" | tr '/' '-').tar.gz"
  echo "== saving $image -> images/$(basename "$file")"
  docker save "$image" | gzip > "$file"
done

cp compose.yaml Makefile LICENSE "$OUT/"
cp -R db deploy "$OUT/"
cp deploy/install.sh deploy/prerequisites.sh "$OUT/"
sed "s/^RELEASE=.*/RELEASE=$RELEASE/" .env.example > "$OUT/.env.example"
if [ -d docs/terrain ]; then cp -R docs/terrain "$OUT/docs"; fi

if [ "$SNAPSHOT" = 1 ]; then
  echo "== indicator snapshot from the running stack"
  docker compose exec -T db pg_dump -U pipeline -d prd_mega -n indicator -Fc \
    > "$OUT/snapshots/indicator-$(date +%Y%m%d).dump"
fi

(cd "$OUT" && find images snapshots -type f | sort | xargs shasum -a 256 > SHA256SUMS)

POSTGRES_FROM="$(awk '/^FROM / {print $2}' docker/postgres.Dockerfile)"
POSTGRES_ID="$(docker image inspect "boost-togo/postgres:$RELEASE" --format '{{.Id}}')"
cat > "$OUT/VERSION" <<EOF
release:          $RELEASE
platform:         $PLATFORM
boost-togo-deploy: $DEPLOY_SHA
$(cat upstream/SOURCES)
postgres:         $POSTGRES_FROM
postgres image:   $POSTGRES_ID
built:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# No macOS extended attributes or AppleDouble (._*) entries in the archive.
TAR_OPTS=()
if tar --version 2>/dev/null | grep -q bsdtar; then TAR_OPTS=(--no-xattrs --no-mac-metadata); fi
(cd "$ROOT/dist" && COPYFILE_DISABLE=1 tar "${TAR_OPTS[@]}" -czf "$NAME.tar.gz" "$NAME" \
  && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
rm -rf "$OUT"
echo "== $ROOT/dist/$NAME.tar.gz"
cat "$ROOT/dist/$NAME.tar.gz.sha256"
