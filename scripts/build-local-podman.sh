#!/usr/bin/env bash
# Local single-device GrapheneOS + KernelSU-Next build.
#
# The build runs inside a Podman container because Kleaf requires a normal
# FHS environment; Nix shells are not used.
#
# Usage:
#   ./scripts/build-local-podman.sh [options]
#
# Options:
#   -d, --device NAME       Device codename (default: lynx)
#       --lto MODE          thin|full|none (default: thin)
#   -j, --jobs N            Build jobs (default: nproc)
#       --ram-mb N          Kleaf RAM budget in MiB (default: 75% of RAM)
#       --ksu-ref REF       KernelSU-Next tag/commit (default: v3.4.2)
#       --no-anykernel      Do not build AnyKernel3-<device>.zip
#       --clean             Remove .local-build/<device> before building
#       --rebuild-image     Rebuild the builder image
#       --privileged        Run the build container privileged (Bazel sandbox)
#       --min-free-gb N     Abort if the workspace has less free space
#   -h, --help              Show this help

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_ROOT="$REPO_ROOT/.local-build"
IMAGE="${KSU_BUILDER_IMAGE:-ksu-grapheneos-builder:22.04}"
CONTAINERFILE="$REPO_ROOT/scripts/podman/Containerfile"

DEVICE=lynx
LTO=thin
JOBS=""
RAM_MB=""
KSU_REF=v3.4.2
BUILD_ANYKERNEL=1
CLEAN=0
REBUILD_IMAGE=0
PRIVILEGED=0
MIN_FREE_GB="${MIN_FREE_GB:-40}"
IN_CONTAINER=0

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//'
}

die() {
    echo "error: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --in-container)
            IN_CONTAINER=1
            shift
            ;;
        -d|--device)
            [ "$#" -ge 2 ] || die "$1 requires an argument"
            DEVICE="$2"
            shift 2
            ;;
        --lto)
            [ "$#" -ge 2 ] || die "$1 requires an argument"
            LTO="$2"
            shift 2
            ;;
        -j|--jobs)
            [ "$#" -ge 2 ] || die "$1 requires an argument"
            JOBS="$2"
            shift 2
            ;;
        --ram-mb)
            [ "$#" -ge 2 ] || die "$1 requires an argument"
            RAM_MB="$2"
            shift 2
            ;;
        --ksu-ref)
            [ "$#" -ge 2 ] || die "$1 requires an argument"
            KSU_REF="$2"
            shift 2
            ;;
        --no-anykernel)
            BUILD_ANYKERNEL=0
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --rebuild-image)
            REBUILD_IMAGE=1
            shift
            ;;
        --privileged)
            PRIVILEGED=1
            shift
            ;;
        --min-free-gb)
            [ "$#" -ge 2 ] || die "$1 requires an argument"
            MIN_FREE_GB="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (use --help)"
            ;;
    esac
done

case "$LTO" in
    thin|full|none) ;;
    *) die "--lto must be thin, full or none" ;;
esac
case "$MIN_FREE_GB" in
    ''|*[!0-9]*) die "--min-free-gb must be an integer" ;;
esac
case "$JOBS" in
    ''|*[!0-9]*) [ -z "$JOBS" ] || die "--jobs must be an integer" ;;
esac
case "$RAM_MB" in
    ''|*[!0-9]*) [ -z "$RAM_MB" ] || die "--ram-mb must be an integer" ;;
esac

