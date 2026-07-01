SUMMARY = "Minimal BeagleBone AI-64 image: console + SSH + Python3 + hardware tools"
DESCRIPTION = "Stripped-down image for BBAI-64 hardware bring-up and development. \
Includes dropbear SSH, Python 3, i2c-tools, devmem2, and DHCP networking via \
connman. No graphical stack, no EdgeAI packages."

LICENSE = "MIT"

# Pull in the arago image base (sets COMPATIBLE_MACHINE, WKS, etc.)
require recipes-core/images/arago-image.inc

# SSH via dropbear (lightweight). debug-tweaks (empty root password) is set
# in local.conf EXTRA_IMAGE_FEATURES.
IMAGE_FEATURES += "ssh-server-dropbear"

# ----------------------------------------------------------------
# Package list — only what is explicitly needed
# ----------------------------------------------------------------
IMAGE_INSTALL += "\
    bash \
    openssh-sftp-server \
    python3 \
    python3-core \
    python3-modules \
    i2c-tools \
    devmem2 \
    ethtool \
    util-linux \
    procps \
    iproute2 \
    connman \
    connman-client \
    kernel-modules \
    usb-gadget-net \
"

# ----------------------------------------------------------------
# Strip features that pull in heavy stacks
# ----------------------------------------------------------------
DISTRO_FEATURES:remove = "wayland opengl x11 vulkan opencl"
MACHINE_FEATURES:remove = "gpu"

IMAGE_ROOTFS_EXTRA_SPACE = "0"

export IMAGE_BASENAME = "bbai64-minimal-image"
