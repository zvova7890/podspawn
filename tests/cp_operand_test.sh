#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../podspawn.sh
source "$repo_root/podspawn.sh"

assertions=0

assert_operand()
{
    local operand=$1
    local expected_container=$2
    local expected_path=$3
    local actual_container actual_path

    ((assertions += 1))
    if ! parse_cp_operand "$operand" actual_container actual_path; then
        printf 'not ok - failed to parse %s\n' "$operand" >&2
        exit 1
    fi
    if [[ $actual_container != "$expected_container" ||
          $actual_path != "$expected_path" ]]; then
        printf 'not ok - %s: expected %s and %s, got %s and %s\n' \
            "$operand" "$expected_container" "$expected_path" \
            "$actual_container" "$actual_path" >&2
        exit 1
    fi
}

assert_operand 'alpine:/etc/os-release' \
    'alpine' '/etc/os-release'
assert_operand 'alpine:3.20:/etc/os-release' \
    'alpine:3.20' '/etc/os-release'
assert_operand 'docker://docker.io/library/alpine:3.20:/etc/os-release' \
    'docker://docker.io/library/alpine:3.20' '/etc/os-release'
assert_operand 'docker://localhost:5000/team/image:latest:/var/log/app.log' \
    'docker://localhost:5000/team/image:latest' '/var/log/app.log'
assert_operand 'oci:/tmp/image-layout:v1:/usr/bin/tool' \
    'oci:/tmp/image-layout:v1' '/usr/bin/tool'

unused_container= unused_path=
if parse_cp_operand 'local-file' unused_container unused_path; then
    printf 'not ok - parsed a host path as a container operand\n' >&2
    exit 1
fi
((assertions += 1))

# Verify that cmd_cp passes the complete URI to container resolution.
resolved_container=
declare -a podman_args=()
PODSPAWN_QUIET=1
require_root() { :; }
resolve_container()
{
    resolved_container=$1
    CONTAINER_NAME=managed-container
}
podman() { podman_args=("$@"); }

cmd_cp '/host/source.txt' \
    'docker://localhost:5000/team/image:latest:/tmp/'
if [[ $resolved_container != 'docker://localhost:5000/team/image:latest' ||
      ${podman_args[*]} != 'cp /host/source.txt managed-container:/tmp/' ]]; then
    printf 'not ok - cmd_cp did not preserve the complete container URI\n' >&2
    exit 1
fi
((assertions += 1))

printf 'ok - %d cp operand assertions passed\n' "$assertions"
