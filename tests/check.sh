#!/usr/bin/env bash
# Local checks only: no real firewall, sysctl or traffic-control changes.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./forwarding-install.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for address in 0.0.0.0 192.0.2.2 203.0.113.10 255.255.255.255; do
    valid_ipv4 "$address" || fail "Valid IPv4 rejected: $address"
done
for address in '' false YOUR_ORIGIN_IP 1.2.3 1.2.3.4.5 256.1.2.3 01.2.3.4 '1.2.3.4;reboot' '1.2.3.4 ' '1.2.3.-4'; do
    if valid_ipv4 "$address"; then fail "Invalid IPv4 accepted: $address"; fi
done
for port in 22 2222 9999 60001 65535 00022; do
    (check_ssh_port "$port") || fail "Safe SSH port rejected: $port"
done
for port in 0 443 8443 10000 60000 65536 -1 abc ''; do
    if (check_ssh_port "$port") 2>/dev/null; then fail "Unsafe SSH port accepted: $port"; fi
done

write_forwarding_rules 203.0.113.10 eth0 192.0.2.2 > "$work/rules"
[[ $(grep -c '^-A PREROUTING ' "$work/rules") == 6 ]] || fail 'DNAT rule count'
[[ $(grep -c '^-A POSTROUTING ' "$work/rules") == 6 ]] || fail 'SNAT rule count'
for proto in tcp udp; do
    for port in 443 8443 10000:60000; do
        grep -Fxq -- "-A PREROUTING -i eth0 -p $proto --dport $port -j DNAT --to-destination 203.0.113.10" "$work/rules" || fail 'Missing DNAT'
        grep -Fxq -- "-A POSTROUTING -o eth0 -p $proto -d 203.0.113.10 --dport $port -m conntrack --ctstate DNAT -j SNAT --to-source 192.0.2.2" "$work/rules" || fail 'Missing SNAT'
    done
done
grep -Fxq -- '-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' "$work/rules" || fail 'Missing TCPMSS'
printf '%s\n' '*filter' ':ufw-before-input - [0:0]' '-A ufw-before-input -j ufw-logging-deny' 'COMMIT' >> "$work/rules"
validation_rules "$work/rules" > "$work/validation"
grep -Fxq ':ufw-logging-deny - [0:0]' "$work/validation" || fail 'Missing UFW dependency in validation copy'
! grep -q '^:ufw-logging-deny ' "$work/rules" || fail 'Validation changed installed rules'

# tc is mocked to inspect mutations and exercise the real queue-selection code.
tc() {
    if [[ $1 == qdisc && $2 == show ]]; then
        cat "$work/queues"
    elif [[ $1 == qdisc && $2 == replace ]]; then
        printf '%s\n' "$*" >> "$work/calls"
        if [[ $5 == root ]]; then
            printf '%s\n' 'qdisc fq 1: root refcnt 2' > "$work/queues"
        else
            awk -v p="$6" '{for(i=1;i<NF;i++) if($i=="parent" && $(i+1)==p) $2="fq"; print}' "$work/queues" > "$work/next"
            mv "$work/next" "$work/queues"
        fi
    else fail 'Unexpected tc call'; fi
}
printf '%s\n' 'qdisc mq 0: root' 'qdisc fq_codel 0: parent :1' 'qdisc fq_codel 0: parent :2' > "$work/queues"
configure_fq eth0 check || fail 'mq preflight'
[[ ! -e $work/calls ]] || fail 'Preflight changed queues'
configure_fq eth0 || fail 'mq apply'
grep -Fxq 'qdisc mq 0: root' "$work/queues" || fail 'mq root replaced'
[[ $(wc -l < "$work/calls") == 2 ]] || fail 'Wrong mq leaf replacement count'
configure_fq eth0 || fail 'Already fq failed'
[[ $(wc -l < "$work/calls") == 2 ]] || fail 'Existing fq unnecessarily replaced'
printf '%s\n' 'qdisc fq_codel 0: root refcnt 2' > "$work/queues"
configure_fq eth0 || fail 'Single queue apply'
grep -q '^qdisc fq .* root' "$work/queues" || fail 'Single queue not fq'
printf '%s\n' 'qdisc htb 1: root refcnt 2' > "$work/queues"
if configure_fq eth0 check 2>/dev/null; then fail 'Custom shaping accepted'; fi
printf '%s\n' 'qdisc mq 0: root' 'qdisc htb 1: parent :1' > "$work/queues"
if configure_fq eth0 check 2>/dev/null; then fail 'Custom mq child accepted'; fi
printf '%s\n' 'qdisc fq 0: root' 'qdisc clsact ffff: parent ffff:fff1' > "$work/queues"
if configure_fq eth0 check 2>/dev/null; then fail 'Additional queue accepted'; fi
{ declare -f configure_fq; printf '%s\n' 'configure_fq "$1"'; } | bash -n || fail 'Generated boot helper syntax'
printf '%s\n' 'PASS: IPv4, SSH conflicts, NAT/TCPMSS generation, UFW validation dependencies, fq and mq handling.'
