#!/usr/bin/env bash
# Build and publish carpentry.dev.
#
#   ./deploy.sh check              validate the manifest against GitHub
#   ./deploy.sh build [route...]   generate the whole site into ./site
#   ./deploy.sh deploy [route...]  build, then rsync to the server
#
# Every hosted library is rebuilt from its latest tag, so the site converges on
# a known state instead of accumulating whatever was last copied up by hand.
# A library that fails to build is reported and skipped; its live docs are left
# alone. The run exits nonzero if anything failed.

set -euo pipefail
shopt -s nullglob

cd "$(dirname "$0")"

MANIFEST=${MANIFEST:-libs.tsv}
SITE=${SITE:-site}
# Path prefix rsync writes to. With a forced rrsync command on the server this
# is just "user@host:/", since rrsync resolves paths inside its own root.
DEST=${DEST:-carpentry-docs@veitheller.de:/var/www/html/carpentry/}
RSYNC_OPTS=${RSYNC_OPTS:-}

failed=()
built=()
tmp=

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Network flakes should not silently drop a library from the deploy.
retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    [ "$n" -ge 3 ] && return 1
    sleep $((n * 3))
  done
}
note() { printf '  %s\n' "$*"; }

# name repo route category blurb, tab separated, # for comments
manifest_rows() { grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$'; }

# A route is either a path we publish, "-" for a package we only link to, or a
# full URL for docs someone else hosts. Only the first kind gets built.
we_publish() {
  case "$1" in
    - | http://* | https://*) return 1 ;;
    *) return 0 ;;
  esac
}

hosted_rows() { manifest_rows | awk -F'\t' '$3 != "-" && $3 !~ /^https?:/'; }

latest_tag() {
  retry gh api "repos/$1/tags" --jq '.[0].name' 2>/dev/null
}

# Find a generated page by name, ignoring case, comparing in the shell rather
# than on the filesystem: macOS is case insensitive and would match CLI.html
# for cli.html, which Linux will not.
find_page() {
  local docs=$1 want base f
  want=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  for f in "$docs"/*.html; do
    base=$(basename "$f")
    [ "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" = "$want" ] || continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

doc_title() {
  sed -n 's/.*(Project.config "title" "\([^"]*\)").*/\1/p' "$1/gendocs.carp" | head -n 1
}

# The modules a library says it documents. Every one of them must produce a
# page, which is the only real check we have: a load that fails part way still
# exits 0, so the exit status says nothing.
doc_modules() {
  sed -n 's/.*(save-docs \([^)]*\)).*/\1/p' "$1/gendocs.carp" | head -n 1
}

