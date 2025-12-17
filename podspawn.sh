#!/usr/bin/env bash
set -euo pipefail

# podspawn: Run Podman images with systemd-nspawn
#
# Requirements:
#   - podman (to pull/create/mount OCI images)
#   - systemd-nspawn (to run rootfs with extra flexibility)
#
# Why:
#   Podman, Docker, and other OCI runtimes follow the OCI model:
#     * A container is not just a chroot, but a stateful object with lifecycle.
#     * By default, mounts, user settings, and runtime options must be declared
#       when the container is created, not at the time you run a command.
#
#   For cross-compilation and development it's often more convenient to treat an
#   OCI image like a mutable chroot (similar to "mock" or "systemd-nspawn -D").
#   This script provides that bridge:
#
#     1. Pull and create a Podman container from an OCI image.
#        - The container is mutable and will retain changes until explicitly
#          re-created.
#
#     2. Mount its merged rootfs into a host directory that a regular user can
#        access, e.g. under /var/lib/podspawn/<container>/rootfs.
#
#     3. Launch the rootfs with systemd-nspawn, which allows runtime flexibility
#        (bind mounts, hostnames, users, etc.) that would normally be fixed at
#        container creation time.
#
#   This way you can use any Podman-supported transport (docker://, oci:,
#   dir:, etc.) as a source, but still work with it like a traditional chroot.
#
# Example:
#   podspawn init alpine:3.20
#   podspawn shell alpine:3.20
#   podspawn exec alpine:3.20 -- make -j4
#
# Typical use cases:
#   - Quick cross-compilation chroots from upstream OCI images
#   - Testing or development in an image without a complex container lifecycle
#   - Reusing Podman's image handling while keeping nspawn's runtime flexibility

VERSION="1.0.0"

# ---------- globals ----------
PODSPAWN_DIR=${VAR_LIB_DIR:-/var/lib/podspawn}
PODSPAWN_FORCE=${FORCE_OPT:-0}
PODSPAWN_QUIET=${QUIET:-0}
PODSPAWN_EPHEMERAL=${EPHEMERAL:-0}
PODSPAWN_HOSTNAME=""
PODSPAWN_MACHINE=""
PODSPAWN_TAG_OVERRIDE=""
PODSPAWN_WORKDIR=""
PODSPAWN_BINDS=()
PODSPAWN_ENVS=()
PODSPAWN_EXTRA=()
PODSPAWN_NO_ENV=0

# runtime paths
META_DIR=""
ROOTFS_DIR=""
CONFIG_FILE=""
CONTAINER_NAME=""
REPO=""
SRC_REF=""
OCI_TAG=""

# ---------- logging ----------
msg() { (( PODSPAWN_QUIET )) || printf '>> %s\n' "$*" >&2; }
die() { printf 'ERR: %s\n' "$*" >&2; exit 1; }

# ---------- privilege management ----------
drop_privileges() {
  # Drop to original user if running via usermode/consolehelper
  if [[ -n "${USERHELPER_UID:-}" ]]; then
    local gid="${USERHELPER_GID:-$(id -g "$USERHELPER_UID" 2>/dev/null || echo "$USERHELPER_UID")}"
    exec setpriv --reuid="$USERHELPER_UID" --regid="$gid" --clear-groups "$@"
  fi
  # If not via usermode, just execute
  exec "$@"
}

require_root() {
  [[ $EUID -eq 0 ]] || die "This operation requires root privileges"
}

