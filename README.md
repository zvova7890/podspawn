# podspawn

Run OCI/Podman images like traditional chroots with systemd-nspawn.

## Why?

OCI container runtimes (Podman/Docker) require mounts and settings to be fixed at container creation. Rootless Podman also isolates the filesystem in user namespaces, making it inaccessible for cross-compilation.

**podspawn** combines Podman's image management with systemd-nspawn's runtime flexibility:
- ✅ Use any OCI image as a mutable chroot/sysroot
- ✅ Accessible rootfs for cross-compilation toolchains
- ✅ Change bind mounts, users, and settings per command
- ✅ Works for both native builds and cross-compilation

## Installation

```bash
# Install script and PAM configuration
sudo install -m 755 podspawn.sh /usr/bin/podspawn.sh
sudo install -m 644 pam-podspawn /etc/pam.d/podspawn
sudo install -m 644 console.apps-podspawn /etc/security/console.apps/podspawn
sudo ln -sf /usr/bin/consolehelper /usr/bin/podspawn

# Create podspawn group and add your user
sudo groupadd -r podspawn
sudo usermod -aG podspawn $USER

# Re-login for group changes to take effect
```

**Requirements:**
- `podman` - OCI image management
- `systemd-nspawn` - container runtime
- `usermode` - PAM-based privilege elevation

## Quick Start

```bash
# Initialize a container
podspawn init alpine:3.20

# Interactive shell (starts in home directory)
podspawn shell alpine:3.20

# Execute command
podspawn exec alpine:3.20 -- apk add build-essential

# Cross-compilation
SYSROOT=$(podspawn mount ubuntu:22.04)
arm-linux-gnueabihf-gcc --sysroot=$SYSROOT -o app main.c
```

## Commands

```bash
podspawn init <image>              # Pull and initialize container
podspawn shell <container>         # Interactive shell or run shell command
podspawn exec <container> -- <cmd> # Execute command directly
podspawn cp <src> <dest>           # Copy files (supports container:path syntax)
podspawn mount <container>         # Print rootfs path
podspawn list                      # List containers
podspawn info <container>          # Show container details
podspawn rm <container>            # Remove container
```

## Common Options

```bash
--bind H:C[:ro|rw]    # Bind mount host to container
-w, --workdir PATH    # Working directory
-e, --env KEY=VALUE   # Environment variable
--user UID            # Run as specific user
--root                # Run as root
--ephemeral           # Discard changes after exit
-f, --force           # Force re-pull/re-init
```

## Examples

**Cross-compilation workflow:**
```bash
podspawn init ubuntu:22.04
podspawn exec ubuntu:22.04 --bind $PWD:/build -w /build -- make
```

**Development with bind mount:**
```bash
podspawn shell alpine:3.20 \
  --bind /home/user/myproject:/src \
  -w /src \
  -e CC=gcc
```

**Copy files:**
```bash
podspawn cp myconfig.conf alpine:3.20:/etc/
podspawn cp alpine:3.20:/var/log/app.log ./
```

**Ephemeral testing:**
```bash
podspawn shell alpine:3.20 --ephemeral 'rm -rf /tmp/*'
```

## How It Works

1. **Pull**: Uses Podman to fetch OCI images
2. **Mount**: Runs `podman mount` as root, bind mounts to `/var/lib/podspawn/<container>/rootfs`
3. **Execute**: Uses systemd-nspawn for runtime flexibility

The rootfs is mounted system-wide (not in a user namespace), making it accessible for cross-compilers and other host tools.

## Image References

Supports all Podman transports:
- `alpine:3.20` → Docker Hub
- `docker://registry.example.com/image:tag`
- `oci:/path/to/layout:tag`
- `oci-archive:/path/to/image.tar:tag`
- `containers-storage:image:tag`

## Configuration

Containers stored in `/var/lib/podspawn/` (override with `VAR_LIB_DIR` env var).

PAM configuration allows running as root without explicit sudo through usermode's `consolehelper`.

### Running inside Docker

podspawn can be used inside Docker containers for cross-compilation, but requires:
```bash
docker run --privileged --cgroupns=private ...
```

The `--privileged` flag is needed for mounting operations, and `--cgroupns=private` ensures systemd-nspawn works correctly.

## Releasing

Create a release commit and matching annotated tag with:

```bash
scripts/release.sh 1.2.3
git push origin HEAD v1.2.3
```

An optional second argument sets the Debian changelog and tag message:

```bash
scripts/release.sh 1.2.3 "Add support for example images"
```

The release script updates the version in `podspawn.sh` and
`debian/changelog`. The tag workflow verifies both versions against the tag
before building and publishing the Debian package.

## Comparison

| Feature | podspawn | Podman | Buildah |
|---------|----------|--------|---------|
| OCI images | ✅ | ✅ | ✅ |
| Runtime flexibility | ✅ | ❌ | N/A |
| Accessible rootfs | ✅ | ❌* | ❌* |
| Cross-compilation | ✅ | ❌ | ❌ |

\* Rootless mode requires unshare namespace, making rootfs inaccessible for cross-compilation

## License

MIT