# The landing page has a different name per library: multi-module libraries get
# <Title>_index.html, a library that turns the index off gets its top level
# module page, and the title is whatever gendocs.carp sets, which need not
# match either the repo name or the module casing. nginx wants index.html.
normalize_landing_page() {
  local docs=$1 title=$2 page f base candidates=()
  [ -f "$docs/index.html" ] && return 0

  if [ -n "$title" ]; then
    page=$(find_page "$docs" "${title}_index.html") || page=$(find_page "$docs" "${title}.html") || page=
    if [ -n "$page" ]; then
      cp "$page" "$docs/index.html"
      return 0
    fi
  fi

  # Several modules and no index: the landing page is the top level module,
  # the only page whose name has no dotted parent.
  for f in "$docs"/*.html; do
    base=$(basename "$f" .html)
    case "$base" in
      *.*) ;;
      *) candidates+=("$f") ;;
    esac
  done
  if [ ${#candidates[@]} -eq 1 ]; then
    cp "${candidates[0]}" "$docs/index.html"
    return 0
  fi

  candidates=("$docs"/*_index.html)
  if [ ${#candidates[@]} -eq 1 ]; then
    cp "${candidates[0]}" "$docs/index.html"
    return 0
  fi

  return 1
}

# A retried clone must start from a clean directory or git refuses the second
# attempt because the destination is not empty.
clone_at_tag() {
  local repo=$1 tag=$2 work=$3
  rm -rf "$work"
  git clone --quiet --depth 1 --branch "$tag" "https://github.com/$repo" "$work"
}

build_lib() {
  local repo=$1 route=$2 work=$3 tag docs

  tag=$(latest_tag "$repo") || true
  if [ -z "${tag:-}" ] || [ "$tag" = "null" ]; then
    note "no tags on $repo"
    return 1
  fi
  note "$repo @ $tag"

  if ! retry clone_at_tag "$repo" "$tag" "$work" 2>"$work.clone.log"; then
    note "clone failed: $(tail -n 1 "$work.clone.log")"
    return 1
  fi

  # Drop any committed docs/ so what we publish is purely what gendocs emits.
  rm -rf "$work/docs"

  [ -f "$work/gendocs.carp" ] || { note "no gendocs.carp"; return 1; }
  # Loading runs save-docs; -x would additionally compile the library, which
  # doc generation does not need and which drags in every C dependency.
  (cd "$work" && carp gendocs.carp </dev/null) >"$work/.gendocs.log" 2>&1 || true

  docs=$work/docs
  [ -d "$docs" ] || { note "gendocs wrote no docs/"; return 1; }

  local missing= m
  for m in $(doc_modules "$work"); do
    find_page "$docs" "$m.html" >/dev/null || missing="$missing $m"
  done
  if [ -n "$missing" ]; then
    note "no page generated for:$missing"
    sed 's/^/    /' <(tail -n 3 "$work/.gendocs.log")
    return 1
  fi
  normalize_landing_page "$docs" "$(doc_title "$work")" || {
    note "cannot pick a landing page from: $(cd "$docs" && echo *.html)"
    return 1
  }

  printf '%s\n' "$tag" >"$docs/VERSION"

  mkdir -p "$SITE/$route"
  rsync -a --delete "$docs/" "$SITE/$route/"

  # save-docs emits no stylesheet, and libraries disagree about where theirs
  # lives: most point at ../style.css, fourteen at a bare style.css next to the
  # page. Giving every route its own copy satisfies both, and stops the bare
  # ones from rendering with whatever stale stylesheet was copied up years ago.
  cp style.css "$SITE/$route/style.css"
}

cmd_build() {
  command -v carp >/dev/null || die "carp not on PATH"
  command -v gh >/dev/null || die "gh not on PATH"

  local only=("$@")
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  # A route filter that matches nothing is a typo, not an empty deploy. Guard
  # the expansion: bash 3.2 treats an empty array as unset under set -u.
  if [ ${#only[@]} -gt 0 ]; then
    for r in "${only[@]}"; do
      hosted_rows | awk -F'\t' -v r="$r" '$3 == r {found = 1} END {exit !found}' \
        || die "no such route in $MANIFEST: $r"
    done
  fi

  mkdir -p "$SITE"
  cp index.html style.css "$SITE/"

  while IFS=$'\t' read -r name repo route _category _blurb; do
    if [ ${#only[@]} -gt 0 ]; then
      local match=no
      for r in "${only[@]}"; do [ "$r" = "$route" ] && match=yes; done
      [ "$match" = yes ] || continue
    fi
    printf '%s\n' "$name"
    if build_lib "$repo" "$route" "$tmp/$route"; then
      built+=("$route")
    else
      failed+=("$route")
    fi
    rm -rf "$tmp/$route"
  done < <(hosted_rows)

  printf '\nbuilt %d route(s) into %s/\n' "${#built[@]}" "$SITE"
  if [ ${#failed[@]} -gt 0 ]; then
    printf 'failed: %s\n' "${failed[*]}"
    return 1
  fi
}

cmd_deploy() {
  local status=0

  # macOS ships openrsync, which sends a --server option set that the rrsync
  # forced command on the server rejects. CI runs GNU rsync, so this only bites
  # when deploying by hand from a Mac.
  if rsync --version 2>&1 | head -n 1 | grep -qi openrsync; then
    die "openrsync cannot talk to the rrsync forced command; install GNU rsync or deploy from CI"
  fi

  cmd_build "$@" || status=$?

  if [ ${#built[@]} -eq 0 ]; then
    die "nothing built, refusing to deploy"
  fi

  # Per-route --delete so a route is replaced wholesale, but a route that
  # failed to build above is never touched. Root files sync without --delete
  # so nothing can wipe sibling routes.
  for route in "${built[@]}"; do
    rsync -a --delete $RSYNC_OPTS "$SITE/$route/" "$DEST$route/"
  done
  rsync -a $RSYNC_OPTS "$SITE/index.html" "$SITE/style.css" "$DEST"

  printf 'deployed %d route(s) to %s\n' "${#built[@]}" "$DEST"
  return $status
}

cmd_check() {
  command -v gh >/dev/null || die "gh not on PATH"
  local problems=0
  while IFS=$'\t' read -r name repo route _category _blurb; do
    local full
    full=$(gh api "repos/$repo" --jq .full_name 2>/dev/null) || {
      printf '%-14s missing repo %s\n' "$name" "$repo"
      problems=$((problems + 1))
      continue
    }
    if [ "$full" != "$repo" ]; then
      printf '%-14s %s redirects to %s\n' "$name" "$repo" "$full"
      problems=$((problems + 1))
    fi
    if we_publish "$route"; then
      local tag
      tag=$(latest_tag "$repo")
      if [ -z "$tag" ] || [ "$tag" = "null" ]; then
        printf '%-14s no tags, cannot publish /%s\n' "$name" "$route"
        problems=$((problems + 1))
      fi
    fi
  done < <(manifest_rows)
  printf '%d problem(s)\n' "$problems"
  [ "$problems" -eq 0 ]
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  deploy) shift; cmd_deploy "$@" ;;
  check) shift; cmd_check "$@" ;;
  *) die "usage: $0 {check|build|deploy} [route...]" ;;
esac