# ---------- usage ----------
usage() {
  cat <<EOF
Usage: $0 <command> [options] [args...]

Commands:
  init <image>              Pull and initialize a container from an image
  shell <container>         Start an interactive shell in the container
  exec <container> [--] <cmd...>  Execute a command in the container
  cp <container>:<src> <dest>     Copy files from container to host
  cp <src> <container>:<dest>     Copy files from host to container
  list                      List all managed containers
  info <container>          Show detailed information about a container
  rm <container>            Remove a container
  mount <container>         Print the rootfs path of a container
  version                   Show version information
  help                      Show this help message

Image/Container Reference:
  <image> can be any Podman-supported transport:
    docker://registry/name[:tag]     Pull from Docker Hub/registry
    oci:PATH:TAG                     OCI layout directory
    oci-archive:/path/img.tar:ref    OCI archive tarball
    docker-archive:/path/img.tar     Docker archive tarball
    dir:/path/dir                    docker save-style directory
    containers-storage:IMAGE[:TAG]   Local Podman storage
    docker-daemon:IMAGE[:TAG]        Local Docker storage

  Or short forms:
    alpine:3.20              Expands to docker://docker.io/library/alpine:3.20
    ubuntu                   Expands to docker://docker.io/library/ubuntu:latest
    myorg/myapp:v1.0         Expands to docker://docker.io/myorg/myapp:v1.0

  <container> can be:
    - Container name (sanitized image name)
    - Full image reference
    - repo:tag format

Global Options:
  -f, --force            Force re-pull/re-init even if exists
  -q, --quiet            Less output
  -h, --help             Show this help

Init Options:
  --tag TAG              Override the OCI tag for local storage

Shell/Exec Options:
  --bind H:C[:mode]      Bind mount host:container (mode: rw|ro)
  --ephemeral            Use nspawn --ephemeral (changes not persisted)
  --hostname NAME        Set container hostname
  --machine NAME         Set nspawn machine name
  --user UID             Run as specific user (default: container's USER)
  --root                 Run as root (UID 0)
  -w, --workdir PATH     Working directory inside container
  -e, --env KEY=VALUE    Set environment variable
  --no-env               Don't inherit environment from container image
  --nspawn-opt ARG       Pass additional option to systemd-nspawn

Environment Variables:
  VAR_LIB_DIR            Base directory for containers (default: /var/lib/podspawn)
  FORCE_OPT              Set to 1 to force operations
  QUIET                  Set to 1 for quiet mode
  EPHEMERAL              Set to 1 for ephemeral mode

Examples:
  # Initialize Alpine container
  $0 init alpine:3.20

  # Start interactive shell
  $0 shell alpine:3.20

  # Execute a command
  $0 exec alpine:3.20 -- apk add build-base

  # Execute with working directory
  $0 exec alpine:3.20 -w /tmp -- pwd

  # Set environment variables
  $0 shell alpine:3.20 -e PATH=/custom/bin:\$PATH

  # Cross-compile with bind mount
  $0 exec ubuntu:22.04 --bind /home/user/src:/build -w /build -- make

  # Copy files to/from container
  $0 cp myfile.txt alpine:3.20:/tmp/
  $0 cp alpine:3.20:/etc/os-release ./

  # Get rootfs path for cross-compilation
  arm-linux-gnueabihf-gcc --sysroot=\$($0 mount ubuntu:22.04) ...

  # List all containers
  $0 list

  # Show container info
  $0 info alpine:3.20

  # Remove container
  $0 rm alpine:3.20

  # Force re-pull and init
  $0 init --force alpine:3.20

For more information, visit: https://github.com/yourusername/podspawn
EOF
}

# ---------- helpers ----------
ref_normalize() {
  local ref="${1:-}"

  # explicit transports (leave unchanged)
  case "$ref" in
    docker://*|docker-archive:*|docker-daemon:*|oci:*|oci-archive:*|dir:*|containers-storage:*)
      echo "$ref"
      return
      ;;
  esac

  # heuristics for docker hub style refs
  case "$ref" in
    */*|*@*)  echo "docker://$ref" ;;                            # has registry/ns or digest
    *:*)      echo "docker://docker.io/library/$ref" ;;          # has tag but no slash
    *)        echo "docker://docker.io/library/$ref:latest" ;;   # plain name
  esac
}

ref_strip_transport() {
  local input="${1:-}"
  [[ -n "$input" ]] || die "strip_transport: missing input"
  echo "$input" | sed 's|^[a-zA-Z0-9+.-]\+://||'
}

ref_parse() {
  local r="${1:-}"
  [[ -n "$r" ]] || die "ref_parse: missing input"
  local last="${r##*/}" tag="" digest=""
  [[ "$r" == *"@"* ]] && digest="${r#*@}"
  [[ "$last" == *":"* ]] && { tag="${last##*:}"; last="${last%:*}"; }
  local hostpath="${r%"${r##*/}"}"; hostpath="${hostpath%/}"
  printf '%s|%s|%s|%s\n' "$hostpath" "$last" "$tag" "$digest"
}

sanitize() { echo "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'; }
tag_from_digest() { echo "sha-${1#sha256:}" | cut -c1-22; }

# ---------- bind mount security ----------
check_bind_mount_safety() {
  local spec="$1"
  local host_path container_path mode
  
  # Parse the bind mount spec (host:container or host:container:mode)
  if [[ "$spec" == *:*:* ]]; then
    host_path="${spec%%:*}"
    local rest="${spec#*:}"
    container_path="${rest%%:*}"
    mode="${rest##*:}"
  elif [[ "$spec" == *:* ]]; then
    host_path="${spec%%:*}"
    container_path="${spec#*:}"
    mode="rw"
  else
    die "Invalid bind mount spec: $spec"
  fi
  
  # Expand to absolute path
  host_path="$(realpath -m "$host_path" 2>/dev/null || echo "$host_path")"
  
  # Critical system directories that should NEVER be mounted (even read-only)
  # Reading /etc/shadow, /root/.ssh, etc. is a security risk
  local forbidden_dirs=(
    "/"
    "/bin"
    "/boot"
    "/dev"
    "/etc"
    "/lib"
    "/lib64"
    "/proc"
    "/root"
    "/sbin"
    "/sys"
    "/usr"
    "/var/lib/podman"
    "/var/lib/containers"
    "/var/lib/systemd"
  )
  
  for forbidden in "${forbidden_dirs[@]}"; do
    if [[ "$host_path" == "$forbidden" ]] || [[ "$host_path" == "$forbidden/"* ]]; then
      die "Refusing to mount system directory: $host_path (security policy)"
    fi
  done
  
  # Check if path exists
  if [[ ! -e "$host_path" ]]; then
    die "Bind mount source does not exist: $host_path"
  fi
  
  # Check write permission as the ORIGINAL USER, not as root
  # This prevents users from mounting files they don't have access to
  if [[ -n "${USERHELPER_UID:-}" ]]; then
    local gid="${USERHELPER_GID:-$(id -g "$USERHELPER_UID" 2>/dev/null || echo "$USERHELPER_UID")}"
    # Test as the original user using setpriv
    if ! setpriv --reuid="$USERHELPER_UID" --regid="$gid" --clear-groups test -w "$host_path" 2>/dev/null; then
      die "No write permission to bind mount source: $host_path (checked as UID ${USERHELPER_UID})"
    fi
  else
    # Running directly as root - still require write permission
    # This prevents accidentally mounting read-only filesystems
    if [[ ! -w "$host_path" ]]; then
      die "No write permission to bind mount source: $host_path"
    fi
  fi
}

# ---------- config ----------
config_save() {
  {
    echo "REF=$SRC_REF"
    echo "USER=$1"
    echo "OCI_TAG=$OCI_TAG"
    echo "REPO=$REPO"
    echo "CID=$2"
    echo "ENV=$3"
  } >"$CONFIG_FILE"
}

config_load() {
  local key val line
  while read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      REF)  ref="$val" ;;
      USER) user="$val" ;;
      OCI_TAG) oci_tag="$val" ;;
      REPO) repo="$val" ;;
      CID)  cid="$val" ;;
      ENV)  env="$val" ;;
    esac
  done <"$CONFIG_FILE"
}

