#!/usr/bin/env bash
# Checks out the upstream code pinned in upstream.lock under upstream/:
#   upstream/rpf-country-dash   the dashboard (merge of DASHBOARD_COMMITS)
#   upstream/mega-indicators    the indicator ETL, only INDICATORS_PATHS
#   upstream/mega-boost         the Togo BOOST ETL, only BOOST_PATHS
# Every checkout is recreated from scratch; the script fails if a pinned
# commit cannot be fetched or the dashboard merge gives another tree.
# Needs git 2.38 or later (git merge-tree --write-tree).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../upstream.lock
. "$ROOT/upstream.lock"
OUT="$ROOT/upstream"
mkdir -p "$OUT"

die() { echo "fetch-upstream: $*" >&2; exit 1; }

# Says when the upstream ref has moved on; the pinned commit is still used.
ref_note() {
  local url=$1 ref=$2 pinned=$3 current
  current="$(git ls-remote "$url" "$ref" | cut -f1)"
  if [ -z "$current" ]; then
    echo "   note: $ref no longer exists upstream"
  elif [ "$current" != "$pinned" ]; then
    echo "   note: $ref is now at ${current:0:7}; upstream.lock pins ${pinned:0:7}"
  fi
}

new_repo() {
  local dir=$1 url=$2
  rm -rf "$dir"
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
}

sparse_checkout() {
  local name=$1 url=$2 ref=$3 commit=$4 paths=$5 dir="$OUT/$1"
  echo "== $name ${commit:0:7} ($ref), folders: $paths"
  new_repo "$dir" "$url"
  git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$commit" \
    || die "$name: commit $commit cannot be fetched from $url"
  # shellcheck disable=SC2086
  git -C "$dir" sparse-checkout set --cone $paths
  git -C "$dir" -c advice.detachedHead=false checkout -q --detach "$commit"
  ref_note "$url" "$ref" "$commit"
}

dashboard_checkout() {
  local dir="$OUT/rpf-country-dash" commits refs tree c
  read -r -a commits <<<"$DASHBOARD_COMMITS"
  read -r -a refs <<<"$DASHBOARD_REFS"
  [ "${#commits[@]}" = "${#refs[@]}" ] || die "DASHBOARD_REFS and DASHBOARD_COMMITS differ in length"
  echo "== rpf-country-dash ${DASHBOARD_COMMITS// /+}"
  new_repo "$dir" "$DASHBOARD_URL"
  # Full history without file contents: the merge needs the common ancestor.
  git -C "$dir" fetch -q --filter=blob:none origin "${commits[@]}" \
    || die "rpf-country-dash: $DASHBOARD_COMMITS cannot be fetched from $DASHBOARD_URL"
  if [ "${#commits[@]}" = 1 ]; then
    tree="$(git -C "$dir" rev-parse "${commits[0]}^{tree}")"
  else
    tree="$(git -C "$dir" merge-tree --write-tree "${commits[@]}")" \
      || die "rpf-country-dash: the pinned commits do not merge cleanly"
  fi
  [ "$tree" = "$DASHBOARD_TREE" ] \
    || die "rpf-country-dash: tree $tree, upstream.lock expects $DASHBOARD_TREE"
  git -C "$dir" read-tree --reset -u "$tree"
  for c in "${!commits[@]}"; do ref_note "$DASHBOARD_URL" "${refs[$c]}" "${commits[$c]}"; done
}

dashboard_checkout
sparse_checkout mega-indicators "$INDICATORS_URL" "$INDICATORS_REF" "$INDICATORS_COMMIT" "$INDICATORS_PATHS"
sparse_checkout mega-boost "$BOOST_URL" "$BOOST_REF" "$BOOST_COMMIT" "$BOOST_PATHS"

cat > "$OUT/SOURCES" <<EOF
rpf-country-dash: $DASHBOARD_URL
  commits:        $DASHBOARD_COMMITS ($DASHBOARD_REFS)
  tree:           $DASHBOARD_TREE
mega-indicators:  $INDICATORS_URL $INDICATORS_COMMIT ($INDICATORS_REF)
  folders:        $INDICATORS_PATHS
mega-boost:       $BOOST_URL $BOOST_COMMIT ($BOOST_REF)
  folders:        $BOOST_PATHS
EOF
echo "== upstream/ ready"
