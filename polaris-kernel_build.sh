#!/bin/bash
set -e

# ============================================================
# Arguments
# ============================================================

KERNEL_VERSION="${1:-7.1.0}"

# GitHub Actions mengirimkan workspace sebagai argument kedua.
# Jika tidak diberikan, gunakan lokasi script.
ROOT_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

echo "=========================================="
echo " Xiaomi Polaris Kernel Build"
echo "=========================================="
echo "Kernel version : $KERNEL_VERSION"
echo "Root directory : $ROOT_DIR"
echo "Current dir    : $(pwd)"
echo "=========================================="

# Pastikan ROOT_DIR benar
if [ ! -d "$ROOT_DIR" ]; then
    echo "ERROR: ROOT_DIR tidak ditemukan:"
    echo "$ROOT_DIR"
    exit 1
fi

cd "$ROOT_DIR"

echo "Working directory:"
pwd


# ============================================================
# ccache
# ============================================================

# Jika CCACHE_DIR belum diset, gunakan default
if [ -z "$CCACHE_DIR" ]; then
    export CCACHE_DIR="/home/runner/.ccache"
    export CCACHE_MAXSIZE="10G"
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
fi

mkdir -p "$CCACHE_DIR"

# Pastikan ccache menggunakan clang
export CC="ccache clang"
export CXX="ccache clang++"

export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export READELF="llvm-readelf"
export STRIP="llvm-strip"

export PATH="/usr/lib/ccache:$PATH"

echo ""
echo "=========================================="
echo " ccache"
echo "=========================================="

ccache --version || true
ccache --show-config || true


# ============================================================
# Check source package
# ============================================================

echo ""
echo "=========================================="
echo " Checking package source"
echo "=========================================="

echo "--- firmware package ---"

if [ ! -f "$ROOT_DIR/firmware-xiaomi-polaris/DEBIAN/control" ]; then
    echo "ERROR:"
    echo "$ROOT_DIR/firmware-xiaomi-polaris/DEBIAN/control"
    echo "tidak ditemukan!"
    exit 1
fi

echo "OK: firmware-xiaomi-polaris/DEBIAN/control"


echo "--- ALSA package ---"

if [ ! -f "$ROOT_DIR/alsa-xiaomi-polaris/DEBIAN/control" ]; then
    echo "ERROR:"
    echo "$ROOT_DIR/alsa-xiaomi-polaris/DEBIAN/control"
    echo "tidak ditemukan!"
    exit 1
fi

echo "OK: alsa-xiaomi-polaris/DEBIAN/control"


echo "--- kernel package ---"

if [ ! -f "$ROOT_DIR/linux-xiaomi-polaris/DEBIAN/control" ]; then
    echo "ERROR:"
    echo "$ROOT_DIR/linux-xiaomi-polaris/DEBIAN/control"
    echo "tidak ditemukan!"
    exit 1
fi

echo "OK: linux-xiaomi-polaris/DEBIAN/control"


# ============================================================
# Clone Linux kernel
# ============================================================

echo ""
echo "=========================================="
echo " Clone Linux kernel"
echo "=========================================="

rm -rf "$ROOT_DIR/linux"

git clone \
    https://gitlab.com/sdm845-mainline/linux.git \
    --branch sdm845/7.1-dev \
    --depth 1 \
    "$ROOT_DIR/linux"

cd "$ROOT_DIR/linux"

echo ""
echo "Kernel source:"
pwd


# ============================================================
# Merge kernel config
# ============================================================

echo ""
echo "=========================================="
echo " Merge kernel config"
echo "=========================================="

./scripts/kconfig/merge_config.sh \
    "$ROOT_DIR/sdm845.config" \
    "$ROOT_DIR/sdm845_fragment.config" \
    "$ROOT_DIR/misc.config" \
    "$ROOT_DIR/pmos.config"

echo ""
echo "Running olddefconfig..."

make \
    ARCH=arm64 \
    LLVM=1 \
    olddefconfig


# ============================================================
# Build kernel
# ============================================================

echo ""
echo "=========================================="
echo " Build kernel"
echo "=========================================="

make \
    -j"$(nproc)" \
    ARCH=arm64 \
    CC="ccache clang" \
    LLVM=1

echo ""
echo "Kernel build completed."


# ============================================================
# Kernel release
# ============================================================

_kernel_version="$(make kernelrelease -s)"

echo ""
echo "Kernel release:"
echo "$_kernel_version"


# ============================================================
# Update Debian package version
# ============================================================

echo ""
echo "=========================================="
echo " Update Debian package"
echo "=========================================="

sed -i \
    "s/^Version:.*/Version: ${_kernel_version}/" \
    "$ROOT_DIR/linux-xiaomi-polaris/DEBIAN/control"