# ---------- setup ----------
setup_layout() {
  local image_ref="${1:-}"
  [[ -n "$image_ref" ]] || die "Image reference required"

  SRC_REF="$(ref_normalize "$image_ref")"
  local parts hostpath name tag digest
  parts="$(ref_parse "$(ref_strip_transport "$SRC_REF")")"
  hostpath="${parts%%|*}"; parts="${parts#*|}"
  name="${parts%%|*}";    parts="${parts#*|}"
  tag="${parts%%|*}";     digest="${parts#*|}"

  if [[ -n "$PODSPAWN_TAG_OVERRIDE" ]]; then
    OCI_TAG="$PODSPAWN_TAG_OVERRIDE"
  elif [[ -n "$tag" ]]; then
    OCI_TAG="$tag"
  elif [[ -n "$digest" ]]; then
    OCI_TAG="$digest"
  else
    OCI_TAG="latest"
  fi

  REPO="$name"
  [[ -n "$hostpath" ]] && REPO="$hostpath/$name"
  CONTAINER_NAME="$(sanitize "$REPO")"

  META_DIR="${PODSPAWN_DIR%/}/$CONTAINER_NAME"
  ROOTFS_DIR="$META_DIR/rootfs"
  CONFIG_FILE="$META_DIR/config"

  mkdir -p "$META_DIR"
  chown root:podspawn "$PODSPAWN_DIR" "$META_DIR" 2>/dev/null || true

  (( PODSPAWN_QUIET>0 )) || {
    echo ">> NAME      : $CONTAINER_NAME"
    echo ">> SRC_REF   : $SRC_REF"
    echo ">> REPO      : $REPO"
    echo ">> OCI_TAG   : $OCI_TAG"
    echo ">> META      : $META_DIR"
  }
}

