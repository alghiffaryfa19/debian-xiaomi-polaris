# 仅在未设置环境变量时配置ccache
if [ -z "$CCACHE_DIR" ]; then
    export CCACHE_DIR="/home/runner/.ccache"
    export CCACHE_MAXSIZE="10G"
    export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
fi

# 确保ccache目录存在
mkdir -p "$CCACHE_DIR"

# 确保ccache优先使用clang
export CC="ccache clang"
export CXX="ccache clang++"
export AR="llvm-ar"
export NM="llvm-nm"
export OBJCOPY="llvm-objcopy"
export OBJDUMP="llvm-objdump"
export READELF="llvm-readelf"
export STRIP="llvm-strip"

git clone https://gitlab.com/sdm845-mainline/linux.git --branch sdm845/7.1-dev --depth 1 linux
cd linux

./scripts/kconfig/merge_config.sh ../sdm845.config ../sdm845_fragment.config ../misc.config ../pmos.config

make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1
_kernel_version="$(make kernelrelease -s)"


sed -i "s/Version:.*/Version: ${_kernel_version}/" ../linux-xiaomi-polaris/DEBIAN/control

PKGDIR=../linux-xiaomi-polaris
ARCH=arm64

# =========================
# Systemd fast shutdown config (wait n see)
# =========================
#mkdir -p $PKGDIR/etc/systemd/system.conf.d
#cat <<EOF > $PKGDIR/etc/systemd/system.conf.d/99-fast-shutdown.conf
#[Manager]
#DefaultTimeoutStopSec=10s
#DefaultTimeoutAbortSec=10s
#EOF

# =========================
# Install kernel images
# =========================
mkdir -p $PKGDIR/boot

install -Dm644 arch/$ARCH/boot/Image.gz \
    $PKGDIR/boot/Image.gz

install -Dm644 arch/$ARCH/boot/Image \
    $PKGDIR/boot/Image

install -Dm644 arch/$ARCH/boot/dts/qcom/sdm845-xiaomi-polaris.dtb \
    $PKGDIR/boot/sdm845-xiaomi-polaris.dtb

install -Dm644 .config \
    $PKGDIR/boot/config-${_kernel_version}

install -Dm644 System.map \
    $PKGDIR/boot/System.map-${_kernel_version}
    
chmod +x ../mkbootimg

cat arch/arm64/boot/Image.gz arch/arm64/boot/dts/qcom/sdm845-xiaomi-polaris.dtb > Image.gz-dtb_polaris

install -Dm644 Image.gz-dtb_polaris \
    $PKGDIR/boot/Image.gz-dtb_polaris

mv Image.gz-dtb_polaris zImage_polaris
../mkbootimg --kernel zImage_polaris --cmdline "root=PARTLABEL=userdata rootwait rw fsck.repair=yes" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_polaris_singleboot.img

ukify build \
  --linux=arch/arm64/boot/Image \
  --devicetree=arch/arm64/boot/dts/qcom/sdm845-xiaomi-polaris.dtb \
  --cmdline="console=tty0 root=PARTLABEL=linux rootwait rw" \
  --output=../bootaa64.efi

# =========================
# Build ESP IMG (FAT32) containing EFI/BOOT/bootaa64.efi
# =========================
ESP_IMG=../esp_polaris.img
EFI_FILE=../bootaa64.efi

# Calculate image size: EFI file size + 1MB overhead, rounded up to nearest MB
EFI_SIZE_KB=$(( ($(stat -c%s "$EFI_FILE") / 1024) + 1 ))
IMG_SIZE_KB=$(( EFI_SIZE_KB + 1024 ))

# Create empty image and format as FAT32
dd if=/dev/zero of="$ESP_IMG" bs=1K count="$IMG_SIZE_KB"
mformat -i "$ESP_IMG" -F ::

# Create EFI/BOOT directory structure and copy bootaa64.efi
mmd -i "$ESP_IMG" ::EFI
mmd -i "$ESP_IMG" ::EFI/BOOT
mcopy -i "$ESP_IMG" "$EFI_FILE" ::EFI/BOOT/bootaa64.efi

echo "ESP image created: $ESP_IMG"

make -j$(nproc) ARCH=arm64 CC="ccache clang" LLVM=1 INSTALL_MOD_PATH=../linux-xiaomi-polaris modules_install
rm ../linux-xiaomi-polaris/lib/modules/**/build

cd ..
git clone https://github.com/alghiffaryfa19/firmware-xiaomi-polaris polaris-firmaware
cd polaris-firmaware

cd ..
mkdir -p firmware-xiaomi-polaris/lib/firmware
cp -r polaris-firmaware/* firmware-xiaomi-polaris/usr/

git clone https://gitlab.com/sdm845-mainline/alsa-ucm-conf
mkdir -p alsa-xiaomi-polaris/usr/share/alsa
cp -r alsa-ucm-conf/ucm2 alsa-xiaomi-polaris/usr/share/alsa/

dpkg-deb --build --root-owner-group linux-xiaomi-polaris
dpkg-deb --build --root-owner-group firmware-xiaomi-polaris
dpkg-deb --build --root-owner-group alsa-xiaomi-polaris
