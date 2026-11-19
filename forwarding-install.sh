#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

valid_ipv4() {
    local address=$1 octet
    local -a octets
    [[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

check_ssh_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] || die 'Invalid SSH_PORT.'
    local port=$((10#$1))
    (( port >= 1 && port <= 65535 )) || die 'Invalid SSH_PORT.'
    if (( port == 443 || port == 8443 || (port >= 10000 && port <= 60000) )); then
        die 'SSH_PORT overlaps the forwarded ports. Change the SSH port before installation.'
    fi
}

# Also embedded in the boot helper. Preserve mq and replace only its leaves.
configure_fq() {
    local iface=$1 mode=${2:-apply} listing root parent kind
    local -a parents=()
    listing=$(tc qdisc show dev "$iface") || return 1
    root=$(awk '/ root( |$)/ {print $2}' <<< "$listing")
    case $root in
        fq|fq_codel|pfifo_fast|noqueue) ;;
        mq)
            while read -r kind parent; do
                case $kind in fq|fq_codel|pfifo_fast) ;; *) printf 'Unsupported mq child: %s\n' "$kind" >&2; return 1 ;; esac
                [[ $parent =~ ^[[:xdigit:]]*:[[:xdigit:]]+$ ]] || return 1
                parents+=("$parent")
            done < <(awk '{for(i=1;i<NF;i++) if($i=="parent") print $2, $(i+1)}' <<< "$listing")
            ((${#parents[@]})) || return 1
            ;;
        *) printf 'Unsupported queue tree on %s: %s\n' "$iface" "$root" >&2; return 1 ;;
    esac
    # Refuse custom shaping or additional ingress/clsact queues.
    if [[ $root != mq ]] && [[ $(awk 'END {print NR}' <<< "$listing") != 1 ]]; then return 1; fi
    if [[ $root == mq ]] && [[ $(awk 'END {print NR}' <<< "$listing") != $((${#parents[@]} + 1)) ]]; then return 1; fi
    [[ $mode == check ]] && return 0
    if [[ $root == mq ]]; then
        for parent in "${parents[@]}"; do
            kind=$(awk -v p="$parent" '{for(i=1;i<NF;i++) if($i=="parent" && $(i+1)==p) print $2}' <<< "$listing")
            if [[ $kind != fq ]]; then tc qdisc replace dev "$iface" parent "$parent" fq || return 1; fi
        done
    elif [[ $root != fq ]]; then
        tc qdisc replace dev "$iface" root fq || return 1
    fi
    listing=$(tc qdisc show dev "$iface") || return 1
    awk '$1=="qdisc" && $2!="mq" && $2!="fq" {bad=1} END {exit bad}' <<< "$listing"
}

write_forwarding_rules() {
    local origin=$1 iface=$2 source=$3 proto port
    printf '%s\n' '*nat' '# traffic-forwarding: dedicated IPv4 relay' ':PREROUTING ACCEPT [0:0]' ':POSTROUTING ACCEPT [0:0]'
    for proto in tcp udp; do
        for port in 443 8443 10000:60000; do
            printf '%s\n' "-A PREROUTING -i $iface -p $proto --dport $port -j DNAT --to-destination $origin"
            printf '%s\n' "-A POSTROUTING -o $iface -p $proto -d $origin --dport $port -m conntrack --ctstate DNAT -j SNAT --to-source $source"
        done
    done
    printf '%s\n' 'COMMIT' '*mangle' ':FORWARD ACCEPT [0:0]' \
        '-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' 'COMMIT'
}

# Declare UFW-created dependencies in the test copy only: a fresh VM may not
# have ufw-logging-deny yet. The installed before.rules remains standard.
validation_rules() {
    awk '
    { lines[NR]=$0 }
    /^:/ { declared[substr($1,2)]=1 }
    { for(i=1;i<NF;i++) if($i=="-j" && $(i+1) ~ /^ufw-/) needed[$(i+1)]=1 }
    END {
        for(n=1;n<=NR;n++) {
            print lines[n]
            if(lines[n]=="*filter") for(chain in needed)
                if(!(chain in declared)) print ":" chain " - [0:0]"
        }
    }' "$1"
}

main() {
    [[ $EUID -eq 0 ]] || die 'Run as root.'
    local origin=${ORIGIN_IP:-} ssh_port=${SSH_PORT:-${SSH_CONNECTION:-}}
    if [[ -z ${SSH_PORT:-} ]]; then ssh_port=${ssh_port##* }; fi
    valid_ipv4 "$origin" || die 'Set ORIGIN_IP to a valid destination IPv4 address.'
    local first=${origin%%.*}
    (( first > 0 && first < 224 && first != 127 )) || die 'ORIGIN_IP must be a unicast server address.'
    [[ -n $ssh_port ]] || die 'Set SSH_PORT to your actual SSH port.'
    check_ssh_port "$ssh_port"
    ssh_port=$((10#$ssh_port))
    . /etc/os-release
    [[ $ID == ubuntu || $ID == debian ]] || die 'Only Ubuntu and Debian are supported.'
    [[ -d /run/systemd/system ]] || die 'A VM running systemd is required.'
    local command missing=0
    for command in ufw ip tc iptables iptables-save iptables-restore ip6tables-save nft sysctl flock modprobe; do
        command -v "$command" >/dev/null 2>&1 || missing=1
    done
    if (( missing )); then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ufw iproute2 iptables nftables procps util-linux kmod
    fi
    exec 9>/run/traffic-forwarding-install.lock
    flock -n 9 || die 'Another installation is running.'

    local existing status route iface source interfaces file saved
    for file in /etc/sysctl.d/99-relay-optimization.conf /etc/sysctl.d/99-3dp-forwarder.conf \
        /etc/sysctl.d/99-traffic-forwarding.conf /usr/local/libexec/traffic-forwarding-fq \
        /etc/systemd/system/traffic-forwarding-fq.service /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        [[ ! -e $file ]] || die "Existing relay configuration: $file. This installer requires a clean VPS."
    done
    local service
    for service in nftables.service netfilter-persistent.service; do
        if systemctl is-enabled --quiet "$service" 2>/dev/null || systemctl is-active --quiet "$service"; then
            die "Another firewall loader is enabled or active: $service."
        fi
    done
    status=$(ufw status) || die 'Cannot read UFW status.'
    [[ $status == 'Status: inactive' ]] || die 'UFW is already active; use a clean VPS.'
    existing=$(ufw show added) || die 'Cannot read UFW rules.'
    ! grep -q '^ufw ' <<< "$existing" || die 'Existing UFW user rules; use a clean VPS.'
    for file in before.rules before6.rules after.rules after6.rules; do
        cmp -s "/etc/ufw/$file" "/usr/share/ufw/iptables/$file" ||
            die "UFW $file differs from the package default; refusing to overwrite it."
    done
    existing=$(nft list ruleset) || die 'Cannot inspect nftables.'
    [[ -z $existing ]] || die 'Existing nftables tables; use a clean VPS.'
    for command in iptables-save ip6tables-save; do
        saved=$($command) || die "Cannot inspect $command."
        if grep -Eq '^-A |^:[^ ]+ (DROP|REJECT) ' <<< "$saved"; then
            die "Existing firewall rules or restrictive policies in $command."
        fi
    done

    route=$(ip -4 route get "$origin") || die 'No route to ORIGIN_IP.'
    [[ $route != local\ * && $route != broadcast\ * ]] || die 'ORIGIN_IP is local or broadcast.'
    iface=$(awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}' <<< "$route")
    source=$(awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}' <<< "$route")
    [[ $iface =~ ^[a-zA-Z0-9_.-]+$ && $iface != lo ]] || die 'Cannot determine network interface.'
    valid_ipv4 "$source" || die 'Cannot determine the local SNAT address.'
    interfaces=$(ip -4 -o addr show scope global | awk '{print $2}' | sort -u)
    [[ $interfaces == "$iface" ]] || die 'Only a VPS with one global IPv4 interface is supported.'
    configure_fq "$iface" check || die 'Unsupported existing queue configuration.'
    modprobe sch_fq
    log "Origin: $origin; interface: $iface; SNAT address: $source; SSH: $ssh_port"

    local staging backup
    staging=$(mktemp -d)
    trap "rm -rf -- '$staging'" EXIT
    write_forwarding_rules "$origin" "$iface" "$source" > "$staging/before.rules"
    cat /etc/ufw/before.rules >> "$staging/before.rules"
    validation_rules "$staging/before.rules" > "$staging/validation.rules"
    iptables-restore --test < "$staging/validation.rules" || die 'Rules failed validation; UFW configuration has not been changed.'

    backup=$(mktemp -d /var/backups/traffic-forwarding.XXXXXX)
    cp -a /etc/ufw "$backup/ufw"
    iptables-save > "$backup/iptables.rules"
    ip6tables-save > "$backup/ip6tables.rules"
    sysctl net.ipv4.ip_forward net.core.default_qdisc > "$backup/sysctl.txt"
    tc qdisc show dev "$iface" > "$backup/qdisc.txt"
    log "Configuration backup: $backup (no automatic rollback)."
    trap 'printf "ERROR: installation failed at line %s. Inspect the configuration backup before retrying.\n" "$LINENO" >&2' ERR

    install -m 0644 "$staging/before.rules" /etc/ufw/before.rules
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    grep -qx 'DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw || die 'Cannot set UFW forward policy.'
    printf '%s\n' 'net.ipv4.ip_forward = 1' 'net.core.default_qdisc = fq' > /etc/sysctl.d/99-traffic-forwarding.conf
    printf '\n%s\n' '# traffic-forwarding' 'net/ipv4/ip_forward=1' >> /etc/ufw/sysctl.conf
    ufw allow "$ssh_port/tcp" comment 'traffic-forwarding: SSH'
    sysctl -w net.ipv4.ip_forward=1 net.core.default_qdisc=fq

    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin' 'export LC_ALL=C'
        declare -f configure_fq
        printf '%s\n' 'configure_fq "$1"'
    } > "$staging/fq-helper"
    install -d -m 0755 /usr/local/libexec
    install -m 0755 "$staging/fq-helper" /usr/local/libexec/traffic-forwarding-fq
    printf '%s\n' '[Unit]' 'Description=FQ queues for the traffic-forwarding VPS' \
        'Wants=network-online.target' 'After=network-online.target ufw.service' \
        '[Service]' 'Type=oneshot' "ExecStart=/usr/local/libexec/traffic-forwarding-fq $iface" \
        'RemainAfterExit=yes' '[Install]' 'WantedBy=multi-user.target' > "$staging/fq.service"
    install -m 0644 "$staging/fq.service" /etc/systemd/system/traffic-forwarding-fq.service
    systemctl daemon-reload
    systemctl enable --now traffic-forwarding-fq.service
    ufw --force enable

    status=$(ufw status verbose)
    grep -q '^Status: active$' <<< "$status" || die 'UFW is not active.'
    grep -q 'allow (routed)' <<< "$status" || die 'UFW forward policy is not ACCEPT.'
    saved=$(iptables -S FORWARD)
    grep -qx -- '-P FORWARD ACCEPT' <<< "$saved" || die 'Kernel FORWARD policy is not ACCEPT.'
    grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf || die 'UFW boot activation is not enabled.'
    [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] || die 'IPv4 forwarding is disabled.'
    [[ $(sysctl -n net.core.default_qdisc) == fq ]] || die 'Default queue is not fq.'
    configure_fq "$iface" || die 'FQ queues are not configured.'
    local proto port
    for proto in tcp udp; do
        for port in 443 8443 10000:60000; do
            iptables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport "$port" -j DNAT --to-destination "$origin"
            iptables -t nat -C POSTROUTING -o "$iface" -p "$proto" -d "$origin" --dport "$port" -m conntrack --ctstate DNAT -j SNAT --to-source "$source"
        done
    done
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    log "Configured TCP/UDP 443, 8443, 10000-60000 -> $origin; SNAT, TCPMSS, FORWARD ACCEPT and fq."
    log 'Use a fresh OS installation to change the origin or remove this setup.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