resolve_container() {
  local target="$1"
  [[ -n "$target" ]] || die "Container reference required"

  # First try as direct container name
  if [[ -f "$PODSPAWN_DIR/$target/config" ]]; then
    CONTAINER_NAME="$target"
    META_DIR="$PODSPAWN_DIR/$target"
    ROOTFS_DIR="$META_DIR/rootfs"
    CONFIG_FILE="$META_DIR/config"
    config_load
    SRC_REF="$ref"
    OCI_TAG="$oci_tag"
    REPO="$repo"
    return 0
  fi

  # Try to find by matching reference
  local found=0
  while IFS= read -r f; do
    ref= user= oci_tag= repo= cid=
    CONFIG_FILE="$f" config_load
    local cname="${f%/config}"; cname="${cname##*/}"

    if [[ "$repo:$oci_tag" == "$target" || "$ref" == "$target" || "$cname" == "$target" ]]; then
      CONTAINER_NAME="$cname"
      META_DIR="${f%/config}"
      ROOTFS_DIR="$META_DIR/rootfs"
      CONFIG_FILE="$f"
      SRC_REF="$ref"
      OCI_TAG="$oci_tag"
      REPO="$repo"
      found=1
      break
    fi
  done < <(find "$PODSPAWN_DIR" -maxdepth 2 -name config 2>/dev/null)

  if (( found )); then
    return 0
  fi

  # Treat as image reference and setup layout
  setup_layout "$target"
  if [[ -f "$CONFIG_FILE" ]]; then
    config_load
    return 0
  fi

  if (( PODSPAWN_QUIET )); then
    exit 1
  else
    die "Container not found: $target"
  fi
}

is_something_mounted() {
  find "$ROOTFS_DIR/" -mindepth 1 -print -quit 2>/dev/null | grep -q .
}

is_inited() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  is_something_mounted && (
    config_load 2>/dev/null || return 1
    [[ "${ref:-}" = "$SRC_REF" && "${oci_tag:-}" = "$OCI_TAG" ]]
  )
}

# ---------- podman ----------
pod_pull() {
  require_root
  if (( PODSPAWN_QUIET )); then
    podman pull "$SRC_REF" >/dev/null 2>&1
  else
    podman pull "$SRC_REF"
  fi
}

