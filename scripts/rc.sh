#!/usr/bin/env bash
# rc.sh — robust reconnect + run a command on the BBAI-64 over USB gadget.
# Auto-recovers from USB drops. Usage: rc.sh '<remote command>'
IFACE=enxaabbcc000001
BLL="fe80::a8bb:ccff:fe00:2%${IFACE}"
SO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ServerAliveInterval=5"
ensure() {
  for i in $(seq 1 60); do
    lsusb 2>/dev/null | grep -q 0525 && break || sleep 3
  done
  sudo ip link set $IFACE up 2>/dev/null
  sudo ip addr add 192.168.7.1/24 dev $IFACE 2>/dev/null
  sudo sysctl -qw net.ipv4.conf.$IFACE.rp_filter=0 2>/dev/null
  sudo sysctl -qw net.ipv6.conf.$IFACE.disable_ipv6=0 2>/dev/null
  for i in $(seq 1 30); do
    ping6 -c1 -W2 $BLL >/dev/null 2>&1 && return 0 || sleep 2
  done
  return 1
}
ensure || { echo "BOARD_UNREACHABLE"; exit 1; }
# make sure board has its IPv4 too (best effort)
sshpass -p '' ssh $SO root@$BLL 'ip addr add 192.168.7.2/24 dev usb0 2>/dev/null' 2>/dev/null
# run the command via IPv6 (most reliable)
sshpass -p '' ssh $SO root@$BLL "$1"