if [ "$IN_CONTAINER" -eq 0 ]; then
    command -v podman >/dev/null 2>&1 || die "podman is not installed"

    free_gb=$(df -Pk "$REPO_ROOT" | awk 'NR == 2 { print int($4 / 1024 / 1024) }')
    if [ -n "$free_gb" ] && [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
        die "need at least ${MIN_FREE_GB} GiB free in $REPO_ROOT (have ${free_gb} GiB); use --min-free-gb to override"
    fi

    if [ "$REBUILD_IMAGE" -eq 1 ] || ! podman image exists "$IMAGE" >/dev/null 2>&1; then
        echo "==> Building builder image $IMAGE"
        build_args=(build --tag "$IMAGE" --file "$CONTAINERFILE")
        [ "$REBUILD_IMAGE" -eq 1 ] && build_args+=(--no-cache)
        podman "${build_args[@]}" "$(dirname "$CONTAINERFILE")"
    fi

    if [ "$(id -u)" -ne 0 ] && [ -e "$WORK_ROOT" ] && [ ! -w "$WORK_ROOT" ]; then
        die "$WORK_ROOT is not writable by $(id -un); remove it first, e.g. podman unshare rm -rf $WORK_ROOT"
    fi
    if [ "$(id -u)" -ne 0 ] && [ -e "$WORK_ROOT/$DEVICE" ] && [ ! -w "$WORK_ROOT/$DEVICE" ]; then
        die "$WORK_ROOT/$DEVICE is not writable by $(id -un); remove it first, e.g. podman unshare rm -rf $WORK_ROOT/$DEVICE"
    fi

    inside_args=(--in-container --device "$DEVICE" --lto "$LTO" --ksu-ref "$KSU_REF")
    [ -n "$JOBS" ] && inside_args+=(--jobs "$JOBS")
    [ -n "$RAM_MB" ] && inside_args+=(--ram-mb "$RAM_MB")
    [ "$BUILD_ANYKERNEL" -eq 0 ] && inside_args+=(--no-anykernel)
    [ "$CLEAN" -eq 1 ] && inside_args+=(--clean)

    run_args=(
        run --rm
        --security-opt label=disable
        --security-opt seccomp=unconfined
        --shm-size=2g
        --ulimit nofile=65536:65536
        -v "$REPO_ROOT:/work"
        -w /work
    )
    # Run as the host UID so Bazel is not root and bind-mount files keep
    # the caller's ownership.
    if [ "$(id -u)" -ne 0 ]; then
        run_args+=(--userns=keep-id --user "$(id -u):$(id -g)")
        run_args+=(-e HOME=/work/.local-build/.home -e USER="$(id -un)")
    fi
    if [ -t 0 ] && [ -t 1 ]; then
        run_args+=(-t)
    fi
    [ "$PRIVILEGED" -eq 1 ] && run_args+=(--privileged)

    echo "==> Started build container ($DEVICE, lto=$LTO)"
    set +e
    podman "${run_args[@]}" "$IMAGE" \
        bash /work/scripts/build-local-podman.sh "${inside_args[@]}"
    rc=$?
    set -e

    if [ "$(id -u)" -eq 0 ] && [ -d "$WORK_ROOT" ]; then
        echo "note: rootful podman writes as root; chown $WORK_ROOT to your user after the build if needed"
    fi

    exit "$rc"
fi

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_ROOT="$REPO_ROOT/.local-build"
WORK="$WORK_ROOT/$DEVICE"
KERNEL="$WORK/kernel"
DIST="$WORK/dist"

export HOME="${HOME:-/root}"
mkdir -p "$WORK_ROOT" "$HOME"

case "$DEVICE" in
    raviole|bluejay)
        KERNEL_REPO=kernel_pixel_6.1
        KERNEL_BRANCH=17
        ARTIFACTS="boot.img dtbo.img vendor_dlkm.img"
        ;;
    rango|muzel)
        KERNEL_REPO=kernel_pixel_6.6
        KERNEL_BRANCH=17
        ARTIFACTS="boot.img dtbo.img vendor_dlkm.img system_dlkm.img vendor_kernel_boot.img"
        ;;
    stallion)
        KERNEL_REPO=kernel_pixel_6.1
        KERNEL_BRANCH=17-stallion
        ARTIFACTS="boot.img dtbo.img vendor_dlkm.img system_dlkm.img vendor_kernel_boot.img"
        ;;
    lynx|pantah|shusky|akita|caimito|comet|tegu)
        KERNEL_REPO=kernel_pixel_6.1
        KERNEL_BRANCH=17
        ARTIFACTS="boot.img dtbo.img vendor_dlkm.img system_dlkm.img vendor_kernel_boot.img"
        ;;
    *)
        die "unsupported device: $DEVICE"
        ;;