pod_mount() {
  require_root
  msg "mounting -> $META_DIR"
  umount "$ROOTFS_DIR" 2>/dev/null || true
  mkdir -p "$ROOTFS_DIR"
  chown root:podspawn "$ROOTFS_DIR" 2>/dev/null || true

  local local_cid
  local_cid=$(podman ps -a --filter "name=$CONTAINER_NAME" --format "{{.ID}}" --no-trunc)

  if [[ -n "$local_cid" ]]; then
    config_load 2>/dev/null || true

    if ! [[ "$local_cid" == "${cid:-}" && "${ref:-}" = "$SRC_REF" && "${oci_tag:-}" = "$OCI_TAG" ]] ||
         [[ "$PODSPAWN_FORCE" == 1 ]]
    then
      podman rm -f "$local_cid" >/dev/null
      pod_pull
      local_cid=""
    fi
  else
    pod_pull
  fi

  # (Re)create container if cid is empty
  if [[ -z "$local_cid" ]]; then
    local_cid=$(podman create --name "$CONTAINER_NAME" -it "$SRC_REF" /bin/sh -c 'h(){ exit 1; }; trap h SIGTERM; sleep infinity & wait')
  fi

  local mnt=$(podman mount "$local_cid" 2>/dev/null)
  local duser=$(podman inspect "$CONTAINER_NAME" --format '{{.Config.User}}' 2>/dev/null)
  local denv=$(podman inspect "$CONTAINER_NAME" --format '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' 2>/dev/null | base64 -w0)
  touch -r "$mnt" "$ROOTFS_DIR"
  mount --bind "$mnt" "$ROOTFS_DIR"
  config_save "$duser" "$local_cid" "$denv"
}

init_rootfs() {
  if is_inited; then
    if (( PODSPAWN_FORCE )); then
      msg "Force re-initializing..."
      pod_mount
    else
      msg "Already initialized; use --force to re-init."
    fi
  else
    pod_mount
  fi
}

# ---------- mgmt ----------
print_info() {
  local space="${1:-}"
  echo "${space}Container : $CONTAINER_NAME"
  echo "${space}Repo      : $repo"
  echo "${space}Ref       : $ref"
  echo "${space}Tag       : $oci_tag"
  echo "${space}User      : ${user:-<none>}"
  echo "${space}RootFS    : $ROOTFS_DIR"
  echo "${space}Config    : $CONFIG_FILE"
  if mountpoint -q "$ROOTFS_DIR" 2>/dev/null; then
    echo "${space}Status    : ✅ mounted"
  else
    echo "${space}Status    : ❌ not mounted"
  fi
}

# ---------- commands ----------
cmd_init() {
  local image="$1"
  setup_layout "$image"
  init_rootfs
}