echo ""
echo "Updated:"
grep "^Version:" "$ROOT_DIR/linux-xiaomi-polaris/DEBIAN/control"


# ============================================================
# Kernel package directory
# ============================================================

PKGDIR="$ROOT_DIR/linux-xiaomi-polaris"
ARCH=arm64


# ============================================================
# Systemd fast shutdown config
# ============================================================

# mkdir -p "$PKGDIR/etc/systemd/system.conf.d"

# cat <<EOF > "$PKGDIR/etc/systemd/system.conf.d/99-fast-shutdown.conf"
# [Manager]
# DefaultTimeoutStopSec=10s
# DefaultTimeoutAbortSec=10s
# EOF


# ============================================================
# Install kernel images
# ============================================================

echo ""
echo "=========================================="
echo " Install kernel files"
echo "=========================================="

mkdir -p "$PKGDIR/boot"

if [ -f arch/arm64/boot/Image.gz ]; then
    echo "Using compressed kernel: Image.gz"
    install -m 0644 \
        arch/arm64/boot/Image.gz \
        "$PKGDIR/boot/Image.gz"
elif [ -f arch/arm64/boot/Image ]; then
    echo "Using uncompressed kernel: Image"
    install -m 0644 \
        arch/arm64/boot/Image \
        "$PKGDIR/boot/Image"
else
    echo "ERROR: No ARM64 kernel image found!"
    find arch/arm64/boot -maxdepth 1 -type f -ls
    exit 1
fi

install -Dm644 \
    arch/$ARCH/boot/dts/qcom/sdm845-xiaomi-polaris.dtb \
    "$PKGDIR/boot/sdm845-xiaomi-polaris.dtb"

install -Dm644 \
    .config \
    "$PKGDIR/boot/config-${_kernel_version}"

install -Dm644 \
    System.map \
    "$PKGDIR/boot/System.map-${_kernel_version}"


# ============================================================
# Create Image.gz + DTB
# ============================================================

echo ""
echo "=========================================="
echo " Create Image.gz-dtb"
echo "=========================================="

chmod +x "$ROOT_DIR/mkbootimg"

KERNEL_IMAGE=""

if [ -f arch/arm64/boot/Image.gz ]; then
    KERNEL_IMAGE="arch/arm64/boot/Image.gz"
elif [ -f arch/arm64/boot/Image ]; then
    KERNEL_IMAGE="arch/arm64/boot/Image"
else
    echo "ERROR: Kernel image not found"
    exit 1
fi

echo "Kernel image: $KERNEL_IMAGE"

cat \
    "$KERNEL_IMAGE" \
    arch/arm64/boot/dts/qcom/sdm845-xiaomi-polaris.dtb \
    > "$ROOT_DIR/Image-dtb_polaris"

install -Dm644 \
    "$ROOT_DIR/Image-dtb_polaris" \
    "$PKGDIR/boot/Image-dtb_polaris"

mv \
    "$ROOT_DIR/Image-dtb_polaris" \
    "$ROOT_DIR/zImage_polaris"


# ============================================================
# Create boot.img
# ============================================================

echo ""
echo "=========================================="
echo " Create boot.img"
echo "=========================================="

"$ROOT_DIR/mkbootimg" \
    --kernel "$ROOT_DIR/zImage_polaris" \
    --cmdline "console=ttyMSM0,115200 earlycon loglevel=7 root=/dev/disk/by-partlabel/userdata rootwait rw" \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --tags_offset 0x01e00000 \
    --pagesize 4096 \
    --id \
    -o "$ROOT_DIR/boot.img"


# ============================================================
# Create UKI
# ============================================================

echo ""
echo "=========================================="
echo " Create bootaa64.efi"
echo "=========================================="

ukify build \
    --linux=arch/arm64/boot/Image \
    --devicetree=arch/arm64/boot/dts/qcom/sdm845-xiaomi-polaris.dtb \
    --cmdline="console=tty0 root=PARTLABEL=linux rootwait rw" \
    --output="$ROOT_DIR/bootaa64.efi"


# ============================================================
# Build ESP IMG
# ============================================================

echo ""
echo "=========================================="
echo " Build ESP image"
echo "=========================================="

ESP_IMG="$ROOT_DIR/esp_polaris.img"
EFI_FILE="$ROOT_DIR/bootaa64.efi"

EFI_SIZE_KB=$(( ($(stat -c%s "$EFI_FILE") / 1024) + 1 ))

IMG_SIZE_KB=$(( EFI_SIZE_KB + 1024 ))

echo "EFI size : ${EFI_SIZE_KB} KB"
echo "IMG size : ${IMG_SIZE_KB} KB"

dd \
    if=/dev/zero \
    of="$ESP_IMG" \
    bs=1K \
    count="$IMG_SIZE_KB"

mformat \
    -i "$ESP_IMG" \
    -F ::

