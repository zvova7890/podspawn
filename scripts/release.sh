#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release.sh <version> [release message]

Update all project versions, create a release commit, and tag it.
The version may be written as 1.2.3 or v1.2.3.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || {
  usage >&2
  exit 2
}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
  die "This command must be run inside a Git repository"
cd "$repo_root"

version=${1#v}
tag="v$version"
release_message=${2:-"Release $version"}

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "Version must use the X.Y.Z format"
git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null &&
  die "Tag $tag already exists"

current_script_version=$(
  sed -n 's/^VERSION="\([^"]*\)"$/\1/p' podspawn.sh
)
current_package_version=$(
  sed -n '1s/^podspawn (\([^)]*\)).*/\1/p' debian/changelog
)
current_package_upstream=${current_package_version%-*}

[[ -n $current_script_version ]] ||
  die "Could not find VERSION in podspawn.sh"
[[ -n $current_package_version ]] ||
  die "Could not read the version from debian/changelog"
[[ $version != "$current_script_version" || $version != "$current_package_upstream" ]] ||
  die "Project is already at version $version"

maintainer_name=${DEBFULLNAME:-$(git config user.name || true)}
maintainer_email=${DEBEMAIL:-$(git config user.email || true)}
[[ -n $maintainer_name ]] ||
  die "Set Git user.name or DEBFULLNAME before creating a release"
[[ -n $maintainer_email ]] ||
  die "Set Git user.email or DEBEMAIL before creating a release"

sed -i \
  "s/^VERSION=\"${current_script_version}\"$/VERSION=\"${version}\"/" \
  podspawn.sh

changelog_entry=$(mktemp)
trap 'rm -f "$changelog_entry"' EXIT
{
  printf 'podspawn (%s-1) unstable; urgency=medium\n\n' "$version"
  printf '  * %s\n\n' "$release_message"
  printf ' -- %s <%s>  %s\n\n' \
    "$maintainer_name" "$maintainer_email" "$(date -R)"
  cat debian/changelog
} >"$changelog_entry"
mv "$changelog_entry" debian/changelog
trap - EXIT

updated_script_version=$(
  sed -n 's/^VERSION="\([^"]*\)"$/\1/p' podspawn.sh
)
updated_package_version=$(
  sed -n '1s/^podspawn (\([^)]*\)).*/\1/p' debian/changelog
)
[[ $updated_script_version == "$version" ]] ||
  die "Failed to update podspawn.sh"
[[ $updated_package_version == "$version-1" ]] ||
  die "Failed to update debian/changelog"

git add podspawn.sh debian/changelog
git commit -m "Release $version"
git tag -a "$tag" -m "$release_message"

printf 'Created release commit and tag %s\n' "$tag"
printf 'Push with: git push origin HEAD %s\n' "$tag"
