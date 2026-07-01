SUMMARY = "USB gadget Ethernet (g_ether) with pinned MAC + static IP 192.168.7.2"
DESCRIPTION = "Loads g_ether at boot with FIXED MAC addresses (so the host \
interface name never changes), assigns 192.168.7.2/24 to usb0 via a systemd \
oneshot service bound to the usb0 device, and blacklists usb0 in connman."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

SRC_URI = "file://g_ether-load.conf \
           file://g_ether-options.conf \
           file://usb0-static-ip.service \
"

S = "${WORKDIR}"

PACKAGE_ARCH = "${MACHINE_ARCH}"

# Let the systemd class enable our service in the image at build time.
inherit systemd
SYSTEMD_SERVICE:${PN} = "usb0-static-ip.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    # 1. Load g_ether at boot
    install -d ${D}${sysconfdir}/modules-load.d
    install -m 0644 ${WORKDIR}/g_ether-load.conf ${D}${sysconfdir}/modules-load.d/g_ether.conf

    # 2. Pin the gadget MAC addresses (defeats per-boot MAC randomization)
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${WORKDIR}/g_ether-options.conf ${D}${sysconfdir}/modprobe.d/g_ether.conf

    # 3. systemd oneshot service that assigns usb0's static IP
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/usb0-static-ip.service ${D}${systemd_system_unitdir}/

    # 4. Blacklist usb0 in connman so it won't DHCP the gadget interface
    install -d ${D}${sysconfdir}/connman
    printf '[General]\nNetworkInterfaceBlacklist=usb0,vmnet0,vmnet1,vmnet8,vboxnet0\n' \
        > ${D}${sysconfdir}/connman/main.conf
}

FILES:${PN} = "\
    ${sysconfdir}/modules-load.d/g_ether.conf \
    ${sysconfdir}/modprobe.d/g_ether.conf \
    ${systemd_system_unitdir}/usb0-static-ip.service \
    ${sysconfdir}/connman/main.conf \
"