mmd \
    -i "$ESP_IMG" \
    ::EFI

mmd \
    -i "$ESP_IMG" \
    ::EFI/BOOT

mcopy \
    -i "$ESP_IMG" \
    "$EFI_FILE" \
    ::EFI/BOOT/bootaa64.efi

echo "ESP image created:"
echo "$ESP_IMG"


# ============================================================
# Install kernel modules
# ============================================================

echo ""
echo "=========================================="
echo " Install kernel modules"
echo "=========================================="

make \
    -j"$(nproc)" \
    ARCH=arm64 \
    CC="ccache clang" \
    LLVM=1 \
    INSTALL_MOD_PATH="$PKGDIR" \
    modules_install


# Remove build symlink/directory
rm -rf "$PKGDIR/lib/modules/"*/build


# ============================================================
# Return to repository root
# ============================================================

cd "$ROOT_DIR"

echo ""
echo "=========================================="
echo " Repository root"
echo "=========================================="

pwd


# ============================================================
# Firmware
# ============================================================

echo ""
echo "=========================================="
echo " Build firmware package"
echo "=========================================="

rm -rf "$ROOT_DIR/polaris-firmware"

git clone \
    https://github.com/alghiffaryfa19/firmware-xiaomi-polaris \
    "$ROOT_DIR/polaris-firmware"

# Copy seluruh isi repository firmware ke root package.
# Repository sudah memiliki lib/firmware.
mkdir -p "$ROOT_DIR/firmware-xiaomi-polaris/usr/lib/firmware"

cp -a \
  "$ROOT_DIR/polaris-firmware/lib/firmware/." \
  "$ROOT_DIR/firmware-xiaomi-polaris/usr/lib/firmware/"

echo ""
echo "Firmware package structure:"
find "$ROOT_DIR/firmware-xiaomi-polaris" -maxdepth 3 -print


# ============================================================
# ALSA UCM
# ============================================================

echo ""
echo "=========================================="
echo " Build ALSA package"
echo "=========================================="

rm -rf "$ROOT_DIR/alsa-ucm-conf"

git clone \
    https://gitlab.com/sdm845-mainline/alsa-ucm-conf \
    "$ROOT_DIR/alsa-ucm-conf"


mkdir -p \
    "$ROOT_DIR/alsa-xiaomi-polaris/usr/share/alsa"


cp -a \
    "$ROOT_DIR/alsa-ucm-conf/ucm2" \
    "$ROOT_DIR/alsa-xiaomi-polaris/usr/share/alsa/"


# ============================================================
# Verify package structures
# ============================================================

echo ""
echo "=========================================="
echo " Verify Debian packages"
echo "=========================================="

echo ""
echo "--- linux-xiaomi-polaris ---"
find "$ROOT_DIR/linux-xiaomi-polaris" \
    -maxdepth 3 \
    -print

echo ""
echo "--- firmware-xiaomi-polaris ---"
find "$ROOT_DIR/firmware-xiaomi-polaris" \
    -maxdepth 3 \
    -print

echo ""
echo "--- alsa-xiaomi-polaris ---"
find "$ROOT_DIR/alsa-xiaomi-polaris" \
    -maxdepth 3 \
    -print


echo ""
echo "Checking control files..."

test -f \
    "$ROOT_DIR/linux-xiaomi-polaris/DEBIAN/control"

test -f \
    "$ROOT_DIR/firmware-xiaomi-polaris/DEBIAN/control"

test -f \
    "$ROOT_DIR/alsa-xiaomi-polaris/DEBIAN/control"

echo "All control files OK."


# ============================================================
# Build Debian packages
# ============================================================

echo ""
echo "=========================================="
echo " Build Debian packages"
echo "=========================================="

dpkg-deb \
    --build \
    --root-owner-group \
    "$ROOT_DIR/linux-xiaomi-polaris"

dpkg-deb \
    --build \
    --root-owner-group \
    "$ROOT_DIR/firmware-xiaomi-polaris"

dpkg-deb \
    --build \
    --root-owner-group \
    "$ROOT_DIR/alsa-xiaomi-polaris"


# ============================================================
# Copy resulting packages to root
# ============================================================

echo ""
echo "=========================================="
echo " Copy packages"
echo "=========================================="

echo "Packages created:"

ls -lh \
    "$ROOT_DIR"/*.deb \
    2>/dev/null || true


# ============================================================
# Cleanup
# ============================================================

rm -rf \
    "$ROOT_DIR/polaris-firmware" \
    "$ROOT_DIR/alsa-ucm-conf" \
    "$ROOT_DIR/linux"


# ============================================================
# ccache statistics
# ============================================================

echo ""
echo "=========================================="
echo " ccache statistics"
echo "=========================================="

ccache --show-stats || true


echo ""
echo "=========================================="
echo " BUILD COMPLETE"
echo "=========================================="
