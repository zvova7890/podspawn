#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

export VAR_LIB_DIR="$test_root/var/lib/podspawn"
work_dir="$test_root/work"

mkdir -p \
    "$VAR_LIB_DIR/alpha/rootfs/etc" \
    "$VAR_LIB_DIR/alpha/rootfs/usr/bin" \
    "$VAR_LIB_DIR/beta/rootfs/var/log" \
    "$VAR_LIB_DIR/ignored/rootfs" \
    "$work_dir/layout-dir"
touch \
    "$VAR_LIB_DIR/alpha/config" \
    "$VAR_LIB_DIR/alpha/rootfs/etc/hosts" \
    "$VAR_LIB_DIR/beta/config" \
    "$work_dir/source.txt" \
    "$work_dir/source with spaces.txt"

# shellcheck source=../completions/podspawn
source "$repo_root/completions/podspawn"

# Completion functions normally run inside Readline. These test doubles make
# that context deterministic without requiring bash-completion to be installed.
compopt()
{
    return 0
}

_init_completion()
{
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD
    cur=${words[cword]}
    prev=${words[cword-1]:-}
}

assertions=0

fail()
{
    printf 'not ok - %s\n' "$1" >&2
    printf '  replies: %s\n' "${COMPREPLY[*]:-<none>}" >&2
    exit 1
}

assert_reply()
{
    local expected=$1
    local description=$2
    local reply

    ((assertions += 1))
    for reply in "${COMPREPLY[@]}"; do
        [[ $reply == "$expected" ]] && return
    done
    fail "$description (expected '$expected')"
}

assert_no_reply()
{
    local unexpected=$1
    local description=$2
    local reply

    ((assertions += 1))
    for reply in "${COMPREPLY[@]}"; do
        [[ $reply != "$unexpected" ]] ||
            fail "$description (unexpected '$unexpected')"
    done
}

assert_reply_count()
{
    local expected=$1
    local description=$2

    ((assertions += 1))
    [[ ${#COMPREPLY[@]} -eq $expected ]] ||
        fail "$description (expected $expected replies, got ${#COMPREPLY[@]})"
}

run_completion()
{
    COMP_WORDS=("$@")
    COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
    COMP_LINE=${COMP_WORDS[*]}
    COMP_POINT=${#COMP_LINE}
    _podspawn
}

cd "$work_dir"

run_completion podspawn sh
assert_reply shell 'completes top-level commands'

run_completion podspawn --quiet sh
assert_reply shell 'finds the command after a global option'

run_completion podspawn shell al
assert_reply alpha 'completes managed containers for shell'
assert_no_reply ignored 'ignores directories without a container config'

run_completion podspawn info b
assert_reply beta 'completes managed containers for info'

run_completion podspawn exec alpha --work
assert_reply --workdir 'completes exec options'

run_completion podspawn exec alpha --hostname ''
assert_reply_count 0 'does not complete option values as options'

run_completion podspawn cp sou
assert_reply source.txt 'completes local copy sources'
assert_reply 'source with spaces.txt' 'preserves spaces in local filenames'

run_completion podspawn cp source.txt al
assert_reply alpha: 'completes a container copy destination'

run_completion podspawn cp alpha:/etc sou
assert_reply source.txt 'completes a local destination for container copies'

run_completion podspawn cp source.txt alpha:/et
assert_reply /etc/ 'completes paths inside a container rootfs'

run_completion podspawn exec alpha --workdir /usr/b
assert_reply /usr/bin/ 'completes workdirs inside a container rootfs'

run_completion podspawn init oci:lay
assert_reply layout-dir 'completes filesystem paths after an image transport'

complete -p podspawn >/dev/null || fail 'registers completion for podspawn'
((assertions += 1))
complete -p podspawn.sh >/dev/null || fail 'registers completion for podspawn.sh'
((assertions += 1))

printf 'ok - %d completion assertions passed\n' "$assertions"
