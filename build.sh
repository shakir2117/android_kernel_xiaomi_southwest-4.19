#!/bin/bash
#
# lavender / SouthWest 4.19.325 kernel build script
#
# Target tree: pix106/android_kernel_xiaomi_southwest-4.19
# Branch:      main-dynamic-3.18.2   (retrofit dynamic partitions)
#
# This tree ships NO KernelSU and NO SUSFS, and has no manual hooks in
# fs/. So KernelSU-Next is added fresh and hooks via kprobes, which the
# tree supports (CONFIG_HAVE_KPROBES=y) but does not enable by default.
#
# Usage:
#   ./build.sh                  # STAGE 1: stock build, proves the base boots
#   ./build.sh --susfs          # STAGE 2: add KSU-Next + SUSFS
#   ./build.sh --susfs --clean  # wipe out/ first
#   ./build.sh --menuconfig     # inspect config before building
#   ./build.sh --no-package     # skip the AnyKernel3 zip
#
# Run STAGE 1 and flash it before ever running STAGE 2.

set -e

# ----------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------
DEFCONFIG="lavender_defconfig"
DEVICE="lavender"
JOBS="$(nproc --all)"

KERNEL_DIR="$(pwd)"
OUT="${KERNEL_DIR}/out"
TC_DIR="${TC_DIR:-${HOME}/toolchains/clang}"
AK3_DIR="${KERNEL_DIR}/AnyKernel3"

export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-builder}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-local}"

# susfs4ksu branch tracks the KERNEL version, not the Android version.
SUSFS_BRANCH="kernel-4.19"

# KernelSU-Next with SUSFS pre-merged, ported to 4.19.
KSUN_REPO="https://github.com/wshamroukh/KernelSU-Next-SUSFS-kernelv4.19"
KSUN_BRANCH="next-susfs"

# Where the driver gets dropped. This tree has no existing wiring, so the
# script adds the Kconfig source line and the Makefile obj line itself.
KSU_PATH="drivers/kernelsu"

# Files merged by hand in-tree; their hunks are stripped from the patch.
#   fs/proc/cmdline.c - CONFIG_INITRAMFS_IGNORE_SKIP_FLAG code occupies the
#                       same lines the SUSFS patch targets.
SKIP_PATCH_FILES="fs/proc/cmdline.c"

DO_SUSFS=0; DO_CLEAN=0; DO_MENUCONFIG=0; DO_PACKAGE=1

for arg in "$@"; do
    case "$arg" in
        --susfs)      DO_SUSFS=1 ;;
        --clean)      DO_CLEAN=1 ;;
        --menuconfig) DO_MENUCONFIG=1 ;;
        --no-package) DO_PACKAGE=0 ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

msg()  { echo -e "\n\033[1;32m>>> $*\033[0m"; }
warn() { echo -e "\033[1;33m !! $*\033[0m"; }
die()  { echo -e "\033[1;31m XX $*\033[0m"; exit 1; }

# ----------------------------------------------------------------------
# Sanity
# ----------------------------------------------------------------------
[ -f "Makefile" ] || die "Run this from the kernel source root."
[ -f "arch/arm64/configs/${DEFCONFIG}" ] || die "${DEFCONFIG} not found"

KVER="$(make kernelversion 2>/dev/null || echo unknown)"
msg "Kernel source version: ${KVER}"
case "${KVER}" in
    4.19.*) : ;;
    *) warn "Expected a 4.19.x tree; SUSFS_BRANCH=${SUSFS_BRANCH} may be wrong" ;;
esac

# ----------------------------------------------------------------------
# Toolchain
# ----------------------------------------------------------------------
if [ -x "${TC_DIR}/bin/clang" ]; then
    export PATH="${TC_DIR}/bin:${PATH}"
    msg "Using toolchain at ${TC_DIR}"
elif command -v clang >/dev/null 2>&1; then
    msg "Using clang already on PATH"
else
    msg "Fetching clang into ${TC_DIR}"
    mkdir -p "${TC_DIR}"; cd "${TC_DIR}"
    curl -LO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
    chmod +x antman
    ./antman -S
    ./antman --patch=glibc || true
    cd "${KERNEL_DIR}"
    export PATH="${TC_DIR}/bin:${PATH}"
