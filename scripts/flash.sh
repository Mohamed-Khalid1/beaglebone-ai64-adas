#!/usr/bin/env bash
# flash.sh — Flash any BBAI-64 Yocto image to a microSD card using bmaptool.
#
# Usage:
#   ./flash.sh /dev/sdX [image-name]
#   ./flash.sh --list              # show available images in the deploy dir
#
# image-name examples:
#   bbai64-minimal-image   (default)
#   core-image-weston
#   tisdk-base-image
#
# The script looks for:
#   <DEPLOY_DIR>/<image-name>-beaglebone-ai64.rootfs.wic.xz
#   <DEPLOY_DIR>/<image-name>-beaglebone-ai64.rootfs.wic.bmap  (optional)
#
# Requirements: bmap-tools (sudo apt install bmap-tools)

set -euo pipefail

DEPLOY_DIR="/home/mohamedkhalid/tisdk/build/deploy-ti/images/beaglebone-ai64"
DEFAULT_IMAGE="bbai64-minimal-image"
MACHINE="beaglebone-ai64"

# ----------------------------------------------------------------
# --list: show available images and exit
# ----------------------------------------------------------------
if [[ "${1:-}" == "--list" ]]; then
    echo "Available images in ${DEPLOY_DIR}:"
    echo ""
    found=0
    for f in "${DEPLOY_DIR}"/*-"${MACHINE}".rootfs.wic.xz; do
        [[ -f "$f" ]] || continue
        basename "$f" | sed "s/-${MACHINE}\.rootfs\.wic\.xz//"
        found=1
    done
    if [[ $found -eq 0 ]]; then
        echo "  (none found — build one first with bitbake <image-name>)"
    fi
    exit 0
fi

# ----------------------------------------------------------------
# Argument check
# ----------------------------------------------------------------
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 /dev/sdX [image-name]"
    echo "       $0 --list"
    echo ""
    echo "Available block devices:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "^loop"
    exit 1
fi

TARGET="$1"
IMAGE_NAME="${2:-${DEFAULT_IMAGE}}"

IMAGE_WIC="${DEPLOY_DIR}/${IMAGE_NAME}-${MACHINE}.rootfs.wic.xz"
IMAGE_BMAP="${DEPLOY_DIR}/${IMAGE_NAME}-${MACHINE}.rootfs.wic.bmap"

# ----------------------------------------------------------------
# Sanity guards
# ----------------------------------------------------------------
if [[ ! -b "${TARGET}" ]]; then
    echo "ERROR: '${TARGET}' is not a block device."
    exit 1
fi

SYSTEM_DISKS=("/dev/sda" "/dev/nvme0n1")
for disk in "${SYSTEM_DISKS[@]}"; do
    if [[ "${TARGET}" == "${disk}" ]]; then
        echo "ERROR: '${TARGET}' looks like a system disk. Aborting."
        echo "       Double-check with: lsblk -d -o NAME,SIZE,MODEL,MOUNTPOINT"
        exit 1
    fi
done

if [[ ! -f "${IMAGE_WIC}" ]]; then
    echo "ERROR: Image not found:"
    echo "       ${IMAGE_WIC}"
    echo ""
    echo "Available images (run: $0 --list):"
    for f in "${DEPLOY_DIR}"/*-"${MACHINE}".rootfs.wic.xz; do
        [[ -f "$f" ]] || continue
        echo "  $(basename "$f" | sed "s/-${MACHINE}\.rootfs\.wic\.xz//")"
    done
    echo ""
    echo "Build a new one:"
    echo "  cd /home/mohamedkhalid/tisdk"
    echo "  source sources/oe-core/oe-init-build-env build"
    echo "  bitbake ${IMAGE_NAME}"
    exit 1
fi

# ----------------------------------------------------------------
# Install bmaptool if missing
# ----------------------------------------------------------------
if ! command -v bmaptool &>/dev/null; then
    echo "bmaptool not found — installing bmap-tools..."
    sudo apt-get install -y bmap-tools
fi

# ----------------------------------------------------------------
# Confirm with user
# ----------------------------------------------------------------
echo ""
echo "Image         : ${IMAGE_NAME}"
echo "File          : ${IMAGE_WIC}"
echo "Target device : ${TARGET}"
TARGET_SIZE=$(lsblk -nd -o SIZE "${TARGET}" 2>/dev/null || echo "unknown")
echo "Device size   : ${TARGET_SIZE}"
echo ""
echo "WARNING: ALL DATA ON ${TARGET} WILL BE ERASED."
read -rp "Type 'yes' to continue: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# Unmount any mounted partitions on the target
echo ""
echo "Unmounting partitions on ${TARGET}..."
for part in "${TARGET}"?* "${TARGET}"p?*; do
    if [[ -b "${part}" ]]; then
        sudo umount "${part}" 2>/dev/null || true
    fi
done

# ----------------------------------------------------------------
# Flash
# ----------------------------------------------------------------
echo ""
echo "Flashing ${IMAGE_NAME} — this may take a few minutes..."

if [[ -f "${IMAGE_BMAP}" ]]; then
    sudo bmaptool copy "${IMAGE_WIC}" --bmap "${IMAGE_BMAP}" "${TARGET}"
else
    echo "(No .bmap file found — falling back to plain copy, will be slower)"
    sudo bmaptool copy "${IMAGE_WIC}" "${TARGET}"
fi

sync
echo ""
echo "Done. Remove the microSD card and insert it into the BBAI-64."
echo ""
echo "Image flashed  : ${IMAGE_NAME}"
echo "SSH via USB-C  : ssh root@192.168.7.2   (empty password)"
echo "SSH via Ethernet: ssh root@<dhcp-ip>    (find IP with: ip addr show eth0)"