esac

case "$DEVICE" in
    raviole) DEVICE_NAMES="raviole oriole raven" ;;
    pantah) DEVICE_NAMES="pantah cheetah panther" ;;
    shusky) DEVICE_NAMES="shusky husky shiba" ;;
    caimito) DEVICE_NAMES="caimito tokay caiman komodo" ;;
    muzel) DEVICE_NAMES="muzel mustang blazer frankel" ;;
    *) DEVICE_NAMES="$DEVICE" ;;
esac

if [ -z "$JOBS" ]; then
    JOBS=$(nproc)
fi
if [ -z "$RAM_MB" ]; then
    mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    RAM_MB=$(( mem_kb * 3 / 4 / 1024 ))
fi

echo "==> Device: $DEVICE"
echo "==> Kernel: $KERNEL_REPO ($KERNEL_BRANCH)"
echo "==> KernelSU-Next: $KSU_REF"
echo "==> Jobs: $JOBS, RAM budget: ${RAM_MB} MiB, LTO: $LTO"
echo "==> Work tree: $WORK"

if [ "$CLEAN" -eq 1 ]; then
    echo "==> Removing $WORK"
    rm -rf "$WORK"
fi
mkdir -p "$WORK_ROOT"

if [ ! -d "$KERNEL/.git" ]; then
    echo "==> Cloning GrapheneOS kernel"
    git clone --recurse-submodules --shallow-submodules --depth=1 \
        -b "$KERNEL_BRANCH" \
        "https://gitlab.com/grapheneos/$KERNEL_REPO.git" "$KERNEL"
else
    echo "==> Reusing existing kernel tree (use --clean to refresh)"
fi

cd "$KERNEL/aosp"
ref="$KSU_REF"
[ -n "$ref" ] || ref=v3.4.2
echo "==> Setting up KernelSU-Next $ref"
setup_url="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/v3.4.2/kernel/setup.sh"
curl -fLSs "$setup_url" | bash -s "$ref"

test -d KernelSU-Next/.git || die "KernelSU-Next checkout not found"
expected=$(git -C KernelSU-Next rev-parse "$ref^{commit}") \
    || die "unknown KernelSU-Next ref: $ref"
actual=$(git -C KernelSU-Next rev-parse HEAD)
[ "$actual" = "$expected" ] \
    || die "KernelSU-Next is at $actual, expected $expected"
test -e drivers/kernelsu || die "drivers/kernelsu symlink missing"
grep -q "obj-\$(CONFIG_KSU) += kernelsu/" drivers/Makefile \
    || die "drivers/Makefile was not patched"
grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig \
    || die "drivers/Kconfig was not patched"

# Device modules need the GKI-generated signing key; patch Kleaf to pass it.
python3 "$REPO_ROOT/scripts/kernel-patches.py" "$KERNEL"

DEFCONFIG="arch/arm64/configs/gki_defconfig"
apply_config() {
    local line="$1"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && return 0
    local key="${line%%=*}" value="${line#*=}"
    if grep -q "^$key=" "$DEFCONFIG"; then
        sed -i "s|^$key=.*|$key=$value|g" "$DEFCONFIG"
    elif grep -q "^# $key is not set" "$DEFCONFIG"; then
        sed -i "s|^# $key is not set|$key=$value|g" "$DEFCONFIG"
    else
        echo "$key=$value" >> "$DEFCONFIG"
    fi
}

configs='CONFIG_KSU=y
CONFIG_MODULE_SIG_ALL=y
CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"'
while IFS= read -r line; do apply_config "$line"; done <<< "$configs"

grep -q '^CONFIG_KSU=y' "$DEFCONFIG" || die "CONFIG_KSU is not enabled"
grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$DEFCONFIG" \
    || die "CONFIG_MODULE_SIG_FORCE must stay enabled"