fi

command -v clang >/dev/null || die "clang not on PATH"
msg "$(clang --version | head -1)"

# ----------------------------------------------------------------------
# KernelSU-Next + SUSFS  (STAGE 2 only)
# ----------------------------------------------------------------------
if [ "${DO_SUSFS}" = "1" ]; then
  if [ -f ".susfs_applied" ]; then
    msg "SUSFS already applied (.susfs_applied present) - skipping"
  else

    # ---- 1. Drop in the KSU driver ----------------------------------
    msg "Installing KernelSU-Next (${KSUN_BRANCH}) at ${KSU_PATH}"
    rm -rf .ksun_tmp "${KSU_PATH}"
    git clone --depth=1 -b "${KSUN_BRANCH}" "${KSUN_REPO}" .ksun_tmp
    [ -d ".ksun_tmp/kernel" ] || die "Expected kernel/ dir in ${KSUN_REPO}"
    cp -r .ksun_tmp/kernel "${KSU_PATH}"
    rm -rf .ksun_tmp

    [ -f "${KSU_PATH}/Kconfig" ]  || die "install failed: no Kconfig"
    grep -q "KSU_SUSFS" "${KSU_PATH}/Kconfig" \
        || die "${KSU_PATH}/Kconfig has no SUSFS options - wrong branch?"

    # ---- 2. Wire it into the build ----------------------------------
    # Unlike the S0NiX tree, this one has no kernelsu references at all,
    # so both lines have to be added. Without the Kconfig source line the
    # CONFIG_KSU_SUSFS_* symbols never register and SUSFS silently vanishes.
    if ! grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
        msg "Adding kernelsu to drivers/Kconfig"
        # insert before the final endmenu
        printf '%s\n' "$(sed '$ d' drivers/Kconfig)" > drivers/Kconfig.new
        printf '\nsource "drivers/kernelsu/Kconfig"\n\nendmenu\n' >> drivers/Kconfig.new
        mv drivers/Kconfig.new drivers/Kconfig
    fi
    grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig \
        || die "failed to add kernelsu to drivers/Kconfig"

    if ! grep -q 'CONFIG_KSU) += kernelsu/' drivers/Makefile; then
        msg "Adding kernelsu to drivers/Makefile"
        echo 'obj-$(CONFIG_KSU)		+= kernelsu/' >> drivers/Makefile
    fi
    grep -q 'CONFIG_KSU) += kernelsu/' drivers/Makefile \
        || die "failed to add kernelsu to drivers/Makefile"
    msg "Driver wired into drivers/Kconfig and drivers/Makefile"

    # ---- 3. SUSFS sources -------------------------------------------
    msg "Fetching susfs4ksu (${SUSFS_BRANCH})"
    rm -rf susfs4ksu
    git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git \
        -b "${SUSFS_BRANCH}" susfs4ksu

    msg "Copying SUSFS sources"
    cp susfs4ksu/kernel_patches/fs/* fs/
    cp susfs4ksu/kernel_patches/include/linux/* include/linux/

    # ---- 4. Kernel-side SUSFS patch ---------------------------------
    MAIN_PATCH="susfs4ksu/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"
    [ -f "${MAIN_PATCH}" ] || die "Missing ${MAIN_PATCH}"

    FILTERED="/tmp/susfs_filtered.patch"
    msg "Filtering patch (skipping: ${SKIP_PATCH_FILES})"
    SKIP_LIST="${SKIP_PATCH_FILES}" python3 - "${MAIN_PATCH}" > "${FILTERED}" <<'PY'
import os, sys

skip = set(os.environ.get("SKIP_LIST", "").split())
emit = True
kept, dropped = [], []

with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if line.startswith("diff --git "):
            hit = next((f for f in skip if f in line), None)
            emit = hit is None
            (dropped if hit else kept).append(hit or line.split()[-1])
        if emit:
            sys.stdout.write(line)

sys.stderr.write("   kept %d file diffs, dropped %d (%s)\n"
                 % (len(kept), len(dropped), ", ".join(dropped) or "none"))
PY

    msg "Applying 50_add_susfs_in_${SUSFS_BRANCH}.patch"
    set +e
    patch -p1 --no-backup-if-mismatch < "${FILTERED}"
    RC=$?
    set -e

    if [ "${RC}" != "0" ]; then
        warn "Patch failed. Rejected hunks:"
        find . -name '*.rej' | sed 's/^/    /'
        warn "Merge the change by hand and add the file to SKIP_PATCH_FILES,"
        warn "or append missing 'u64 android_kabi_reservedN;' struct members."
        exit 1
    fi

    for f in ${SKIP_PATCH_FILES}; do
        grep -q "susfs" "${f}" || die "${f} is in SKIP_PATCH_FILES but has no susfs code"
        echo "   verified pre-merged: ${f}"
    done

    touch .susfs_applied
    msg "SUSFS applied cleanly"
  fi
fi

# ----------------------------------------------------------------------
# Configure
# ----------------------------------------------------------------------
[ "${DO_CLEAN}" = "1" ] && { msg "Cleaning out/"; rm -rf "${OUT}"; }
mkdir -p "${OUT}"

MAKE_ARGS=(
    O="${OUT}" ARCH=arm64
    CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
)

# Without aarch64-linux-gnu-as, clang falls back to the host x86 assembler
# and dies with "/usr/bin/as: unrecognized option '-EL'" minutes in.
if [ "${USE_IAS}" = "1" ]; then
    msg "Using clang's integrated assembler (LLVM_IAS=1)"
    MAKE_ARGS+=(LLVM_IAS=1)
elif command -v aarch64-linux-gnu-as >/dev/null 2>&1; then
    msg "Using GNU as: $(aarch64-linux-gnu-as --version | head -1)"
else
    die "aarch64-linux-gnu-as not found.
   Install it:   apt-get install -y binutils-aarch64-linux-gnu
   Or re-run:    USE_IAS=1 ./build.sh"
fi

msg "Generating .config from ${DEFCONFIG}"
make "${MAKE_ARGS[@]}" "${DEFCONFIG}"

CFG="scripts/config --file ${OUT}/.config"

# -Werror turns new warnings into hard failures; panic-on-oops turns a
# readable oops into a silent bootloop. Both off for bring-up.
msg "Relaxing build-breaking options"
${CFG} --disable CC_WERROR
${CFG} --disable PANIC_ON_OOPS

if [ "${DO_SUSFS}" = "1" ]; then
    msg "Enabling KernelSU + SUSFS options"

    # This tree has no manual hooks in fs/, so KernelSU must hook via
    # kprobes. CONFIG_HAVE_KPROBES=y here but KPROBES itself ships off.
    ${CFG} --enable KPROBES
    ${CFG} --enable KSU
    ${CFG} --enable KSU_KPROBES_HOOK

    ${CFG} --enable KSU_SUSFS
    ${CFG} --enable KSU_SUSFS_SUS_PATH
    ${CFG} --enable KSU_SUSFS_SUS_MOUNT
    ${CFG} --enable KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
    ${CFG} --enable KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
    ${CFG} --enable KSU_SUSFS_SUS_KSTAT
    ${CFG} --enable KSU_SUSFS_TRY_UMOUNT
    ${CFG} --enable KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
    ${CFG} --enable KSU_SUSFS_SPOOF_UNAME
    ${CFG} --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
    ${CFG} --enable KSU_SUSFS_OPEN_REDIRECT
    ${CFG} --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
    ${CFG} --enable KSU_SUSFS_ENABLE_LOG        # keep on for the first boot
    ${CFG} --enable KSU_SUSFS_HAS_MAGIC_MOUNT

    # SUS_SU is unsupported on non-GKI.
    ${CFG} --disable KSU_SUSFS_SUS_SU
fi

make "${MAKE_ARGS[@]}" olddefconfig

[ "${DO_MENUCONFIG}" = "1" ] && make "${MAKE_ARGS[@]}" menuconfig

if [ "${DO_SUSFS}" = "1" ]; then
    msg "Verifying config"
    for opt in CONFIG_KPROBES CONFIG_KSU CONFIG_KSU_SUSFS; do
        grep -q "^${opt}=y" "${OUT}/.config" || die "${opt} did not stick"
        echo "   ${opt}=y"
    done
    grep -q "^CONFIG_KSU_SUSFS_SUS_SU=y" "${OUT}/.config" \
        && die "KSU_SUSFS_SUS_SU must be off on non-GKI"
    echo "   --- all KSU options ---"
    grep -E "^CONFIG_KSU" "${OUT}/.config" | sed 's/^/     /' || true
else
    msg "STAGE 1 build: stock kernel, no KernelSU, no SUSFS"
    grep -qE "^CONFIG_KSU=y" "${OUT}/.config" \
        && warn "CONFIG_KSU is set unexpectedly in a stock build"
fi

# ----------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------
msg "Building with ${JOBS} jobs"
START=$(date +%s)
make -j"${JOBS}" "${MAKE_ARGS[@]}"
END=$(date +%s)

IMAGE="${OUT}/arch/arm64/boot/Image.gz-dtb"
[ -f "${IMAGE}" ] || die "Image.gz-dtb not produced"
msg "Built in $(( (END-START)/60 ))m $(( (END-START)%60 ))s"

# ----------------------------------------------------------------------
# Package
# ----------------------------------------------------------------------
if [ "${DO_PACKAGE}" = "1" ]; then
    if [ ! -d "${AK3_DIR}" ]; then
        msg "Cloning AnyKernel3"
        git clone --depth=1 https://github.com/osm0sis/AnyKernel3 "${AK3_DIR}"
        rm -rf "${AK3_DIR}/.git"
        # Current AnyKernel3 uses UPPERCASE BLOCK= / IS_SLOT_DEVICE=.
        # Lowercase seds silently no-op and leave the omap placeholder,
        # which aborts at flash time.
        SUF=""; [ "${DO_SUSFS}" = "1" ] && SUF=" + KSU-Next + SUSFS"
        sed -i 's|^device.name1=.*|device.name1='"${DEVICE}"'|'          "${AK3_DIR}/anykernel.sh"
        sed -i 's|^kernel.string=.*|kernel.string=SouthWest'"${SUF}"' ('"${DEVICE}"')|' "${AK3_DIR}/anykernel.sh"
        sed -i 's|^BLOCK=.*|BLOCK=/dev/block/bootdevice/by-name/boot;|'  "${AK3_DIR}/anykernel.sh"
        sed -i 's|^IS_SLOT_DEVICE=.*|IS_SLOT_DEVICE=0;|'                 "${AK3_DIR}/anykernel.sh"

        grep -q "^BLOCK=/dev/block/bootdevice/by-name/boot;" "${AK3_DIR}/anykernel.sh" \
            || die "AnyKernel3 BLOCK= not set - check anykernel.sh variable names"
    fi

    cp "${IMAGE}" "${AK3_DIR}/"
    SUFFIX="-stock"; [ "${DO_SUSFS}" = "1" ] && SUFFIX="-susfs"
    ZIP="${DEVICE}-southwest${SUFFIX}-$(date +%Y%m%d-%H%M).zip"
    ( cd "${AK3_DIR}" && zip -r9 "../${ZIP}" . -x '*.zip' >/dev/null )
    msg "Packaged: ${KERNEL_DIR}/${ZIP}"
fi

if [ "${DO_SUSFS}" = "1" ]; then
cat <<'EOF'

STAGE 2 done
------------
  Flash the zip from recovery, then:

      adb shell uname -r
      adb shell su -c "dmesg | grep -i susfs"

  Install the KernelSU-Next manager APK - this kernel is KSU-Next.
  Modules in /data/adb/modules carry over.

  Parachute: fastboot flash boot boot-backup.img
EOF
else
cat <<'EOF'

STAGE 1 done
------------
  Flash this stock build FIRST and confirm it boots. This proves the
  SouthWest tree is compatible with your ROM before any SUSFS work.

      adb shell uname -r      # expect 4.19.325-SouthWest-v3.18.2-dynamic

  Boots  -> re-run with --susfs for stage 2.
  Hangs  -> this tree is not compatible either; stop here.

  Parachute: fastboot flash boot boot-backup.img
EOF
fi
