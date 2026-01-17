#!/bin/bash

set -e

EXTRACT_OTA=../../../prebuilts/extract-tools/linux-x86/bin/ota_extractor
EXTRACT_EROFS=../../../prebuilts/erofs-utils/linux-x86/bin/extract.erofs
MKDTBOIMG=../../../system/libufdt/utils/src/mkdtboimg.py
UNPACKBOOTIMG=../../../system/tools/mkbootimg/unpack_bootimg.py
ROM_ZIP=$1

error_handler() {
    if [[ -d $extract_out ]]; then
        echo "Error detected, cleaning temporal working directory $extract_out"
        rm -rf "$extract_out"
    fi
}

trap error_handler ERR

function usage() {
    echo "Usage: ./extract-files.sh <rom-zip>"
    exit 1
}

function get_path() {
    echo "$extract_out/$1"
}

function unpackbootimg() {
    $UNPACKBOOTIMG "$@"
}

function extract_ota() {
    $EXTRACT_OTA "$@"
}

# Tool existence checks
if [[ ! -f $UNPACKBOOTIMG ]]; then
    echo "Missing $UNPACKBOOTIMG, are you on the correct directory?"
    exit 1
fi

if [[ ! -f $EXTRACT_OTA ]]; then
    echo "Missing $EXTRACT_OTA, are you on the correct directory and have built the ota_extractor target?"
    exit 1
fi

if [[ ! -f $EXTRACT_EROFS ]]; then
    echo "Missing $EXTRACT_EROFS, please ensure erofs-utils is built and available."
    exit 1
fi

if [[ -z $ROM_ZIP ]] || [[ ! -f $ROM_ZIP ]]; then
    usage
fi

# Clean and create needed directories
for dir in ./modules/vendor_dlkm ./modules/system_dlkm ./modules/vendor_boot ./images ./images/dtbs; do
    rm -rf "$dir"
    mkdir -p "$dir"
done

# Extract the OTA package
extract_out=$(mktemp -d)
echo "Using $extract_out as working directory"

echo "Extracting the payload from $ROM_ZIP"
unzip -q "$ROM_ZIP" payload.bin -d "$extract_out"

echo "Extracting OTA images"
extract_ota -payload "$extract_out/payload.bin" -output_dir "$extract_out" -partitions boot,dtbo,vendor_boot,vendor_dlkm,system_dlkm

# BOOT
echo "Extracting the kernel image from boot.img"
out="$extract_out/boot-out"
mkdir "$out"

echo "Extracting at $out"
unpackbootimg --boot_img "$(get_path boot.img)" --out "$out" --format mkbootimg

echo "Done. Copying the kernel"
cp "$out/kernel" ./images/kernel
echo "Done"

# VENDOR_BOOT
echo "Extracting the ramdisk kernel modules and DTB"
out="$extract_out/vendor_boot-out"
mkdir "$out"

echo "Extracting at $out"
unpackbootimg --boot_img "$(get_path vendor_boot.img)" --out "$out" --format mkbootimg

echo "Done. Extracting the ramdisk"
mkdir "$out/ramdisk"
unlz4 -c "$out/vendor_ramdisk00" > "$out/vendor_ramdisk"
cd "$out/ramdisk" && cpio -i -F "../vendor_ramdisk" &>/dev/null
cd - > /dev/null

echo "Copying all ramdisk modules"
while IFS= read -r -d '' module; do    cp "$module" ./modules/vendor_boot/
done < <(find "$out/ramdisk" \( -name "*.ko" -o -name "modules.load*" -o -name "modules.blocklist" \) -print0)

# VENDOR_DLKM
echo "Extracting the dlkm kernel modules"
out="$extract_out/vendor_dlkm"
mkdir -p "$out"

echo "Extracting at $out"
"$EXTRACT_EROFS" -i "$(get_path vendor_dlkm.img)" -o "$out"

echo "Done. Extracting the vendor dlkm"

echo "Copying all vendor dlkm modules"
while IFS= read -r -d '' module; do
    cp "$module" ./modules/vendor_dlkm/
done < <(find "$out/lib" \( -name "*.ko" -o -name "modules.load*" -o -name "modules.blocklist" \) -print0)

# SYSTEM_DLKM
echo "Extracting the dlkm kernel modules"
out="$extract_out/system_dlkm"
mkdir -p "$out"

echo "Extracting at $out"
"$EXTRACT_EROFS" -i "$(get_path system_dlkm.img)" -o "$out"

echo "Done. Extracting the system dlkm"

echo "Copying all system dlkm modules"
cp -r "$out/lib/modules"/6.1* ./modules/system_dlkm/ 2>/dev/null || true

# Extract DTBO and DTBs
echo "Extracting DTBO and DTBs"

curl -sSL "https://raw.githubusercontent.com/PabloCastellano/extract-dtb/master/extract_dtb/extract_dtb.py" > "${extract_out}/extract_dtb.py"

# Copy DTB
python3 "${extract_out}/extract_dtb.py" "${extract_out}/vendor_boot-out/dtb" -o "${extract_out}/dtbs" > /dev/null
find "${extract_out}/dtbs" -type f -name "*.dtb" -exec sh -c '
    for dtb; do
        cp "$dtb" ./images/dtbs/
        printf "  - dtbs/%s\n" "$(basename "$dtb")"
    done
' _ {} +

cp -f "${extract_out}/dtbo.img" ./images/dtbo.img
echo "Done"

# Add touch modules to vendor_boot for recovery
for module in xiaomi_touch.ko goodix_core.ko focaltech_touch.ko; do    if [[ -f ./modules/vendor_dlkm/"$module" ]]; then
        cp "./modules/vendor_dlkm/$module" ./modules/vendor_boot/
        echo "$module" >> ./modules/vendor_boot/modules.load.recovery
    fi
done

rm -rf "$extract_out"
echo "Extracted files successfully"