! grep -q '^CONFIG_MODULE_SIG_PROTECT=y' "$DEFCONFIG" \
    || die "CONFIG_MODULE_SIG_PROTECT must not replace FORCE"
grep -q '^CONFIG_KPROBES=y' "$DEFCONFIG" \
    || die "CONFIG_KPROBES is required by KernelSU-Next"
grep -q '^CONFIG_EXT4_FS=y' "$DEFCONFIG" \
    || die "CONFIG_EXT4_FS is required by KernelSU-Next"

sed -i 's|^POST_DEFCONFIG_CMDS="check_defconfig"|POST_DEFCONFIG_CMDS=""|' build.config.gki
grep -q '^POST_DEFCONFIG_CMDS=""' build.config.gki \
    || die "failed to disable check_defconfig"

KSU_TAG="$(git -C KernelSU-Next describe --abbrev=0 --tags 2>/dev/null \
    || git -C KernelSU-Next rev-parse --short HEAD)"
KSU_SHA="$(git -C KernelSU-Next rev-parse --short HEAD)"
echo "==> KernelSU-Next $KSU_TAG ($KSU_SHA)"

exclude="$(git rev-parse --git-path info/exclude)"
grep -qxF 'KernelSU-Next/' "$exclude" 2>/dev/null \
    || printf '%s\n' 'KernelSU-Next/' >> "$exclude"
git add -A
if ! git diff --cached --quiet; then
    git -c commit.gpgsign=false -c user.name=local-build -c user.email=local-build@localhost \
        commit -m "Add KernelSU-Next ${KSU_TAG} (${KSU_SHA})"
else
    echo "==> aosp: nothing to commit"
fi

cd "$KERNEL"

# Device defconfigs disable MODULE_SIG_ALL; enable it so vendor modules are
# signed under FORCE.
while IFS= read -r -d '' f; do
    tmp="$(mktemp)"
    awk '
        BEGIN { done = 0 }
        /^CONFIG_MODULE_SIG_ALL=/ {
            if (!done) { print "CONFIG_MODULE_SIG_ALL=y"; done = 1 }
            next
        }
        /^# CONFIG_MODULE_SIG_ALL is not set$/ {
            if (!done) { print "CONFIG_MODULE_SIG_ALL=y"; done = 1 }
            next
        }
        { print }
        END { if (!done) print "CONFIG_MODULE_SIG_ALL=y" }
    ' "$f" > "$tmp"
    mv "$tmp" "$f"
done < <(find private/devices/google -type f -name '*_defconfig' -print0)

