FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Build a TI EdgeAI device-tree overlay that fixes the remote-core
# reserved-memory map so the vision-apps firmware (j7-*-fw) loads.
SRC_URI:append:beaglebone-ai64 = " \
    file://k3-j721e-edgeai-apps.dtso \
    file://k3-j721e-rtos-memory-map.dtsi \
    file://remoteproc-cdev.cfg \
"

KERNEL_DEVICETREE:append:beaglebone-ai64 = " ti/k3-j721e-edgeai-apps.dtbo"

# Enable the remoteproc character device (/dev/remoteprocN). TI's TIOVX/TIDL
# memory module (app_mem) opens /dev/remoteproc0 to translate dma_buf FDs into
# the remote cores' address space. The stock bb.org defconfig leaves
# CONFIG_REMOTEPROC_CDEV unset, so /dev/remoteproc0 never appears and every
# EdgeAI demo dies with "MEM: ERROR: /dev/remoteproc0 open failed" ->
# "Failed to translate dmaBufFd" -> TIDL init failure.
# Uses the same KERNEL_CONFIG_FRAGMENTS mechanism the base recipe already uses
# for no-fortify.cfg.
KERNEL_CONFIG_FRAGMENTS:append:beaglebone-ai64 = " ${WORKDIR}/remoteproc-cdev.cfg"

do_configure:append:beaglebone-ai64() {
	dt_dir="${S}/arch/arm64/boot/dts/ti"

	install -m 0644 "${WORKDIR}/k3-j721e-edgeai-apps.dtso" "$dt_dir/"
	install -m 0644 "${WORKDIR}/k3-j721e-rtos-memory-map.dtsi" "$dt_dir/"

	# Append the overlay to the dtb build list. Use a plain end-of-file
	# append (NOT sed against k3-j721e-beagleboneai64.dtb, which also matches
	# the multi-line "*-dtbs :=" continuation blocks and corrupts the Makefile).
	grep -q 'k3-j721e-edgeai-apps.dtbo' "$dt_dir/Makefile" || \
		printf '\ndtb-$(CONFIG_ARCH_K3) += k3-j721e-edgeai-apps.dtbo\n' >> "$dt_dir/Makefile"
}
