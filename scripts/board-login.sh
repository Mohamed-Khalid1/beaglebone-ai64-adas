#!/usr/bin/env bash
# =============================================================================
# board-login.sh — One-command connect to the BeagleBone AI-64, ANY image.
#
# It tries, in order:
#   1. USB-C gadget  — board appears as enxXXXX, reachable at 192.168.7.2
#                      (works for bbai64-minimal-image, which sets the gadget up)
#   2. Ethernet/mDNS — board announces itself as beaglebone-ai64.local via
#                      avahi; we resolve it over the wired/Wi-Fi LAN
#                      (works for tisdk-base-image and any image running avahi)
# …then drops you into a root shell on whichever path succeeded.
#
# Usage:
#   ./board-login.sh            # auto: try USB-C, then Ethernet/mDNS
#   ./board-login.sh usb        # force the USB-C gadget path only
#   ./board-login.sh eth        # force the Ethernet/mDNS path only
#   ./board-login.sh <ip|host>  # connect straight to a known IP or hostname
# =============================================================================

# -e abort on error, -u abort on unset var, -o pipefail catch mid-pipe failures
set -euo pipefail

# ---- Tunables ---------------------------------------------------------------
HOST_IP=192.168.7.1               # host address on the USB-C point-to-point link
BOARD_IP=192.168.7.2              # board address on the USB-C link
SUBNET=192.168.7.0/24             # the /24 both USB ends share
BOARD_MDNS=beaglebone-ai64.local  # board's mDNS name (avahi advertises this)
SSH_USER=root                     # our images log in as root, empty password
USB_WAIT=12                       # seconds to wait for the USB gadget to appear

# SSH options reused everywhere:
#   StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null → ignore changing host key
#   PreferredAuthentications=password + PubkeyAuthentication=no → force empty password
#   ConnectTimeout=10 → fail fast instead of hanging
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o PreferredAuthentications=password -o PubkeyAuthentication=no \
         -o ConnectTimeout=10)

# =============================================================================
# open_shell <address> — exec an interactive root shell on the board.
# 'exec' replaces this script with ssh, so logging out returns you to your
# normal terminal. sshpass sends the empty password; otherwise press Enter.
# =============================================================================
open_shell() {
    local addr="$1"
    echo "[+] Connected path ready — opening shell on ${addr} (type 'exit' to return)"
    echo "-------------------------------------------------------------"
    if command -v sshpass &>/dev/null; then
        exec sshpass -p '' ssh "${SSHOPTS[@]}" "${SSH_USER}@${addr}"
    else
        echo "    (sshpass not installed — press Enter at the password prompt)"
        exec ssh "${SSHOPTS[@]}" "${SSH_USER}@${addr}"
    fi
}

