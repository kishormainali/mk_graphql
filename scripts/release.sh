#!/usr/bin/env bash
#
# Tag (and optionally push) a release for one or both packages in this
# monorepo. Version numbers are read from each package's own pubspec.yaml —
# bump that (and its CHANGELOG.md) first, commit, then run this script.
#
# Usage:
#   scripts/release.sh <mk_graphql|mk_graphql_generator|all> [--push] [--remote <name>]
#
# Examples:
#   scripts/release.sh mk_graphql              # create the tag locally only
#   scripts/release.sh all --push              # tag both packages and push
#   scripts/release.sh mk_graphql_generator --push --remote upstream
#
# Pushing a tag matching mk_graphql-vX.Y.Z / mk_graphql_generator-vX.Y.Z
# triggers that package's publish workflow (.github/workflows/publish-*.yml),
# which publishes to pub.dev via trusted OIDC publishing. There is no undo
# for a publish, so this script always prints exactly what it's about to do
# and asks for confirmation before creating a tag, and again before pushing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REMOTE="origin"
PUSH=false
TARGET=""

usage() {
  local exit_code="${1:-1}"
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit "$exit_code"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    mk_graphql|mk_graphql_generator|all)
      TARGET="$1"
      shift
      ;;
    --push)
      PUSH=true
      shift
      ;;
    --remote)
      REMOTE="${2:?--remote requires a value}"
      shift 2
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  usage
fi

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  echo "error: working tree has uncommitted changes. Commit or stash before releasing." >&2
  git -C "$REPO_ROOT" status --short >&2
  exit 1
fi

package_version() {
  local pkg_dir="$1"
  # First "version: X.Y.Z" line in the package's pubspec.yaml.
  awk -F': *' '/^version:/ { print $2; exit }' "$REPO_ROOT/packages/$pkg_dir/pubspec.yaml"
}

confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

tag_package() {
  local pkg="$1"
  local version
  version="$(package_version "$pkg")"
  if [[ -z "$version" ]]; then
    echo "error: could not read version from packages/$pkg/pubspec.yaml" >&2
    exit 1
  fi

  local tag="${pkg}-v${version}"

  if git -C "$REPO_ROOT" rev-parse "$tag" >/dev/null 2>&1; then
    echo "Tag $tag already exists — skipping (bump the version to release again)."
    return
  fi

  echo
  echo "About to tag HEAD ($(git -C "$REPO_ROOT" rev-parse --short HEAD)) as $tag for packages/$pkg."
  if ! confirm "Create this tag locally?"; then
    echo "Skipped $tag."
    return
  fi

  git -C "$REPO_ROOT" tag -a "$tag" -m "$pkg $version"
  echo "Created tag $tag."

  if [[ "$PUSH" == true ]]; then
    echo
    echo "About to push $tag to $REMOTE — this triggers the pub.dev publish workflow for $pkg. This cannot be undone once pub.dev accepts the publish."
    if confirm "Push $tag to $REMOTE now?"; then
      git -C "$REPO_ROOT" push "$REMOTE" "$tag"
      echo "Pushed $tag."
    else
      echo "Not pushed. Push it yourself later with: git push $REMOTE $tag"
    fi
  else
    echo "Not pushed (pass --push to push after confirmation). Push it yourself later with: git push $REMOTE $tag"
  fi
}

case "$TARGET" in
  mk_graphql)
    tag_package mk_graphql
    ;;
  mk_graphql_generator)
    tag_package mk_graphql_generator
    ;;
  all)
    tag_package mk_graphql
    tag_package mk_graphql_generator
    ;;
esac
