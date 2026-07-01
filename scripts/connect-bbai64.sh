#!/usr/bin/env bash
# connect-bbai64.sh — Prepare a connection to the BeagleBone AI-64 (ANY image)
# WITHOUT opening a shell. It detects the transport, configures the host if
# needed, then prints the exact ssh command to use.
#
#   1. USB-C gadget  — board at 192.168.7.2 (bbai64-minimal-image)
#   2. Ethernet/mDNS — board as beaglebone-ai64.local (tisdk-base-image, etc.)
#
# Usage:
#   ./connect-bbai64.sh         # auto-detect, then: ssh root@<printed-address>
#   ./connect-bbai64.sh usb     # force USB-C gadget path
#   ./connect-bbai64.sh eth     # force Ethernet/mDNS path

set -euo pipefail

HOST_IP=192.168.7.1
BOARD_IP=192.168.7.2
SUBNET=192.168.7.0/24
BOARD_MDNS=beaglebone-ai64.local
SSH_USER=root
USB_WAIT=12

SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o PreferredAuthentications=password -o PubkeyAuthentication=no \
         -o ConnectTimeout=10)

# Try the USB-C gadget path; echo 192.168.7.2 on success, nothing on failure.
try_usb() {
    local iface=""
    for ((i=1; i<=USB_WAIT; i++)); do
        iface=$(ip -br link | awk '/enx[0-9a-f]{12}/{print $1}' | head -1 || true)
        [[ -n "${iface}" ]] && break
        sleep 1
    done
    [[ -z "${iface}" ]] && { echo "" ; return; }
    echo "    [usb] gadget interface: ${iface}" >&2

    sudo nmcli device set "${iface}" managed no 2>/dev/null || true
    sudo sysctl -qw net.ipv6.conf."${iface}".disable_ipv6=0
    sudo sysctl -qw net.ipv6.conf."${iface}".addr_gen_mode=0
    sudo ip addr flush dev "${iface}"
    sudo ip link set "${iface}" down; sleep 1; sudo ip link set "${iface}" up; sleep 3
    sudo ip addr add "${HOST_IP}"/24 dev "${iface}"
    sudo ip route replace "${SUBNET}" dev "${iface}" src "${HOST_IP}"
    sudo sysctl -qw net.ipv4.conf."${iface}".rp_filter=0
    echo "    [usb] host configured: ${HOST_IP}/24 on ${iface}" >&2

    if ping -c1 -W2 -I "${iface}" "${BOARD_IP}" &>/dev/null; then
        echo "${BOARD_IP}"; return
    fi

    # IPv6 link-local rescue: discover the board, set its usb0 IP remotely.
    local host_ll board_ll
    host_ll=$(ip -6 addr show dev "${iface}" scope link | awk '/inet6/{print $2}' | cut -d/ -f1)
    board_ll=$(ping6 -c4 -W2 "ff02::1%${iface}" 2>/dev/null \
                | awk -F'from ' '/bytes from/{print $2}' | cut -d% -f1 \
                | sort -u | grep -v "^${host_ll}$" | head -1 || true)
    [[ -z "${board_ll}" ]] && { echo "" ; return; }
    echo "    [usb] board link-local: ${board_ll}" >&2
    if command -v sshpass &>/dev/null; then
        sshpass -p '' ssh "${SSHOPTS[@]}" "${SSH_USER}@${board_ll}%${iface}" \
            "ip addr add ${BOARD_IP}/24 dev usb0 2>/dev/null; ip link set usb0 up" || true
    else
        ssh "${SSHOPTS[@]}" "${SSH_USER}@${board_ll}%${iface}" \
            "ip addr add ${BOARD_IP}/24 dev usb0 2>/dev/null; ip link set usb0 up" || true
    fi
    ping -c2 -W2 "${BOARD_IP}" &>/dev/null && { echo "${BOARD_IP}"; return; }
    echo ""
}

# Try the Ethernet/mDNS path; echo a reachable host/IP on success.
try_eth() {
    if getent hosts "${BOARD_MDNS}" &>/dev/null; then
        local ip; ip=$(getent hosts "${BOARD_MDNS}" | awk '{print $1}' | head -1)
        echo "    [eth] ${BOARD_MDNS} -> ${ip}" >&2
        ping -c1 -W2 "${ip}" &>/dev/null && { echo "${BOARD_MDNS}"; return; }
    fi
    if command -v avahi-resolve-host-name &>/dev/null; then
        local ip; ip=$(avahi-resolve-host-name -4 "${BOARD_MDNS}" 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "${ip}" ]] && ping -c1 -W2 "${ip}" &>/dev/null; then echo "${ip}"; return; fi
    fi
    echo ""
}

MODE="${1:-auto}"
ADDR=""
case "${MODE}" in
    usb)            ADDR=$(try_usb) ;;
    eth|ethernet|lan|mdns) ADDR=$(try_eth) ;;
    auto)
        ADDR=$(try_usb)
        [[ -z "${ADDR}" ]] && ADDR=$(try_eth)
        ;;
    *) ADDR="${MODE}" ;;
esac

if [[ -z "${ADDR}" ]]; then
    echo "ERROR: Board not reachable over USB-C or Ethernet/mDNS."
    echo "  • USB-C: lsusb | grep 0525:a4a2   (only bbai64-minimal-image sets it up)"
    echo "  • Ethernet: plug in RJ-45, then  ping6 -c2 ${BOARD_MDNS}"
    exit 1
fi

echo ""
echo "[+] Board reachable. Connect with:"
echo "      ssh ${SSH_USER}@${ADDR}            # empty password"
echo "    or for a no-host-key-prompt session:"
echo "      ssh ${SSHOPTS[*]} ${SSH_USER}@${ADDR}"
