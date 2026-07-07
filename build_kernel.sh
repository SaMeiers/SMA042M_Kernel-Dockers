#!/bin/bash
# =============================================================================
# build_kernel.sh — SM-A042M (MT6765) kernel build pipeline
# =============================================================================
# Fixes vs original:
#   1. Sequential defconfig + merge_config (no -j race condition)
#   2. Removed KCFLAGS=-w (warnings are signals, not noise)
#   3. Removed ramdisk mkdir (was breaking AVB on some bootloaders)
#   4. CLANG_TRIPLE aligned with CROSS_COMPILE (both android)
#   5. Removed dead cp to source tree
#   6. Added pre-flight toolchain validation
#   7. Added .config artifact upload for debugging
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------
export ARCH=arm64
export RDIR="$(pwd)"
export KBUILD_BUILD_USER="SaMeiers"
export ANDROID_MAJOR_VERSION=r

TOOLCHAIN_GCC="${RDIR}/toolchains/aarch64-linux-android-4.9/bin/aarch64-linux-android-"
TOOLCHAIN_CC="${RDIR}/toolchains/clang-r383902/bin/clang"

OUT_DIR="${RDIR}/out"
BUILD_DIR="${RDIR}/build"

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
echo "[+] Pre-flight toolchain validation..."
if [ ! -x "${TOOLCHAIN_CC}" ]; then
    echo "ERROR: clang not found at ${TOOLCHAIN_CC}"
    echo "       Did the workflow's 'Download clang-r383902' step run?"
    exit 1
fi
if [ ! -x "${TOOLCHAIN_GCC}gcc" ]; then
    echo "ERROR: aarch64 gcc not found at ${TOOLCHAIN_GCC}gcc"
    echo "       Did the workflow's 'Download GCC 4.9 aarch64 toolchain' step run?"
    exit 1
fi

echo "    CC      : ${TOOLCHAIN_CC} ($(${TOOLCHAIN_CC} --version | head -1))"
echo "    GCC     : ${TOOLCHAIN_GCC}gcc ($(${TOOLCHAIN_GCC}gcc --version | head -1))"
echo ""

# -----------------------------------------------------------------------------
# Prepare output dirs
# -----------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"
rm -rf "${BUILD_DIR}" && mkdir -p "${BUILD_DIR}"

# NOTE: we do NOT pass -j here. -j only helps for the actual kernel build,
# not for kconfig invocations. Passing -j to defconfig/merge steps caused
# a race condition where custom.config ran before .config existed.
COMMON_ARGS=(
    -C "$(pwd)"
    O="${OUT_DIR}"
    ARCH=arm64
    CROSS_COMPILE="${TOOLCHAIN_GCC}"
    CC="${TOOLCHAIN_CC}"
    CLANG_TRIPLE="aarch64-linux-android-"
    CONFIG_SECTION_MISMATCH_WARN_ONLY=y
)

# -----------------------------------------------------------------------------
# 1. Generate base defconfig (creates out/.config)
# -----------------------------------------------------------------------------
echo "[+] Step 1/4: Generating a04e_defconfig..."
make "${COMMON_ARGS[@]}" a04e_defconfig

if [ ! -f "${OUT_DIR}/.config" ]; then
    echo "ERROR: .config was not created by a04e_defconfig"
    exit 1
fi

# -----------------------------------------------------------------------------
# 2. Merge custom.config fragment (sequential, after .config exists)
# -----------------------------------------------------------------------------
# We call merge_config.sh directly instead of `make custom.config` because:
#   - The %.config kconfig rule uses `yes "" | make oldconfig` which can fail
#     silently when KCFLAGS contains problematic values.
#   - We want explicit control over the merge order.
# After merge, we run olddefconfig (not oldconfig) to non-interactively
# resolve any new symbols added by the merge.
if [ -f "${RDIR}/arch/arm64/configs/custom.config" ]; then
    echo "[+] Step 2/4: Merging custom.config fragment..."
    cp "${OUT_DIR}/.config" "${OUT_DIR}/.config.before-merge"
    scripts/kconfig/merge_config.sh -m -O "${OUT_DIR}" \
        "${OUT_DIR}/.config" \
        "${RDIR}/arch/arm64/configs/custom.config"
    make "${COMMON_ARGS[@]}" olddefconfig
else
    echo "[!] Step 2/4: custom.config not found, skipping merge (baseline build)"
fi

# Sanity check: verify the merged symbols are actually present
echo "[+] Verifying custom.config symbols in .config..."
for sym in CONFIG_USER_NS CONFIG_CGROUP_DEVICE; do
    if ! grep -q "^${sym}=y" "${OUT_DIR}/.config"; then
        echo "WARNING: ${sym}=y was requested but is NOT in final .config"
        echo "         This usually means a Kconfig dependency is missing."
    else
        echo "    OK: ${sym}=y"
    fi
done
echo ""

# Save the final .config for debugging
cp "${OUT_DIR}/.config" "${BUILD_DIR}/dot-config-final"

# -----------------------------------------------------------------------------
# 3. Build the kernel
# -----------------------------------------------------------------------------
echo "[+] Step 3/4: Compiling kernel (this takes a while)..."
# NOW we can use -j for parallel compilation
make "${COMMON_ARGS[@]}" -j"$(nproc)"

KERNEL_IMAGE="${OUT_DIR}/arch/arm64/boot/Image.gz"
if [ ! -f "${KERNEL_IMAGE}" ]; then
    echo "ERROR: kernel image not built at ${KERNEL_IMAGE}"
    exit 1
fi

echo "    Built: ${KERNEL_IMAGE} ($(stat -c %s "${KERNEL_IMAGE}") bytes)"

# -----------------------------------------------------------------------------
# 4. Repack into boot.img using AIK-Linux
# -----------------------------------------------------------------------------
echo "[+] Step 4/4: Repacking boot.img..."
rm -f "${RDIR}/AIK-Linux/split_img/boot.img-kernel" "${RDIR}/AIK-Linux/boot.img"
cp "${KERNEL_IMAGE}" "${RDIR}/AIK-Linux/split_img/boot.img-kernel"

# IMPORTANT: do NOT create empty dirs in ramdisk. The stock ramdisk already
# has the structure init expects, and adding empty dirs can trip AVB hash
# verification on strict bootloaders (Samsung A/B with Android 12+).

cd "${RDIR}/AIK-Linux"
./repackimg.sh --nosudo

if [ ! -f "image-new.img" ]; then
    echo "ERROR: AIK did not produce image-new.img"
    exit 1
fi

mv image-new.img "${BUILD_DIR}/boot.img"
cd "${RDIR}"

# -----------------------------------------------------------------------------
# 5. Package into Odin-flashable .tar
# -----------------------------------------------------------------------------
echo "[+] Packaging Odin tar..."
cd "${BUILD_DIR}"
tar -cvf "SM-A042M-Magisk.tar" boot.img
rm -f boot.img
cd "${RDIR}"

echo ""
echo "============================================================"
echo "[i] Build Finished"
echo "    Output: ${BUILD_DIR}/SM-A042M-Magisk.tar"
echo "    Config: ${BUILD_DIR}/dot-config-final (for debugging)"
echo "============================================================"
