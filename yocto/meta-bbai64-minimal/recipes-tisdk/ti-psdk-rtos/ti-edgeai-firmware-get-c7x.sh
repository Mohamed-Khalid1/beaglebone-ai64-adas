#!/usr/bin/env bash
# ti-edgeai-firmware-get-c7x.sh
# Extract the version-matched C7x TIDL firmware (net 0x20250821, SDK 11.01.06) from
# a TI Processor SDK Linux EdgeAI 11.01 artifact and stage it for the bbappend.
#
# WHY: this blob is NOT in psdk_fw.git (every ref there is net 0x20250437). It ships
# only inside TI's full EdgeAI SDK 11.01 image. So you point this script at the SDK
# archive you downloaded; it finds + verifies the blob; you do NOT trust any URL
# blindly — the net-version check is mandatory and the bbappend re-checks at build.
#
# WHERE TO GET THE SDK 11.01 ARTIFACT (any ONE of these contains the blob):
#   TI landing page : https://www.ti.com/tool/PROCESSOR-SDK-J721E  (-> "EDGE AI")
#   Direct CDN dir  : https://software-dl.ti.com/jacinto7/esd/processor-sdk-linux-edgeai/TDA4VM/
#                     pick the 11.01.xx folder, then either:
#                       * the board image  *.wic.xz      (smallest that has firmware)
#                       * the SDK installer ti-processor-sdk-linux-edgeai-*-Install.bin
#                       * the prebuilt rootfs / tisdk-*-rootfs.tar.xz
#   NOTE: confirm the exact filename on the page (it changes per point release);
#   do not assume — copy the real link. The 11.01 release reports
#   "C7x Firmware Version 11_01_06_00" in its model run.log (net 0x20250821).
#
# USAGE:
#   ./ti-edgeai-firmware-get-c7x.sh <path-or-URL-to-SDK-archive>
#       <archive> may be a .wic.xz, .tar.xz, .tar.gz, .img, or .bin
#   Result on success: files/vx_app_rtos_linux_c7x_1.out (verified net 0x20250821)
set -euo pipefail

TARGET_REL="21 08 25 20"            # 0x20250821, little-endian first 4 bytes
FW_NAME="vx_app_rtos_linux_c7x_1.out"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/files/$FW_NAME"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ $# -ge 1 ] || { echo "usage: $0 <SDK-archive-path-or-URL>"; exit 2; }
SRC="$1"

# 1) Obtain the archive locally
if printf '%s' "$SRC" | grep -qE '^https?://'; then
    echo "[*] downloading $SRC"
    ARCH="$WORK/$(basename "$SRC")"
    wget -c -O "$ARCH" "$SRC"
else
    ARCH="$SRC"
    [ -f "$ARCH" ] || { echo "ERROR: not found: $ARCH"; exit 2; }
fi

# 2) Pull the firmware path out of whatever container it is.
#    Strategy: list the archive and extract just the one member to avoid unpacking
#    a multi-GB rootfs. Falls back to loop-mounting a .wic/.img.
echo "[*] searching for $FW_NAME inside $ARCH"
FOUND=""
case "$ARCH" in
  *.tar.xz|*.tar.gz|*.tgz|*.tar)
        MEMBER="$(tar tf "$ARCH" 2>/dev/null | grep -m1 "vision_apps_eaik/$FW_NAME" || true)"
        if [ -n "$MEMBER" ]; then
            tar xf "$ARCH" -C "$WORK" "$MEMBER"
            FOUND="$WORK/$MEMBER"
        fi
        ;;
  *.wic.xz|*.img.xz)
        echo "[*] decompressing image…"
        xz -dkc "$ARCH" > "$WORK/img.raw"
        ARCH="$WORK/img.raw" ;;& # fall through to image handling
  *.wic|*.img|"$WORK/img.raw")
        echo "[*] scanning partitions of image (needs sudo to loop-mount)…"
        LOOP="$(sudo losetup --show -fP "$ARCH")"
        for p in ${LOOP}p*; do
            MNT="$WORK/mnt"; mkdir -p "$MNT"
            sudo mount -o ro "$p" "$MNT" 2>/dev/null || continue
            HIT="$(find "$MNT" -path "*vision_apps_eaik/$FW_NAME" 2>/dev/null | head -1 || true)"
            if [ -n "$HIT" ]; then cp "$HIT" "$WORK/$FW_NAME"; FOUND="$WORK/$FW_NAME"; fi
            sudo umount "$MNT" 2>/dev/null || true
            [ -n "$FOUND" ] && break
        done
        sudo losetup -d "$LOOP" 2>/dev/null || true
        ;;
  *.bin)
        echo "ERROR: .Install.bin is an interactive installer. Run it once to a temp"
        echo "       dir, then re-run this script pointing at the unpacked"
        echo "       board-support/prebuilt-images/*.wic.xz or the rootfs tarball."
        exit 3 ;;
  *)    echo "ERROR: unsupported archive type: $ARCH"; exit 3 ;;
esac

[ -n "$FOUND" ] && [ -f "$FOUND" ] || { echo "ERROR: $FW_NAME not found in archive"; exit 4; }

# 3) MANDATORY net-version verify before staging.
VER="$(od -A n -t x1 -N 4 "$FOUND" | tr -s ' ' | sed 's/^ //;s/ $//')"
echo "[*] $FW_NAME net version first-4-bytes = $VER  (want $TARGET_REL = 0x20250821)"
if [ "$VER" != "$TARGET_REL" ]; then
    echo "ERROR: wrong net version. This SDK build does not contain the 0x20250821"
    echo "       firmware. Use a 11.01.06 EdgeAI SDK release. NOT staging."
    exit 5
fi

mkdir -p "$HERE/files"
cp -f "$FOUND" "$DEST"
echo "[OK] staged verified firmware -> $DEST"
echo "     ($(stat -c%s "$DEST") bytes, net 0x20250821)"
