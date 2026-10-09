#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root on the forwarding VPS. Set ORIGIN_IP to the destination IPv4 address.
ORIGIN_IP=${ORIGIN_IP:?Set ORIGIN_IP to the destination server IPv4 address.}
PORTS=(443 8443 10000:60000)
BACKUP_DIR=

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

[[ $EUID -eq 0 ]] || die 'Run this script as root.'
[[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
. /etc/os-release
[[ $ID == ubuntu || $ID == debian ]] || die 'Only Ubuntu and Debian are supported.'

# Validate the address before it can enter an iptables-restore file.
[[ $ORIGIN_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'ORIGIN_IP must be an IPv4 address.'
IFS=. read -r -a octets <<< "$ORIGIN_IP"
for octet in "${octets[@]}"; do
    [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] || die 'Invalid ORIGIN_IP.'
    (( 10#$octet <= 255 )) || die 'Invalid ORIGIN_IP.'
done

if ! command -v ufw >/dev/null 2>&1; then
    log 'Installing UFW...'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
fi
for command in ip awk iptables-restore mktemp; do
    command -v "$command" >/dev/null 2>&1 || die "Required command missing: $command"
done

route=$(ip -4 route get "$ORIGIN_IP") || die "No route to $ORIGIN_IP."
[[ $route != local\ * ]] || die 'ORIGIN_IP is a local address; forwarding to this host is unsafe.'
WAN_IF=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$route")
[[ $WAN_IF =~ ^[a-zA-Z0-9_.:-]+$ ]] || die 'Cannot determine the outbound interface.'
log "Origin: $ORIGIN_IP; interface: $WAN_IF"

# If UFW must be enabled, ensure this SSH session can reconnect first.
SSH_PORT=${SSH_PORT:-}
if [[ -z $SSH_PORT && -n ${SSH_CONNECTION:-} ]]; then
    SSH_PORT=${SSH_CONNECTION##* }
fi
if [[ -n $SSH_PORT ]]; then
    [[ $SSH_PORT =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die 'Invalid SSH_PORT.'
elif ! LC_ALL=C ufw status | grep -q 'Status: active'; then
    die 'UFW is inactive and the SSH port is unknown. Re-run with SSH_PORT=22 (or your actual port).'
fi

BEFORE=/etc/ufw/before.rules
[[ -f $BEFORE ]] || die "$BEFORE does not exist."
BACKUP_DIR=$(mktemp -d /etc/ufw/3dp-forwarder-backup.XXXXXX)
cp -a "$BEFORE" "$BACKUP_DIR/before.rules"
if [[ -e /etc/sysctl.d/99-3dp-forwarder.conf ]]; then
    cp -a /etc/sysctl.d/99-3dp-forwarder.conf "$BACKUP_DIR/sysctl.conf"
fi
log "Backup: $BACKUP_DIR"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Remove only blocks from this installer or the published legacy installer.
# Leave every unrelated UFW table and rule intact.
awk -v origin="$ORIGIN_IP" '
function emit(    remove) {
    remove = 0
    if (table == "nat" && (index(block, "# BEGIN 3DP FORWARDER") || index(block, "# Проброс портов") ||
        (index(block, "-j DNAT --to-destination " origin) && index(block, "-m conntrack --ctstate DNAT -j MASQUERADE")))) remove = 1
    if (table == "filter" && index(block, "# Разрешаем пересылку для уже установленных соединений")) remove = 1
    if (table == "mangle" && index(block, "--tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu")) remove = 1
    if (!remove) printf "%s", block
    block = ""; table = ""
}
/^\*(nat|filter|mangle)$/ && table == "" { table = substr($0, 2); block = $0 "\n"; next }
table != "" { block = block $0 "\n"; if ($0 == "COMMIT") emit(); next }
/^# (BEGIN|END) 3DP FORWARDER$/ { next }
{ print }
END { if (table != "") { print "Unterminated UFW table" > "/dev/stderr"; exit 2 } }
' "$BEFORE" > "$tmp" || die 'Could not parse before.rules; no changes made.'

if grep -q '^\*nat$' "$tmp"; then
    die 'before.rules already contains unrelated NAT rules. Merge them manually; no changes made.'
fi
if grep -Eq '^DEFAULT_FORWARD_POLICY="?ACCEPT"?' /etc/default/ufw; then
    die 'UFW has a global ACCEPT forward policy. Set a restrictive policy after reviewing existing routes; no changes made.'
fi

{
    printf '%s\n' '*nat' '# BEGIN 3DP FORWARDER' ':PREROUTING ACCEPT [0:0]' ':POSTROUTING ACCEPT [0:0]'
    for proto in tcp udp; do
        for port in "${PORTS[@]}"; do
            printf '%s\n' "-A PREROUTING -i $WAN_IF -p $proto --dport $port -j DNAT --to-destination $ORIGIN_IP"
        done
    done
    # Masquerade only packets that underwent DNAT to the origin.
    printf '%s\n' "-A POSTROUTING -o $WAN_IF -d $ORIGIN_IP -m conntrack --ctstate DNAT -j MASQUERADE"
    printf '%s\n' 'COMMIT' '# END 3DP FORWARDER'
    cat "$tmp"
} > "${tmp}.new"
mv "${tmp}.new" "$tmp"

iptables-restore --test < "$tmp" || die 'Proposed UFW rules failed validation; no changes made.'

install -m 0644 "$tmp" "${BEFORE}.3dp-new"
mv "${BEFORE}.3dp-new" "$BEFORE"
printf '%s\n' 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-3dp-forwarder.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null

if [[ -n $SSH_PORT ]]; then
    ufw allow "${SSH_PORT}/tcp" comment 'Keep SSH access during forwarding setup'
fi

# Preserve DROP as UFW forwarding policy; only these destination ports are allowed.
for proto in tcp udp; do
    for port in "${PORTS[@]}"; do
        ufw route allow in on "$WAN_IF" out on "$WAN_IF" proto "$proto" to "$ORIGIN_IP" port "$port" comment '3DP forwarding'
    done
done

if LC_ALL=C ufw status | grep -q 'Status: active'; then
    ufw reload || die "UFW reload failed. Restore files from $BACKUP_DIR, then run ufw reload."
else
    ufw --force enable || die "UFW enable failed. Restore files from $BACKUP_DIR, then run ufw reload."
fi
[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || die 'IPv4 forwarding is disabled after UFW reload.'
log "Forwarding configured: TCP/UDP 443, 8443, 10000-60000 -> $ORIGIN_IP"
log "Backup: $BACKUP_DIR"