cmd_shell() {
  local container="$1"; shift
  resolve_container "$container"
  is_something_mounted || init_rootfs

  # If no args, let systemd-nspawn handle the shell (starts in home dir)
  # Otherwise wrap command in shell for interpretation
  if [[ $# -eq 0 ]]; then
    run_in_container
  else
    run_in_container /bin/sh -c "$*"
  fi
}

cmd_exec() {
  local container="$1"; shift
  resolve_container "$container"
  is_something_mounted || init_rootfs
  run_in_container "$@"
}

cmd_list() {
  find "$PODSPAWN_DIR" -maxdepth 2 -name config 2>/dev/null | while read -r f; do
    ref= user= oci_tag= repo= cid=
    CONFIG_FILE="$f" config_load
    local cname="${f%/config}"; cname="${cname##*/}"
    CONTAINER_NAME="$cname"
    ROOTFS_DIR="$(dirname "$f")/rootfs"
    CONFIG_FILE="$f"
    echo "┌──────────────────────────────────────────────────"
    print_info " "
    echo "└──────────────────────────────────────────────────"
    echo
  done
}

cmd_info() {
  local target="$1"
  resolve_container "$target"
  print_info
}

cmd_rm() {
  local target="$1"
  resolve_container "$target"

  local local_cid=$(podman ps -a --filter "name=$CONTAINER_NAME" --format "{{.ID}}")
  [[ -n "$local_cid" ]] && podman rm -f "$local_cid" >/dev/null
  umount "$ROOTFS_DIR" 2>/dev/null || true
  rm -rf "$META_DIR"
  msg "Removed $CONTAINER_NAME"
}

cmd_cp() {
  local src="$1"
  local dest="$2"

  [[ -z "$src" || -z "$dest" ]] && die "cp requires source and destination"

  require_root

  # Determine direction: container:path or path
  if [[ "$src" == *:* ]]; then
    # Copy from container to host
    local container="${src%%:*}"
    local container_path="${src#*:}"
    resolve_container "$container"

    msg "Copying from $container:$container_path to $dest"

    # Copy to temporary directory first (as root)
    local tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" EXIT

    # Fix ownership of temp directory
    if [[ -n "${USERHELPER_UID:-}" ]]; then
      local gid="${USERHELPER_GID:-$(id -g "$USERHELPER_UID" 2>/dev/null || echo "$USERHELPER_UID")}"
      chown "$USERHELPER_UID:$gid" "$tmpdir"
    fi

    podman cp "$CONTAINER_NAME:$container_path" "$tmpdir/"

    # Get the basename of what was copied
    local basename="${container_path##*/}"

    # Fix ownership of copied content
    if [[ -n "${USERHELPER_UID:-}" ]]; then
      chown -R "$USERHELPER_UID:$gid" "$tmpdir/$basename"
    fi

    # Move to final destination as user (with dropped privileges)
    drop_privileges mv "$tmpdir/$basename" "$dest"

  elif [[ "$dest" == *:* ]]; then
    # Copy from host to container (this is safe, user can only copy their own files)
    local container="${dest%%:*}"
    local container_path="${dest#*:}"
    resolve_container "$container"

    msg "Copying from $src to $container:$container_path"
    podman cp "$src" "$CONTAINER_NAME:$container_path"
  else
    die "cp requires at least one argument in format 'container:path'"
  fi
}

cmd_mount() {
  local container="$1"
  resolve_container "$container"
  is_inited || die "Not initialized. Use 'init' first"
  echo "$ROOTFS_DIR"
}

cmd_version() {
  echo "podspawn version $VERSION"
}

# ---------- run ----------
resolve_uid() {
  config_load 2>/dev/null || true
  echo "${user:-0}"
}

run_in_container() {
  local uid_in="${uid_in:-$(resolve_uid)}"

  local binds=()
  for spec in "${PODSPAWN_BINDS[@]}"; do
    case "$spec" in
      *:ro) binds+=( --bind-ro "${spec%:ro}" ) ;;
      *:rw) binds+=( --bind    "${spec%:rw}" ) ;;
      *)    binds+=( --bind "$spec" ) ;;
    esac
  done

  # Parse and add image environment variables from config
  local env_args=()
  config_load 2>/dev/null || true
  
  # Only load container environment if --no-env wasn't specified
  if [[ "$PODSPAWN_NO_ENV" -eq 0 && -n "${env:-}" ]]; then
    # Decode base64 and parse environment variables
    while IFS= read -r e; do
      [[ -n "$e" ]] && env_args+=( --setenv="$e" )
    done < <(echo "$env" | base64 -d)
  fi

  # Add user-specified environment variables (these override image defaults)
  for e in "${PODSPAWN_ENVS[@]}"; do
    env_args+=( --setenv="$e" )
  done

  local hn_args=()
  [[ -n "$PODSPAWN_HOSTNAME" ]] && hn_args+=( --hostname "$PODSPAWN_HOSTNAME" )
  [[ -n "$PODSPAWN_MACHINE"  ]] && hn_args+=( --machine  "$PODSPAWN_MACHINE" )
  [[ ${#hn_args[@]} -eq 0 ]] && hn_args+=( --hostname "$(hostname)" )

  local eph=()
  (( PODSPAWN_EPHEMERAL )) && eph+=( --ephemeral )

  local chdir_args=()
  [[ -n "$PODSPAWN_WORKDIR" ]] && chdir_args+=( --chdir="$PODSPAWN_WORKDIR" )

  exec systemd-nspawn -q -D "$ROOTFS_DIR" -u "$uid_in" \
    --register=no --resolv-conf=copy-host --timezone=off --keep-unit \
    "${hn_args[@]}" "${binds[@]}" "${eph[@]}" "${chdir_args[@]}" "${env_args[@]}" "${PODSPAWN_EXTRA[@]}" \
    -- "$@"
}

# ---------- main ----------
main() {
  [[ $# -eq 0 ]] && { usage; exit 1; }

  # Parse global options first
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force) PODSPAWN_FORCE=1; shift ;;
      -q|--quiet) PODSPAWN_QUIET=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      -*) break ;;  # Unknown option, might be command-specific
      *) break ;;   # Not an option, must be command
    esac
  done

  local command="${1:-}"
  [[ -z "$command" ]] && { usage; exit 1; }
  shift

  case "$command" in
    init)
      # Parse init-specific options
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -f|--force) PODSPAWN_FORCE=1; shift ;;
          -q|--quiet) PODSPAWN_QUIET=1; shift ;;
          --tag) PODSPAWN_TAG_OVERRIDE="$2"; shift 2 ;;
          --) shift; break ;;
          -*) die "Unknown init option: $1" ;;
          *) break ;;
        esac
      done
      [[ $# -lt 1 ]] && die "init requires an image reference"
      cmd_init "$1"
      ;;

    shell|exec)
      [[ $# -lt 1 ]] && die "$command requires a container reference"
      local container="$1"; shift
      # Parse run options
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -f|--force) PODSPAWN_FORCE=1; shift ;;
          -q|--quiet) PODSPAWN_QUIET=1; shift ;;
          --bind)
            check_bind_mount_safety "$2"
            PODSPAWN_BINDS+=("$2")
            shift 2
            ;;
          --ephemeral) PODSPAWN_EPHEMERAL=1; shift ;;
          --hostname) PODSPAWN_HOSTNAME="$2"; shift 2 ;;
          --machine)  PODSPAWN_MACHINE="$2"; shift 2 ;;
          --user)     uid_in="$2"; shift 2 ;;
          --root)     uid_in=0; shift ;;
          -w|--workdir) PODSPAWN_WORKDIR="$2"; shift 2 ;;
          -e|--env)   PODSPAWN_ENVS+=("$2"); shift 2 ;;
          --no-env)   PODSPAWN_NO_ENV=1; shift ;;
          --nspawn-opt) PODSPAWN_EXTRA+=("$2"); shift 2 ;;
          --) shift; break ;;
          -*) die "Unknown $command option: $1" ;;
          *) break ;;
        esac
      done
      if [[ "$command" == "shell" ]]; then
        cmd_shell "$container" "$@"
      else
        cmd_exec "$container" "$@"
      fi
      ;;

    cp)
      [[ $# -lt 2 ]] && die "cp requires source and destination"
      cmd_cp "$1" "$2"
      ;;

    list)
      cmd_list
      ;;

    info)
      [[ $# -lt 1 ]] && die "info requires a container reference"
      cmd_info "$1"
      ;;

    rm)
      [[ $# -lt 1 ]] && die "rm requires a container reference"
      cmd_rm "$1"
      ;;

    mount)
      [[ $# -lt 1 ]] && die "mount requires a container reference"
      cmd_mount "$1"
      ;;

    version)
      cmd_version
      ;;

    help|--help|-h)
      usage
      exit 0
      ;;

    *)
      die "Unknown command: $command (try 'podspawn help')"
      ;;
  esac
}

main "$@"
