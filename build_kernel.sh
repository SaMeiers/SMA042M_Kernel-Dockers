#!/bin/bash
set -e

export ARCH=arm64
export RDIR="$(pwd)"
export KBUILD_BUILD_USER="SaMeiers"

export ANDROID_MAJOR_VERSION=r

export BUILD_CROSS_COMPILE="${RDIR}/toolchains/aarch64-linux-android-4.9/bin/aarch64-linux-android-"
export BUILD_CC="${RDIR}/toolchains/clang-r383902/bin/clang"

mkdir -p "${RDIR}/out"
rm -rf "${RDIR}/build" && mkdir -p "${RDIR}/build"

export ARGS="
-C $(pwd) \
O=$(pwd)/out \
-j$(nproc) \
ARCH=arm64 \
CROSS_COMPILE=${BUILD_CROSS_COMPILE} \
CC=${BUILD_CC} \
CLANG_TRIPLE=aarch64-linux-gnu- \
KCFLAGS=-w \
CONFIG_SECTION_MISMATCH_WARN_ONLY=y \
"

build_kernel(){
    make ${ARGS} clean && make ${ARGS} mrproper
    make ${ARGS} a04e_defconfig custom.config
    make ${ARGS} || exit 1
    cp out/arch/arm64/boot/Image.gz "$(pwd)/arch/arm64/boot/Image.gz"
}

build_boot() {
    rm -f "${RDIR}/AIK-Linux/split_img/boot.img-kernel" "${RDIR}/AIK-Linux/boot.img"
    cp "${RDIR}/out/arch/arm64/boot/Image.gz" "${RDIR}/AIK-Linux/split_img/boot.img-kernel"
    mkdir -p "${RDIR}/AIK-Linux/ramdisk"/{debug_ramdisk,dev,metadata,mnt,proc,second_stage_resources,sys}
    cd "${RDIR}/AIK-Linux" && ./repackimg.sh --nosudo && mv image-new.img "${RDIR}/build/boot.img"
}

build_tar(){
    cd "${RDIR}/build"
    tar -cvf "SM-A042M-Magisk.tar" boot.img && rm boot.img
    echo -e "\n[i] Build Finished..!\n" && cd "${RDIR}"
}

build_kernel
build_boot
build_tar
 
