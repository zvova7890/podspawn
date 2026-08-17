#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../podspawn.sh
source "$repo_root/podspawn.sh"

PODSPAWN_QUIET=1
assertions=0

assert_name()
{
    local image_ref=$1
    local expected=$2

    setup_layout "$image_ref"
    ((assertions += 1))
    if [[ $CONTAINER_NAME != "$expected" ]]; then
        printf 'not ok - %s: expected %s, got %s\n' \
            "$image_ref" "$expected" "$CONTAINER_NAME" >&2
        exit 1
    fi
}

# Equivalent Docker Hub references have the same local identity.
assert_name 'example/image' 'example_image'
assert_name 'docker.io/example/image' 'example_image'
assert_name 'docker://docker.io/example/image' 'example_image'

# Any explicit Docker registry is a source location, not part of the identity.
assert_name 'quay.io/example/image' 'example_image'
assert_name 'registry.example.com:5000/example/image' 'example_image'
assert_name 'localhost:5000/example/image' 'example_image'
assert_name 'containers-storage:registry.example.com/example/image:latest' 'example_image'
assert_name 'docker-daemon:registry.example.com/example/image:latest' 'example_image'

# A first component that does not look like a registry is a namespace.
assert_name 'team/project/image:latest' 'team_project_image'

# Official Docker Hub images retain their real "library" namespace.
assert_name 'alpine:3.20' 'library_alpine'

# Filesystem-based transports must not be interpreted as Docker registries.
assert_name 'oci:/tmp/example/layout:v1' 'oci__tmp_example_layout'

printf 'ok - %d container-name assertions passed\n' "$assertions"