for d in private/devices/google/*/; do
    [ -e "$d/.git" ] || continue
    [ -n "$(git -C "$d" status --porcelain)" ] || continue
    git -C "$d" add -A
    git -C "$d" -c commit.gpgsign=false \
        -c user.name=local-build -c user.email=local-build@localhost \
        commit -m "Enable CONFIG_MODULE_SIG_ALL for module signing"
done

git add common/ack build/kernel private/devices/google
if ! git diff --cached --quiet; then
    git -c commit.gpgsign=false -c user.name=local-build -c user.email=local-build@localhost \
        commit -m "Update ack: KernelSU-Next ${KSU_TAG}"
else
    echo "==> kernel: nothing to commit"
fi

cd "$KERNEL"

# Drop stale staging dirs so the output glob sees a single kernel release.
if [ -d out/bazel ]; then
    find out/bazel -path '*/staging/lib/modules/*' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find out/bazel -name 'modules_staging_dir.tar.gz' -delete 2>/dev/null || true
fi

if [ "$KERNEL_REPO" = kernel_pixel_6.6 ]; then
    manifest_args=(--repo_manifest="$(realpath .)":"$(realpath aosp_manifest.xml)")
else
    export KLEAF_REPO_MANIFEST=aosp_manifest.xml
    manifest_args=()
fi

echo "==> Building boot images (this takes a while)"
KLEAF_MAKE_JOBS="$JOBS" nice -n 19 ionice -c2 -n7 \
    ./build_"$DEVICE".sh --lto="$LTO" \
        "${manifest_args[@]}" \
        --config=local \
        --jobs="$JOBS" \
        --local_ram_resources="$RAM_MB" \
        --local_cpu_resources="$JOBS"

CONFIG_OUT="out/$DEVICE/dist/.config"
if [ -f "$CONFIG_OUT" ]; then
    grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$CONFIG_OUT" \
        || die "$CONFIG_OUT: CONFIG_MODULE_SIG_FORCE is not enabled"
    grep -q '^CONFIG_MODULE_SIG_ALL=y' "$CONFIG_OUT" \
        || die "$CONFIG_OUT: CONFIG_MODULE_SIG_ALL is not enabled"
else
    echo "warning: $CONFIG_OUT not found; module signing cannot be verified"
fi

unsigned=0
for f in out/"$DEVICE"/dist/*.ko; do
    [ -e "$f" ] || continue
    if ! tail -c 28 "$f" | grep -aq '~Module signature appended~'; then
        echo "unsigned module: $f" >&2
        unsigned=1
    fi
done
[ "$unsigned" -eq 0 ] || die "some modules are unsigned; CONFIG_MODULE_SIG_FORCE would reject them"

rm -rf "$DIST"
mkdir -p "$DIST"
for f in $ARTIFACTS; do
    test -f "out/$DEVICE/dist/$f" || die "missing artifact: $f"
    cp "out/$DEVICE/dist/$f" "$DIST/"
done
printf '%s\n' "$DEVICE" > "$DIST/device.txt"
printf '%s\n' "$KSU_TAG" > "$DIST/version.txt"

{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    # shellcheck disable=SC2016  # written literally into install.sh
    printf '%s\n' 'cd "$(dirname "$0")"'
    printf '%s\n' ''
    printf '%s\n' 'fastboot oem disable-verification'
    for f in boot dtbo vendor_kernel_boot; do
        if echo " $ARTIFACTS " | grep -q " $f.img "; then
            printf 'fastboot flash %s %s.img\n' "$f" "$f"
        fi
    done
    if echo " $ARTIFACTS " | grep -qE " (system_dlkm|vendor_dlkm)\.img "; then
        printf '%s\n' 'fastboot reboot fastboot'
        for f in system_dlkm vendor_dlkm; do
            if echo " $ARTIFACTS " | grep -q " $f.img "; then
                printf 'fastboot flash %s %s.img\n' "$f" "$f"
            fi
        done
    fi
} > "$DIST/install.sh"
chmod +x "$DIST/install.sh"

if [ "$BUILD_ANYKERNEL" -eq 1 ]; then
    AK3_REF="020dfeccf9d7e962a48400fc94d3e451df92eead"
    ak3="$WORK/AnyKernel3"
    stage="$WORK/ak3"
    rm -rf "$ak3" "$stage"

    git clone -q https://github.com/osm0sis/AnyKernel3.git "$ak3"
    git -C "$ak3" checkout -q --detach "$AK3_REF"
    test "$(git -C "$ak3" rev-parse HEAD)" = "$AK3_REF"

    mkdir -p "$stage"
    cp -a "$ak3/tools" "$ak3/META-INF" "$stage/"
    for f in $ARTIFACTS; do
        cp "$DIST/$f" "$stage/$f"
    done

    {
        printf '%s\n' '### AnyKernel3 Ramdisk Mod Script'
        printf '%s\n' "properties() { '"
        printf 'kernel.string=KernelSU-Next for GrapheneOS (%s)\n' "$DEVICE"
        printf '%s\n' 'do.devicecheck=1'
        printf '%s\n' 'do.modules=0'
        printf '%s\n' 'do.systemless=0'
        printf '%s\n' 'do.cleanup=1'
        printf '%s\n' 'do.cleanuponabort=0'
        n=0
        for dn in $DEVICE_NAMES; do
            n=$((n + 1))
            printf 'device.name%d=%s\n' "$n" "$dn"
        done
        printf '%s\n' 'supported.versions='
        printf '%s\n' "'; }"
        printf '\n'
    } > "$stage/anykernel.sh"

    cat >> "$stage/anykernel.sh" <<'AK3EOF'
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;

. tools/ak3-core.sh;

real_slot() {
  local s
  s="$(grep -o 'androidboot[.]slot_suffix=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)"
  [ "$s" ] || s="$(grep -o 'androidboot[.]slot=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)"
  case "$s" in
    _a|_b) echo "$s" ;;
    *) echo "" ;;
  esac
}

flash_logical() {
  local p img size lptools httools target dev verity rs
  p="$1"; img="$AKHOME/$2"
  [ -f "$img" ] || return 0
  lptools="$AKHOME/tools/lptools_static"
  httools="$AKHOME/tools/httools_static"
  size="$(wc -c < "$img")"
  target="${p}${SLOT}"
  dev="/dev/block/mapper/${p}${SLOT}"
  verity="/dev/block/mapper/${p}-verity"
  rs="$(real_slot)"

  "$lptools" remove "${p}_ak3" >/dev/null 2>&1
  if "$lptools" create "${p}_ak3" "$size" >/dev/null 2>&1; then
    "$lptools" unmap "${p}_ak3" >/dev/null 2>&1
    "$lptools" map "${p}_ak3" >/dev/null 2>&1 || abort "map ${p}_ak3 failed. Aborting..."
    dd if="$img" of="/dev/block/mapper/${p}_ak3" 2>/dev/null || abort "write ${p}_ak3 failed. Aborting..."
    "$lptools" replace "${p}_ak3" "$target" >/dev/null 2>&1 || abort "replace ${target} failed. Aborting..."
    ui_print " " "Flashed ${p} (shadow replace)"
    return 0
  fi

  ui_print " " "create ${p}_ak3 failed; resizing ${target}..."
  if [ "$SLOT" = "$rs" ]; then
    "$httools" umount "$p" >/dev/null 2>&1
    [ -e "$verity" ] && "$lptools" unmap "${p}-verity" >/dev/null 2>&1
  fi
  [ -e "$dev" ] && "$lptools" unmap "$target" >/dev/null 2>&1
  "$lptools" resize "$target" "$size" >/dev/null 2>&1 || abort "resize ${target} failed. Aborting..."
  "$lptools" map "$target" >/dev/null 2>&1 || abort "map ${target} failed. Aborting..."
  dd if="$img" of="$dev" 2>/dev/null || abort "write ${p} failed. Aborting..."
  if [ "$SLOT" = "$rs" ]; then
    "$httools" mount "$p" >/dev/null 2>&1 || abort "mount ${p} failed. Aborting..."
  else
    "$lptools" unmap "$target" >/dev/null 2>&1
  fi
  ui_print " " "Flashed ${p} (resize)"
}
AK3EOF

    for f in $ARTIFACTS; do
        case "$f" in
            system_dlkm.img|vendor_dlkm.img)
                printf 'flash_logical %s %s\n' "${f%.img}" "$f" ;;
            *)
                printf 'flash_generic %s\n' "${f%.img}" ;;
        esac
    done >> "$stage/anykernel.sh"

    sh -n "$stage/anykernel.sh"
    test -f "$stage/META-INF/com/google/android/update-binary"
    test -f "$stage/tools/ak3-core.sh"
    test -f "$stage/tools/lptools_static"
    test -f "$stage/tools/httools_static"
    grep -q "^device.name1=" "$stage/anykernel.sh"
    grep -q "^flash_generic boot\$" "$stage/anykernel.sh"
    for f in $ARTIFACTS; do test -f "$stage/$f"; done

    zipfile="$DIST/AnyKernel3-${DEVICE}.zip"
    rm -f "$zipfile"
    ( cd "$stage" && zip -rq9 "$zipfile" . )
    unzip -t "$zipfile" >/dev/null
    echo "==> Built $zipfile"
fi

echo
echo "==> Done: $DIST"
ls -l "$DIST"