# =============================================================================
# try_usb — attempt the USB-C gadget path. Echoes the reachable address on
# success (always 192.168.7.2), echoes nothing on failure. Never aborts.
# =============================================================================
try_usb() {
    # Detect the gadget iface. g_ether gets a RANDOM MAC each plug, so its name
    # (enxXXXXXXXXXXXX) changes every time — detect it, never hardcode it.
    local iface=""
    for ((i=1; i<=USB_WAIT; i++)); do
        iface=$(ip -br link | awk '/enx[0-9a-f]{12}/{print $1}' | head -1 || true)
        [[ -n "${iface}" ]] && break
        sleep 1
    done
    [[ -z "${iface}" ]] && { echo "" ; return; }
    echo "    [usb] gadget interface: ${iface}" >&2

    # Stop NetworkManager flushing our manual config on that iface.
    sudo nmcli device set "${iface}" managed no 2>/dev/null || true

    # Ensure an IPv6 link-local is generated (addr_gen_mode=0 = EUI-64) so the
    # IPv6 rescue path below can work.
    sudo sysctl -qw net.ipv6.conf."${iface}".disable_ipv6=0
    sudo sysctl -qw net.ipv6.conf."${iface}".addr_gen_mode=0

    # Give the host its IPv4, force the /24 out THIS iface (else it goes to the
    # Wi-Fi gateway), and relax reverse-path filtering so replies aren't dropped.
    sudo ip addr flush dev "${iface}"
    sudo ip link set "${iface}" down; sleep 1; sudo ip link set "${iface}" up; sleep 3
    sudo ip addr add "${HOST_IP}"/24 dev "${iface}"
    sudo ip route replace "${SUBNET}" dev "${iface}" src "${HOST_IP}"
    sudo sysctl -qw net.ipv4.conf."${iface}".rp_filter=0
    echo "    [usb] host configured: ${HOST_IP}/24 on ${iface}" >&2

    # Fast path: board already answers on IPv4.
    if ping -c1 -W2 -I "${iface}" "${BOARD_IP}" &>/dev/null; then
        echo "${BOARD_IP}"; return
    fi

    # Rescue path: board booted but usb0 has no IPv4. Reach it over IPv6
    # link-local (ff02::1 = all-nodes multicast), then set the IP ourselves.
    echo "    [usb] no IPv4 yet — trying IPv6 link-local rescue..." >&2
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

# =============================================================================
# try_eth — attempt the Ethernet path via mDNS. The board runs avahi-daemon and
# advertises beaglebone-ai64.local; resolve it over the LAN. Echoes a reachable
# address (hostname or IP) on success, nothing on failure. Never aborts.
# =============================================================================
try_eth() {
    # 1. Direct mDNS hostname resolution (host has mdns4_minimal in nsswitch).
    if getent hosts "${BOARD_MDNS}" &>/dev/null; then
        local ip
        ip=$(getent hosts "${BOARD_MDNS}" | awk '{print $1}' | head -1)
        echo "    [eth] ${BOARD_MDNS} resolved to ${ip}" >&2
        if ping -c1 -W2 "${ip}" &>/dev/null; then echo "${BOARD_MDNS}"; return; fi
    fi

    # 2. avahi-resolve as a second opinion (some setups skip nss mDNS).
    if command -v avahi-resolve-host-name &>/dev/null; then
        local ip
        ip=$(avahi-resolve-host-name -4 "${BOARD_MDNS}" 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "${ip}" ]] && ping -c1 -W2 "${ip}" &>/dev/null; then
            echo "    [eth] avahi resolved ${BOARD_MDNS} -> ${ip}" >&2
            echo "${ip}"; return
        fi
    fi

    # 3. Browse for any SSH service avahi is advertising on the LAN.
    if command -v avahi-browse &>/dev/null; then
        local ip
        ip=$(avahi-browse -rtp _ssh._tcp 2>/dev/null \
              | awk -F';' '/^=/ && $3=="IPv4"{print $8}' | head -1 || true)
        if [[ -n "${ip}" ]] && ping -c1 -W2 "${ip}" &>/dev/null; then
            echo "    [eth] found SSH service at ${ip} via avahi-browse" >&2
            echo "${ip}"; return
        fi
    fi
    echo ""
}

# =============================================================================
# MAIN — pick a path based on the (optional) argument.
# =============================================================================
MODE="${1:-auto}"
ADDR=""

case "${MODE}" in
    usb)
        echo "[*] Forcing USB-C gadget path..."
        ADDR=$(try_usb)
        ;;
    eth|ethernet|lan|mdns)
        echo "[*] Forcing Ethernet/mDNS path..."
        ADDR=$(try_eth)
        ;;
    auto)
        echo "[*] Auto-detecting transport (USB-C first, then Ethernet/mDNS)..."
        ADDR=$(try_usb)
        if [[ -z "${ADDR}" ]]; then
            echo "[*] USB-C gadget not reachable — trying Ethernet/mDNS..."
            ADDR=$(try_eth)
        fi
        ;;
    *)
        # Treat the argument as a literal IP or hostname.
        echo "[*] Connecting directly to '${MODE}'..."
        ADDR="${MODE}"
        ;;
esac

if [[ -z "${ADDR}" ]]; then
    echo ""
    echo "ERROR: Could not reach the board on any path."
    echo ""
    echo "  USB-C gadget (192.168.7.2):"
    echo "    • Only bbai64-minimal-image sets the gadget up. tisdk-base-image does NOT,"
    echo "      so for that image use Ethernet."
    echo "    • Check:  lsusb | grep 0525:a4a2"
    echo ""
    echo "  Ethernet (beaglebone-ai64.local):"
    echo "    • Plug an RJ-45 cable into the board and your LAN/router."
    echo "    • The board runs avahi and gets a DHCP lease; give it ~20s after boot."
    echo "    • Check:  ping6 -c2 ${BOARD_MDNS}    or    avahi-browse -art | grep -i beagle"
    echo ""
    echo "  Current host USB devices:"
    lsusb 2>/dev/null | grep -v 'root hub' | sed 's/^/      /'
    exit 1
fi

open_shell "${ADDR}"
