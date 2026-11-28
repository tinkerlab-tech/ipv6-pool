#!/bin/sh
# IPv6 节点池。直接运行或用 bash ipv6-pool.sh 启动。
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
    printf '%s\n' '此脚本需要 Bash。Alpine 可运行 apk add bash iproute2。' >&2
    exit 1
fi

# /bin/sh 在部分发行版上是 Bash，此时要退出其 POSIX 兼容模式。
set +o posix
set +x
set -o pipefail
export LC_ALL=C
umask 077

if ! (( BASH_VERSINFO[0] > 4 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2 )); then
    printf 'IPv6 节点池：%s\n' '需要 Bash 4.2 或更新版本。Alpine 可运行 apk add bash iproute2。' >&2
    exit 1
fi

STATE=/var/lib/ipv6-pool
RUNNER=$STATE/ipv6-pool.sh
UNIT=/etc/systemd/system/ipv6-pool-restore.service
OPENRC=/etc/local.d/ipv6-pool-restore.start
RC_LOCAL=/etc/rc.local
MARK='# ipv6-pool managed boot hook'
CONFIG=$STATE/pool.conf
PROTECTED=$STATE/protected.list
IPS=$STATE/ips.list
OWNED=$STATE/owned.list
PROOFS=$STATE/ownership.list
PENDING=$STATE/pending.ip
NODES=$STATE/nodes.txt
TRANSITION=$STATE/pool.next
UDP_PORTS=$STATE/udp-ports.list
NFT_TABLE=ipv6_pool_udp
IP6T_CHAIN=IPV6_POOL_UDP
# 匹配备注末尾的旧池标记，也能清理过去重复追加的标记。
V6_NAME_SUFFIX='(^|-)v6(-([0-9]{2}|100))?(-v6(-([0-9]{2}|100))?)*'

declare -a pool=() next_pool=() dad_failed=() link_udp_ports=() udp_ports=()
declare -A protected=() owned=() proofs=() wanted=() present=() live=() route_sources=() udp_port_set=()
device='' prefix='' mask=''
detected_dev='' detected_prefix='' detected_mask='' detected_ip='' detected_ip_raw='' detection_error='' link_error=''
address_snapshot='' routes='' boot_id=''
binding_details='' binding_index='' binding_removed=0

info() { printf '%s\n' "$@"; }
error() { printf 'IPv6 节点池：%s\n' "$*" >&2; }
die() { error "$@"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

# 在同一个目录中原子替换文件，半写入的列表不会被恢复流程读取。
write_file() {
    local path=$1
    shift
    {
        if (( $# )); then printf '%s\n' "$@"; fi
    } > "$path.new" && mv -f "$path.new" "$path"
}

ipv4_valid() {
    local part
    local -a octets
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$1"
    for part in "${octets[@]}"; do
        (( 10#$part <= 255 )) || return 1
    done
}

ipv4_public() {
    local -a octets
    ipv4_valid "$1" || return 1
    IFS=. read -r -a octets <<< "$1"
    local a=$((10#${octets[0]})) b=$((10#${octets[1]}))
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    return 0
}

# 规范化为小写八组，包括双冒号和 IPv4 嵌入式写法。
expand_ipv6() {
    local addr=$1 left right tail hex part missing=0 index=0
    local -a head=() end=() octets=() groups=()
    if [[ $addr == *.* ]]; then
        tail=${addr##*:}
        [[ $addr == *:* ]] && ipv4_valid "$tail" || return 1
        IFS=. read -r -a octets <<< "$tail"
        printf -v hex '%x:%x' "$((10#${octets[0]} * 256 + 10#${octets[1]}))" \
            "$((10#${octets[2]} * 256 + 10#${octets[3]}))"
        addr=${addr%:*}:$hex
    fi
    if [[ $addr == *::* ]]; then
        left=${addr%%::*}
        right=${addr#*::}
        [[ $right != *::* && $left != *: && $right != :* && $right != *: ]] || return 1
        if [[ -n $left ]]; then IFS=: read -r -a head <<< "$left"; fi
        if [[ -n $right ]]; then IFS=: read -r -a end <<< "$right"; fi
        missing=$((8 - ${#head[@]} - ${#end[@]}))
        (( missing >= 1 )) || return 1
    else
        [[ $addr != :* && $addr != *: ]] || return 1
        IFS=: read -r -a head <<< "$addr"
        (( ${#head[@]} == 8 )) || return 1
    fi
    for part in "${head[@]}"; do
        [[ $part =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        printf -v 'groups[index++]' '%04x' "$((16#$part))"
    done
    while (( missing > 0 )); do
        groups[index++]=0000
        (( missing-- ))
    done
    for part in "${end[@]}"; do
        [[ $part =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        printf -v 'groups[index++]' '%04x' "$((16#$part))"
    done
    local IFS=:
    expanded=${groups[*]}
}

valid_device() { [[ $1 =~ ^[A-Za-z0-9_.-]{1,15}$ && $1 != -* ]]; }
valid_mask() { [[ $1 =~ ^(4[89]|5[0-9]|6[0-4])$ ]]; }

valid_pool_ip() {
    local address=$1 suffix
    [[ $address =~ ^([0-9a-f]{4}:){7}[0-9a-f]{4}$ && $address == "$prefix":* ]] || return 1
    suffix=${address#"$prefix":}
    [[ $suffix != 0000:0000:0000:0000 && $suffix != fdff:ffff:ffff:ff[89a-f][0-9a-f] ]]
}

valid_udp_port_spec() {
    local first last
    if [[ $1 =~ ^[1-9][0-9]{0,4}$ ]]; then
        (( 10#$1 >= 1 && 10#$1 <= 65535 ))
        return
    fi
    if [[ $1 =~ ^([1-9][0-9]{0,4})-([1-9][0-9]{0,4})$ ]]; then
        first=${BASH_REMATCH[1]}
        last=${BASH_REMATCH[2]}
        (( 10#$first >= 1 && 10#$first < 10#$last && 10#$last <= 65535 ))
        return
    fi
    return 1
}

add_link_udp_ports() {
    local raw=$1 item first last normalized existing found
    local -a items=()
    IFS=, read -r -a items <<< "$raw"
    for item in "${items[@]}"; do
        [[ $item =~ ^[0-9]{1,5}(-[0-9]{1,5})?$ ]] || continue
        first=$((10#${item%-*}))
        last=$((10#${item##*-}))
        (( first >= 1 && first <= last && last <= 65535 )) || continue
        if (( first == last )); then normalized=$first
        else normalized="$first-$last"; fi
        found=0
        for existing in "${link_udp_ports[@]}"; do
            if [[ $existing == "$normalized" ]]; then found=1; break; fi
        done
        if (( ! found )); then link_udp_ports+=("$normalized"); fi
    done
}

read_state() {
    local address proof extra port_spec
    device='' prefix='' mask=''
    pool=() protected=() owned=() proofs=() wanted=() udp_ports=() udp_port_set=()
    if [[ ! -e $CONFIG ]]; then
        [[ ! -e $IPS && ! -e $OWNED && ! -e $PROOFS && ! -e $PENDING && ! -e $TRANSITION && ! -e $UDP_PORTS ]]
        return
    fi
    read -r device prefix mask extra < "$CONFIG" || return 1
    valid_device "$device" && valid_mask "$mask" && [[ -z $extra ]] || return 1
    [[ $prefix =~ ^[23][0-9a-f]{3}(:[0-9a-f]{4}){3}$ ]] || return 1
    [[ -f $PROTECTED ]] || return 1
    while IFS= read -r address || [[ -n $address ]]; do
        [[ $address =~ ^([0-9a-f]{4}:){7}[0-9a-f]{4}$ ]] || return 1
        protected[$address]=1
    done < "$PROTECTED" || return 1
    if [[ -e $IPS ]]; then
        while IFS= read -r address || [[ -n $address ]]; do
            valid_pool_ip "$address" && [[ ! ${wanted[$address]+yes} ]] || return 1
            pool+=("$address")
            wanted[$address]=1
        done < "$IPS" || return 1
    fi
    if [[ -e $OWNED ]]; then
        while IFS= read -r address || [[ -n $address ]]; do
            valid_pool_ip "$address" || return 1
            owned[$address]=1
        done < "$OWNED" || return 1
    fi
    if [[ -e $PROOFS ]]; then
        while read -r address proof extra || [[ -n $address ]]; do
            valid_pool_ip "$address" && [[ $proof =~ ^[0-9a-f-]{36}:[0-9]+:[0-9]+$ && -z $extra ]] || return 1
            proofs[$address]=$proof
        done < "$PROOFS" || return 1
    fi
    if [[ -e $UDP_PORTS ]]; then
        while IFS= read -r port_spec || [[ -n $port_spec ]]; do
            valid_udp_port_spec "$port_spec" || return 1
            if [[ ! ${udp_port_set[$port_spec]+yes} ]]; then
                udp_ports+=("$port_spec")
                udp_port_set[$port_spec]=1
            fi
        done < "$UDP_PORTS" || return 1
    fi
    (( ${#pool[@]} <= 100 ))
}

# pool.next 在新池验证通过后原子写入。中断后先补齐两个对外文件，再清理旧绑定。
finish_transition() {
    local address node
    local -a addresses=() links=()
    local -A recorded=()
    [[ -e $TRANSITION ]] || return 0
    while IFS=$'\t' read -r address node || [[ -n $address ]]; do
        valid_pool_ip "$address" && [[ ${owned[$address]+yes} && ! ${recorded[$address]+yes} &&
            $node == *://* && ! $node =~ [[:space:][:cntrl:]] ]] || return 1
        recorded[$address]=1
        addresses+=("$address")
        links+=("$node")
    done < "$TRANSITION" || return 1
    (( ${#addresses[@]} && ${#addresses[@]} <= 100 )) || return 1
    write_file "$IPS" "${addresses[@]}" && write_file "$NODES" "${links[@]}" &&
        rm -f "$TRANSITION" && read_state
}

scan_addresses() {
    local _number dev family cidr details expanded
    address_snapshot=$(ip -o -6 addr show) || return 1
    present=() live=()
    while read -r _number dev family cidr details; do
        [[ $family == inet6 && $cidr == */* ]] || continue
        expand_ipv6 "${cidr%/*}" || continue
        present[$expanded]=1
        live["${dev%%@*}/$expanded/${cidr##*/}"]=" $details "
    done <<< "$address_snapshot"
}

scan_routes() {
    local line index expanded
    local -a fields
    routes=$(ip -6 route show default) || return 1
    route_sources=()
    while IFS= read -r line; do
        read -r -a fields <<< "$line"
        for ((index=0; index+1<${#fields[@]}; index++)); do
            if [[ ${fields[index]} == src ]] && expand_ipv6 "${fields[index+1]}"; then
                route_sources[$expanded]=1
            fi
        done
    done <<< "$routes"
}

detect_network() {
    local route_dev route_src _number dev family cidr details expanded source='' first_mask=''
    detected_dev='' detected_prefix='' detected_mask='' detected_ip='' detected_ip_raw=''
    detection_error='无法读取 IPv6 路由或地址。'
    scan_routes && scan_addresses || return 1
    # 按 dev、src 和 metric 取字段，兼容点对点路由与多路径的 nexthop 行。
    read -r route_dev route_src < <(printf '%s\n' "$routes" | awk '
        $1 == "default" { metric = 1024; src = "" }
        $1 != "default" && $1 != "nexthop" { next }
        {
            dev = ""; down = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && !dev) dev = $(i+1)
                if ($i == "src") src = $(i+1)
                if ($i == "metric") metric = $(i+1) + 0
                if ($i == "linkdown" || $i == "dead") down = 1
            }
            if (dev && !down && (!best || metric < priority)) {
                best = dev; priority = metric; preferred = src
            }
        }
        END { if (best) print best, preferred }
    ') || :
    detection_error='找不到可用的 IPv6 默认路由。'
    valid_device "$route_dev" || return 1
    detected_dev=$route_dev
    if [[ -n $route_src ]] && expand_ipv6 "$route_src"; then source=$expanded; fi
    while read -r _number dev family cidr details; do
        [[ ${dev%%@*} == "$route_dev" && $family == inet6 && $cidr == */* && " $details " == *' scope global '* ]] || continue
        expand_ipv6 "${cidr%/*}" || continue
        [[ $expanded == [23]* && ! ${owned[$expanded]+yes} && ! ${wanted[$expanded]+yes} ]] || continue
        [[ " $details " != *' tentative '* && " $details " != *' dadfailed '* ]] || continue
        if [[ -n $source && $expanded != "$source" ]]; then continue; fi
        if [[ " $details " == *' deprecated '* && -z $source ]]; then continue; fi
        if [[ -z $first_mask ]]; then first_mask=${cidr##*/}; fi
        if valid_mask "${cidr##*/}"; then
            detected_prefix=${expanded%:*:*:*:*}
            detected_mask=${cidr##*/}
            detected_ip=$expanded
            detected_ip_raw=${cidr%/*}
            detection_error=''
            return 0
        fi
    done <<< "$address_snapshot"
    if [[ -n $first_mask ]]; then
        detection_error="网卡 $route_dev 的原生 IPv6 掩码为 /${first_mask}，仅支持 /48 至 /64。"
    else
        detection_error="网卡 $route_dev 没有可用的原生全局单播 IPv6。"
    fi
    return 1
}

check_network() {
    detect_network || { error "$detection_error"; return 1; }
    if [[ -n $device && ( $device != "$detected_dev" || $prefix != "$detected_prefix" || $mask != "$detected_mask" ) ]]; then
        # 同网卡可同时有多个原生前缀，保留仍然存在的原池前缀。
        local address key details
        if [[ $device == "$detected_dev" ]]; then
            for key in "${!live[@]}"; do
                address=${key#*/}
                address=${address%/*}
                details=${live[$key]}
                if [[ $key == "$device/$prefix":*"/$mask" && ! ${wanted[$address]+yes} && ! ${owned[$address]+yes} &&
                    $details == *' scope global '* && $details != *' tentative '* &&
                    $details != *' dadfailed '* && $details != *' deprecated '* ]]; then
                    detected_ip=$address
                    detected_ip_raw=$address
                    return 0
                fi
            done
        fi
        error '默认出口或原生 IPv6 前缀已变化，现有地址池无法在当前网络上使用。'
        return 1
    fi
}

init_pool() {
    [[ -z $device ]] || return 0
    write_file "$PROTECTED" "${!present[@]}" &&
        write_file "$CONFIG" "$detected_dev $detected_prefix $detected_mask" &&
        read_state
}

lookup_binding() {
    local address=$1 snapshot index dev family cidr details expanded
    binding_details='' binding_index=''
    snapshot=$(ip -o -6 addr show to "$address/128") || return 1
    while read -r index dev family cidr details; do
        [[ ${dev%%@*} == "$device" && $family == inet6 && $cidr == */* && ${cidr##*/} == "$mask" ]] || continue
        if ! expand_ipv6 "${cidr%/*}" || [[ $expanded != "$address" ]]; then continue; fi
        binding_index=${index%:}
        binding_details=" $details "
        break
    done <<< "$snapshot"
}

# ip addr save 输出原始 rtnetlink 消息。读取 IFA_CACHEINFO.cstamp，
# 用启动 ID、接口编号和内核地址创建时间区分删除后被其他程序重建的绑定。
binding_proof() {
    local address=$1 stamp
    [[ $binding_index =~ ^[0-9]+$ ]] || return 1
    stamp=$(ip -6 addr save dev "$device" | od -An -v -tu1 |
        awk -v target="${address//:/}" -v ifindex="$binding_index" -v mask="$mask" '
        function aligned(n) { return int((n + 3) / 4) * 4 }
        function u16(p) { return little ? b[p] + 256*b[p+1] : 256*b[p] + b[p+1] }
        function u32(p) { return little ? u16(p) + 65536*u16(p+2) : 65536*u16(p) + u16(p+2) }
        { for (i=1; i<=NF; i++) b[++size] = $i }
        END {
            # iproute2 的地址转储魔数为 0x47361222。
            if (b[1]==34 && b[2]==18 && b[3]==54 && b[4]==71) little=1
            else if (b[1]!=71 || b[2]!=54 || b[3]!=18 || b[4]!=34) exit 1
            for (p=5; p+23<=size; p+=aligned(msg_len)) {
                msg_len=u32(p)
                if (msg_len<24 || p+msg_len-1>size) exit 1
                if (u16(p+4)!=20 || b[p+16]!=10 || b[p+17]!=mask || u32(p+20)!=ifindex) continue
                local_ip=""; address_ip=""; created=""
                for (a=p+24; a+3<p+msg_len; a+=aligned(attr_len)) {
                    attr_len=u16(a); kind=u16(a+2)
                    if (attr_len<4 || a+attr_len>p+msg_len) exit 1
                    if ((kind==1 || kind==2) && attr_len==20) {
                        hex=""
                        for (j=a+4; j<a+20; j++) hex=hex sprintf("%02x", b[j])
                        if (kind==2) local_ip=hex
                        else address_ip=hex
                    }
                    if (kind==6 && attr_len>=20) created=sprintf("%.0f", u32(a+12))
                }
                if ((local_ip!="" ? local_ip : address_ip)==target && created!="") {
                    print created
                    exit
                }
            }
            exit 1
        }') || return 1
    [[ $stamp =~ ^[0-9]+$ ]] || return 1
    printf '%s:%s:%s\n' "$boot_id" "$binding_index" "$stamp"
}

save_proofs() {
    local address
    local -a entries=()
    for address in "${!proofs[@]}"; do entries+=("$address ${proofs[$address]}"); done
    write_file "$PROOFS" "${entries[@]}"
}

# 删除前只查目标地址，并核对当前绑定的归属及默认路由来源。
remove_owned() {
    local address=$1 proof
    binding_removed=0
    lookup_binding "$address" || return 1
    if [[ -n $binding_details ]]; then
        scan_routes || return 1
        if [[ ${protected[$address]+yes} || ${route_sources[$address]+yes} ||
            $binding_details != *' scope global '* || $binding_details != *' noprefixroute '* ||
            $binding_details != *' valid_lft forever '* ||
            ! $binding_details =~ [[:space:]]preferred_lft\ 0(sec)?[[:space:]] ||
            ${proofs[$address]-} != "$boot_id":* ]] ||
            ! proof=$(binding_proof "$address") || [[ $proof != "${proofs[$address]}" ]]; then
            error "保留 $address，当前绑定的归属、属性或路由用途无法确认。"
        else
            ip -6 addr del "$address/$mask" dev "$device" || return 1
            binding_removed=1
        fi
    fi
    unset 'owned[$address]' 'proofs[$address]'
    write_file "$OWNED" "${!owned[@]}" && save_proofs
}

recover_pending() {
    local address proof
    [[ -e $PENDING ]] || return 0
    IFS= read -r address < "$PENDING" && valid_pool_ip "$address" || return 1
    scan_addresses || return 1
    if [[ ${present[$address]+yes} ]]; then
        lookup_binding "$address" || return 1
        if [[ ! ${protected[$address]+yes} && ${proofs[$address]-} == "$boot_id":* ]] &&
            proof=$(binding_proof "$address") && [[ $proof == "${proofs[$address]}" ]]; then
            owned[$address]=1
            write_file "$OWNED" "${!owned[@]}" || return 1
        else
            error "保留上次中断时出现的 $address，无法确认它的绑定来源。"
            protected[$address]=1
            write_file "$PROTECTED" "${!protected[@]}" || return 1
        fi
    fi
    rm -f "$PENDING"
}

bind_address() {
    local address=$1 mode=${2:-restore} proof
    local key="$device/$address/$mask" binding_removed
    if [[ ${live[$key]+yes} ]]; then
        [[ $mode != fresh ]] || return 1
        # 已发布地址只尝试修复同一个 IP，避免旧分享链接悄然失效。
        if [[ ${live[$key]} != *' dadfailed '* || ! ${owned[$address]+yes} ]]; then return 0; fi
        remove_owned "$address" || return 1
        (( binding_removed )) || return 0
        unset 'live[$key]' 'present[$address]'
    fi
    if [[ ${protected[$address]+yes} || ${present[$address]+yes} ]]; then
        error "地址 $address 已被保护或在其他接口/掩码上使用。"
        return 1
    fi
    write_file "$PENDING" "$address" || return 1
    # deprecated 避免抢占首选源地址。noprefixroute 保留原有前缀路由策略。
    if ! ip -6 addr add "$address/$mask" dev "$device" preferred_lft 0 noprefixroute; then
        recover_pending || return 1
        [[ $mode != fresh && ${live[$key]+yes} ]]
        return
    fi
    if ! lookup_binding "$address" || ! proof=$(binding_proof "$address"); then
        error "无法记录 $address 的内核绑定归属，保留绑定供检查。"
        return 1
    fi
    proofs[$address]=$proof
    owned[$address]=1
    save_proofs && write_file "$OWNED" "${!owned[@]}" && rm -f "$PENDING"
}

wait_for_dad() {
    local attempt address details pending
    local -a conflicts=()
    dad_failed=()
    for ((attempt=0; attempt<=10; attempt++)); do
        scan_addresses || return 1
        pending=0
        conflicts=()
        for address in "$@"; do
            details=${live["$device/$address/$mask"]-}
            if [[ -z $details ]]; then
                error "地址 $address 未绑定。"
                return 1
            fi
            if [[ $details == *' dadfailed '* ]]; then conflicts+=("$address")
            elif [[ $details == *' tentative '* ]]; then pending=1; fi
        done
        if (( ! pending )); then
            dad_failed=("${conflicts[@]}")
            (( ! ${#dad_failed[@]} ))
            return
        fi
        if (( attempt < 10 )); then sleep 1; fi
    done
    error '等待 IPv6 重复地址检测超时。'
    return 1
}

prune_owned() {
    local address
    for address in "${!owned[@]}"; do
        if [[ ! ${wanted[$address]+yes} ]]; then remove_owned "$address" || return 1; fi
    done
}

record_link_udp_ports() {
    local spec
    (( ${#link_udp_ports[@]} )) || return 0
    for spec in "${link_udp_ports[@]}"; do
        if [[ ! ${udp_port_set[$spec]+yes} ]]; then
            udp_ports+=("$spec")
            udp_port_set[$spec]=1
        fi
    done
    write_file "$UDP_PORTS" "${udp_ports[@]}"
}

remove_udp_nat() {
    if has nft && nft list table ip6 "$NFT_TABLE" >/dev/null 2>&1; then
        nft delete table ip6 "$NFT_TABLE" >/dev/null 2>&1 || true
    fi
    if has ip6tables && ip6tables -t nat -S "$IP6T_CHAIN" >/dev/null 2>&1; then
        while ip6tables -t nat -D PREROUTING -j "$IP6T_CHAIN" >/dev/null 2>&1; do :; done
        ip6tables -t nat -F "$IP6T_CHAIN" >/dev/null 2>&1 || true
        ip6tables -t nat -X "$IP6T_CHAIN" >/dev/null 2>&1 || true
    fi
    return 0
}

apply_udp_nat_nft() {
    local native_ip=$1 spec script=''
    has nft || return 1
    if nft list table ip6 "$NFT_TABLE" >/dev/null 2>&1; then
        nft delete table ip6 "$NFT_TABLE" >/dev/null 2>&1 || return 1
    fi
    script=$'table ip6 '"$NFT_TABLE"$' {\n'
    script+=$'    chain prerouting {\n'
    script+=$'        type nat hook prerouting priority -90; policy accept;\n'
    script+="        ip6 daddr $native_ip return"$'\n'
    for spec in "${udp_ports[@]}"; do
        script+="        iifname \"$device\" ip6 daddr $prefix::/64 udp dport $spec dnat to $native_ip"$'\n'
    done
    script+=$'    }\n'
    script+=$'}\n'
    if ! printf '%s' "$script" | nft -f - >/dev/null 2>&1; then
        nft delete table ip6 "$NFT_TABLE" >/dev/null 2>&1 || true
        return 1
    fi
    if has ip6tables && ip6tables -t nat -S "$IP6T_CHAIN" >/dev/null 2>&1; then
        while ip6tables -t nat -D PREROUTING -j "$IP6T_CHAIN" >/dev/null 2>&1; do :; done
        ip6tables -t nat -F "$IP6T_CHAIN" >/dev/null 2>&1 || true
        ip6tables -t nat -X "$IP6T_CHAIN" >/dev/null 2>&1 || true
    fi
    return 0
}

apply_udp_nat_ip6tables() {
    local native_ip=$1 spec dport
    has ip6tables || return 1
    ip6tables -t nat -N "$IP6T_CHAIN" >/dev/null 2>&1 || true
    ip6tables -t nat -F "$IP6T_CHAIN" >/dev/null 2>&1 || return 1
    if ! ip6tables -t nat -A "$IP6T_CHAIN" -d "$native_ip/128" -j RETURN >/dev/null 2>&1; then
        remove_udp_nat
        return 1
    fi
    for spec in "${udp_ports[@]}"; do
        dport=${spec//-/:}
        if ! ip6tables -t nat -A "$IP6T_CHAIN" -i "$device" -d "$prefix::/64" \
            -p udp --dport "$dport" -j DNAT --to-destination "$native_ip" >/dev/null 2>&1; then
            remove_udp_nat
            return 1
        fi
    done
    if ! ip6tables -t nat -C PREROUTING -j "$IP6T_CHAIN" >/dev/null 2>&1; then
        if ! ip6tables -t nat -A PREROUTING -j "$IP6T_CHAIN" >/dev/null 2>&1; then
            remove_udp_nat
            return 1
        fi
    fi
    return 0
}

# 修正通配符 UDP 服务端（如 Xray/sing-box 跑 Hysteria 2/TUIC 或启用 salamander 混淆）
# 在多 IPv6 下回包源地址退回主 IP 的问题：通过独立 DNAT 链借助 conntrack 原地址回包。
sync_udp_nat() {
    local announce=${1:-0} backend=''
    if (( ! ${#pool[@]} || ! ${#udp_ports[@]} )); then
        remove_udp_nat
        return 0
    fi
    if [[ -z $detected_ip ]]; then return 0; fi
    if apply_udp_nat_nft "$detected_ip"; then
        backend='nftables'
    elif apply_udp_nat_ip6tables "$detected_ip"; then
        backend='ip6tables'
    else
        if (( announce )); then
            info '提示：未能自动配置 IPv6 UDP 回包修正规则（缺少 nft/ip6tables 或内核不支持 IPv6 NAT）。若 Hysteria 2 / TUIC 新节点超时，请手动配置 IPv6 DNAT 或关闭服务端 salamander 混淆。'
        else
            error '未能恢复 IPv6 UDP 回包修正规则（缺少 nft/ip6tables 或内核不支持 IPv6 NAT）。'
        fi
        return 0
    fi
    if (( announce )); then
        info "已配置 IPv6 UDP 回包修正规则（$backend，端口：${udp_ports[*]}），重启后自动恢复。"
    fi
    return 0
}

reconcile() {
    local address
    recover_pending && prune_owned || return 1
    if (( ! ${#pool[@]} )); then
        remove_udp_nat
        return 0
    fi
    scan_addresses || return 1
    for address in "${pool[@]}"; do bind_address "$address" || return 1; done
    if wait_for_dad "${pool[@]}"; then
        if (( ${#udp_ports[@]} )); then sync_udp_nat 0; fi
        return 0
    fi
    for address in "${dad_failed[@]}"; do error "地址 $address 重复地址检测失败。排除冲突后恢复，或选 3 更换地址池。"; done
    return 1
}

stage_pool() {
    local count=$1 address suffix attempt round
    local -a bytes ready
    local -A tried=() failed=()
    next_pool=()
    scan_addresses || return 1
    for ((round=0; round<4; round++)); do
        for ((attempt=0; attempt<count*20 && ${#next_pool[@]}<count; attempt++)); do
            read -r -a bytes <<< "$(od -An -v -tx1 -N8 /dev/urandom)"
            [[ ${bytes[*]} =~ ^[0-9a-f]{2}(\ [0-9a-f]{2}){7}$ ]] || return 1
            printf -v suffix '%s%s:%s%s:%s%s:%s%s' "${bytes[@]}"
            address=$prefix:$suffix
            valid_pool_ip "$address" || continue
            if [[ ${present[$address]+yes} || ${protected[$address]+yes} || ${wanted[$address]+yes} ||
                ${owned[$address]+yes} || ${tried[$address]+yes} ]]; then continue; fi
            tried[$address]=1
            bind_address "$address" fresh || return 1
            next_pool+=("$address")
        done
        (( ${#next_pool[@]} == count )) || return 1
        if wait_for_dad "${next_pool[@]}"; then return 0; fi
        (( ${#dad_failed[@]} )) || return 1
        for address in "${dad_failed[@]}"; do
            error "候选地址 $address 发生重复地址冲突，将补抽新地址。"
            remove_owned "$address" || return 1
            failed[$address]=1
        done
        ready=()
        for address in "${next_pool[@]}"; do
            if [[ ! ${failed[$address]+yes} ]]; then ready+=("$address"); fi
        done
        next_pool=("${ready[@]}")
    done
    error '多次补抽仍有地址发生冲突。'
    return 1
}

has_hook() { [[ -f $1 && ! -L $1 ]] && grep -Fqx "$MARK" "$1"; }
is_systemd() { [[ -d /run/systemd/system ]] && has systemctl; }
is_openrc() { [[ -d /etc/local.d ]] && has rc-update && [[ -x /etc/init.d/local ]]; }

install_systemd() {
    [[ ! -e $UNIT && ! -L $UNIT ]] || has_hook "$UNIT" || return 1
    write_file "$UNIT" "$MARK" '[Unit]' 'Description=Restore managed IPv6 pool' \
        'Wants=network-online.target' 'After=network-online.target' '[Service]' 'Type=oneshot' \
        "ExecStart=$RUNNER --restore" '[Install]' 'WantedBy=multi-user.target' &&
        chmod 644 "$UNIT" && systemctl daemon-reload && systemctl enable ipv6-pool-restore.service
}

install_openrc() {
    [[ ! -e $OPENRC && ! -L $OPENRC ]] || has_hook "$OPENRC" || return 1
    write_file "$OPENRC" '#!/bin/sh' "$MARK" "exec $RUNNER --restore" &&
        chmod 755 "$OPENRC" && rc-update add local default
}

edit_rc_local() {
    local action=$1 line="$RUNNER --restore || :" mode content
    [[ ! -L $RC_LOCAL ]] || return 1
    if [[ ! -e $RC_LOCAL ]]; then
        [[ $action == add ]] || return 0
        write_file "$STATE/rc-local.mode" new &&
            write_file "$RC_LOCAL" '#!/bin/sh' "$MARK" "$line" 'exit 0' &&
            chmod 755 "$RC_LOCAL"
        return
    fi
    [[ -f $RC_LOCAL ]] || return 1
    if [[ $action == add ]]; then
        if has_hook "$RC_LOCAL"; then
            grep -Fqx "$line" "$RC_LOCAL" && chmod u+x "$RC_LOCAL"
            return
        fi
        mode=unchanged
        if [[ ! -x $RC_LOCAL ]]; then mode=disabled; fi
        write_file "$STATE/rc-local.mode" "$mode" || return 1
    else
        has_hook "$RC_LOCAL" || return 0
        content=$(<"$RC_LOCAL")
        mode=''
        if [[ -f $STATE/rc-local.mode ]]; then read -r mode < "$STATE/rc-local.mode" || return 1; fi
        if [[ $mode == new && $content == "#!/bin/sh"$'\n'"$MARK"$'\n'"$line"$'\n''exit 0' ]]; then
            rm -f "$RC_LOCAL"
            return
        fi
    fi
    # 保留旧文件权限和内容，在常见的末尾 exit 0 之前插入恢复命令。
    cp -p "$RC_LOCAL" "$RC_LOCAL.ipv6-pool.new" || return 1
    if awk -v action="$action" -v mark="$MARK" -v hook="$line" '
        { rows[NR] = $0; if ($0 !~ /^[[:space:]]*(#.*)?$/) last = NR }
        END {
            before = NR + 1
            if (last && rows[last] ~ /^[[:space:]]*exit[[:space:]]+0([[:space:]]*(#.*)?)?$/) before = last
            for (i = 1; i <= NR + 1; i++) {
                if (action == "add" && i == before) { print mark; print hook }
                if (action == "remove" && rows[i] == mark && rows[i+1] == hook) { i++; removed++; continue }
                if (i <= NR) print rows[i]
            }
            if (action == "remove" && removed != 1) exit 1
        }
    ' "$RC_LOCAL" > "$RC_LOCAL.ipv6-pool.new" &&
        mv -f "$RC_LOCAL.ipv6-pool.new" "$RC_LOCAL"; then
        if [[ $action == add ]]; then chmod u+x "$RC_LOCAL"
        elif [[ $mode == disabled ]]; then chmod u-x "$RC_LOCAL"
        fi
    else
        rm -f "$RC_LOCAL.ipv6-pool.new"
        return 1
    fi
}

remove_systemd() {
    has_hook "$UNIT" || return 0
    if is_systemd; then systemctl disable ipv6-pool-restore.service --no-reload || return 1; fi
    rm -f "$UNIT" || return 1
    if is_systemd && ! systemctl daemon-reload; then
        error 'systemd 服务已从磁盘移除。当前管理器未能重载配置。'
    fi
}

install_boot() {
    if [[ ! -f ${BASH_SOURCE[0]} ]]; then
        error '请先将脚本保存到本地文件再运行，不支持通过管道直接执行。'
        return 1
    fi
    if [[ ! ${BASH_SOURCE[0]} -ef $RUNNER ]]; then
        if ! cp "${BASH_SOURCE[0]}" "$RUNNER.new" || ! chmod 700 "$RUNNER.new" ||
            ! mv -f "$RUNNER.new" "$RUNNER"; then
            error "无法复制开机恢复脚本到 $RUNNER。"
            return 1
        fi
    fi
    if is_systemd; then
        if install_systemd; then info '开机恢复已启用（systemd）。'; return 0; fi
        remove_systemd || return 1
    fi
    if is_openrc; then
        if install_openrc; then info '开机恢复已启用（OpenRC）。'; return 0; fi
        if has_hook "$OPENRC"; then rm -f "$OPENRC" || return 1; fi
    fi
    if edit_rc_local add; then
        info '开机恢复命令已写入 /etc/rc.local。'
        return 0
    fi
    error '无法写入开机恢复配置（/etc/rc.local）。'
    return 1
}

remove_boot() {
    remove_systemd || return 1
    if has_hook "$OPENRC"; then rm -f "$OPENRC" || return 1; fi
    if has_hook "$RC_LOCAL"; then edit_rc_local remove || return 1; fi
}

decode_base64() {
    local payload=${1//-/+}
    payload=${payload//_/\/}
    [[ $payload =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    if [[ $payload != *=* ]]; then
        case $(("${#payload}" % 4)) in
            1) return 1 ;;
            2) payload+='==' ;;
            3) payload+='=' ;;
        esac
    fi
    printf '%s' "$payload" | base64 -d
}

vmess_links() {
    local address address_lines=''
    if has python3; then
        decode_base64 "$vmess_payload" | python3 -c '
import base64, json, re, sys
profile = json.loads(sys.stdin.buffer.read().decode("utf-8"))
port = profile.get("port") if isinstance(profile, dict) else None
port_ok = (
    (isinstance(port, int) and not isinstance(port, bool) and 1 <= port <= 65535)
    or (isinstance(port, str) and re.fullmatch(r"[0-9]{1,5}", port) is not None and 1 <= int(port) <= 65535)
)
if (not isinstance(profile, dict) or not isinstance(profile.get("add"), str)
        or not profile["add"] or not isinstance(profile.get("id"), str)
        or not profile["id"] or not port_ok
        or not isinstance(profile.get("ps"), (str, type(None)))):
    sys.exit(1)
name = re.sub(sys.argv[1] + r"\Z", "", profile.get("ps") or "")
if (profile.get("tls") in ("tls", "reality") and not profile.get("sni")
        and not profile.get("host")):
    profile["sni"] = profile["add"].strip("[]")
for index, address in enumerate(sys.argv[2:], 1):
    profile["add"] = address
    profile["ps"] = (name + "-" if name else "") + "v6-{:02d}".format(index)
    data = json.dumps(profile, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    print("vmess://" + base64.b64encode(data.encode("utf-8")).decode("ascii"))
' "$V6_NAME_SUFFIX" "$@"
    else
        for address in "$@"; do address_lines+="$address"$'\n'; done
        decode_base64 "$vmess_payload" | jq -scr --arg addresses "$address_lines" --arg suffix "$V6_NAME_SUFFIX" '
            if length != 1 then error("expected one object") else .[0] end |
            if type != "object" or (.add | type != "string" or length == 0)
               or (.id | type != "string" or length == 0)
               or (
                   ((.port | type == "number" and . == floor and . >= 1 and . <= 65535)
                    or (.port | type == "string" and test("^[0-9]{1,5}$") and (sub("^0+"; "") | if length == 0 then 0 else tonumber end | . >= 1 and . <= 65535)))
                   | not
               )
               or ((.ps // "") | type != "string") or .ps == false
            then error("invalid profile") else . end |
            if (.tls == "tls" or .tls == "reality") and ((.sni // "") == "") and ((.host // "") == "")
            then .sni = (.add | sub("^\\["; "") | sub("\\]$"; "")) else . end |
            . as $profile |
            ((.ps // "") | sub($suffix + "\\z"; "") | if length == 0 then "" else . + "-" end) as $name |
            ($addresses | split("\n") | map(select(length > 0)) | to_entries[]) as $entry |
            ($entry.value) as $address |
            (($entry.key + 1) | tostring | if length < 2 then "0" + . else . end) as $number |
            ($profile | .add = $address | .ps = ($name + "v6-" + $number)) |
            "vmess://" + (tojson | @base64)
        '
    fi
}

valid_hysteria_ports() {
    local range first last
    local -a ranges
    [[ $1 =~ ^[0-9]{1,5}(-[0-9]{1,5})?(,[0-9]{1,5}(-[0-9]{1,5})?)*$ ]] || return 1
    IFS=, read -r -a ranges <<< "$1"
    for range in "${ranges[@]}"; do
        first=${range%-*}
        last=${range##*-}
        (( 10#$first >= 1 && 10#$first <= 10#$last && 10#$last <= 65535 )) || return 1
    done
}

append_link_parameter() {
    if [[ $link_tail != *\?* ]]; then link_tail+='?'
    elif [[ -n ${link_tail#*\?} && $link_tail != *\& ]]; then link_tail+='&'; fi
    link_tail+="$1=$2"
}

# 换掉连接地址时，保留原先隐式使用的 TLS 校验名称。
preserve_tls_name() {
    local host=$1 query='' name empty_sni replacement
    if [[ $link_tail == *\?* ]]; then query=${link_tail#*\?}; fi
    if [[ $query =~ (^|\&)[Ss][Nn][Ii]=[^\&]+ ]]; then return 0; fi

    name=${host//:/%3A}
    if [[ $query =~ (^|\&)[Pp][Ee][Ee][Rr]=([^\&]+) ]]; then name=${BASH_REMATCH[2]}; fi
    if [[ $query =~ (^|\&)([Ss][Nn][Ii])=($|\&) ]]; then
        empty_sni=${BASH_REMATCH[0]}
        replacement="${BASH_REMATCH[1]}${BASH_REMATCH[2]}=$name${BASH_REMATCH[3]}"
        link_tail="${link_tail%%\?*}?${query/"$empty_sni"/"$replacement"}"
    else
        append_link_parameter sni "$name"
    fi
}

parse_link() {
    local link=$1 body authority endpoint host after expanded query='' security='' ports old_parameter orig_port mport_raw
    link_error='' link_host='' link_udp_ports=()
    link_scheme=${link%%://*}
    body=${link#*://}
    if [[ -z $link_scheme || $link == "$body" ]]; then
        link_error='未识别到节点链接（缺少「协议://」前缀），请粘贴单条节点链接。'
        return 1
    fi
    if [[ -z $body ]]; then
        link_error='节点链接不完整，协议前缀后缺少内容。'
        return 1
    fi
    if [[ $link =~ [[:space:][:cntrl:]] ]]; then
        link_error='链接包含空格或控制字符。如果备注里有空格，请删除或替换为 %20 后重新粘贴。'
        return 1
    fi
    link_scheme=${link_scheme,,}
    case $link_scheme in
        vmess)
            if ! has python3 && ! has jq; then
                link_error='VMess 需要 python3 或 jq。你也可以粘贴其他受支持的协议链接。'
                return 1
            fi
            vmess_payload=$body
            if ! vmess_links >/dev/null 2>&1; then
                if [[ $body == *@* ]]; then
                    link_error='VMess 仅支持标准 Base64 JSON 格式（vmess://base64...）。'
                else
                    link_error='VMess 链接无效，Base64 解码失败或缺少有效的地址、端口或凭据配置。'
                fi
                return 1
            fi
            return 0
            ;;
        vless|trojan|hysteria2|hy2|ss|anytls|tuic) ;;
        hysteria)
            link_error='不支持 Hysteria v1（hysteria://），请使用 Hysteria 2（hysteria2:// 或 hy2://）。'
            return 1
            ;;
        *)
            link_error="不支持的协议「${link_scheme}://」。支持：vless、vmess、trojan、hysteria2/hy2、ss（SIP002）、anytls、tuic。"
            return 1
            ;;
    esac
    authority=${body%%[/?#]*}
    link_auth=${authority%@*}
    endpoint=${authority##*@}
    if [[ $authority != *@* ]]; then
        if [[ $link_scheme == ss ]]; then
            link_error='暂不支持不含 @ 的旧版 Base64 Shadowsocks 链接，请使用 SIP002 格式（ss://凭据@地址:端口）。'
        else
            link_error='链接缺少凭据或 @ 分隔符（格式应为 协议://凭据@地址:端口）。'
        fi
        return 1
    fi
    if [[ -z $link_auth ]]; then
        link_error='链接缺少凭据部分（@ 前不能为空）。'
        return 1
    fi
    if [[ $link_auth == *@* ]]; then
        link_error='凭据部分包含未转义的 @，请先将密码中的 @ 编码为 %40 后重新粘贴。'
        return 1
    fi
    if [[ $link_scheme == tuic ]]; then
        if [[ $link_auth != *:* || -z ${link_auth%%:*} || -z ${link_auth#*:} ]]; then
            link_error='TUIC v5 链接凭据格式无效，应为 uuid:password@地址:端口。'
            return 1
        fi
    fi
    if [[ $endpoint == \[* ]]; then
        if [[ ! $endpoint =~ ^\[([^]]+)\](:([^:]+))?$ ]]; then
            link_error='节点 IPv6 地址格式无效，请检查方括号和端口写法（如 [2001:db8::1]:443）。'
            return 1
        fi
        host=${BASH_REMATCH[1]}
        link_port=${BASH_REMATCH[3]}
        if [[ $host == *%25* ]]; then
            if [[ ! ${host#*%25} =~ ^[A-Za-z0-9_.-]+$ ]]; then
                link_error='节点 IPv6 地址的区域标识（%25 后）无效。'
                return 1
            fi
            host=${host%%\%25*}
        fi
        if ! expand_ipv6 "$host"; then
            link_error='节点 IPv6 地址无效，请检查方括号内的 IPv6 写法。'
            return 1
        fi
    else
        if [[ ! $endpoint =~ ^([A-Za-z0-9_][A-Za-z0-9_.-]*)(:([^:]+))?$ ]]; then
            link_error='节点地址格式无效，请检查域名、IPv4 或带方括号的 IPv6 地址。'
            return 1
        fi
        host=${BASH_REMATCH[1]}
        link_port=${BASH_REMATCH[3]}
        if [[ $host =~ ^[0-9.]+$ && $host == *.* ]] && ! ipv4_valid "$host"; then
            link_error='节点 IPv4 地址无效，请检查地址后重新粘贴。'
            return 1
        fi
    fi
    case $link_scheme in
        hysteria2|hy2)
            link_port=${link_port:-443}
            if ! valid_hysteria_ports "$link_port"; then
                link_error='Hysteria 2 端口无效，仅支持 1–65535 的单端口或有效跳跃范围（如 443、5000-6000）。'
                return 1
            fi
            ;;
        *)
            if [[ $link_scheme == anytls ]]; then link_port=${link_port:-443}; fi
            if [[ -z $link_port ]]; then
                link_error="协议 ${link_scheme}:// 缺少端口号（需为 1–65535 的整数）。"
                return 1
            fi
            if [[ ! $link_port =~ ^[0-9]{1,5}$ ]] || ! (( 10#$link_port >= 1 && 10#$link_port <= 65535 )); then
                link_error='节点端口无效，需为 1–65535 之间的整数。'
                return 1
            fi
            ;;
    esac
    after=${body#"$authority"}
    link_host=$host
    link_tail=${after%%#*}
    if [[ $link_tail == *\?* ]]; then query=${link_tail#*\?}; fi
    case $link_scheme in
        hysteria2|hy2)
            orig_port=$link_port
            # v2rayN/NG 需要主机后的单个端口，跳跃端口通过 mport 传递。
            if [[ $link_port == *[,-]* ]]; then
                add_link_udp_ports "$orig_port"
                ports=${link_port//,/%2C}
                link_port=${link_port%%[,-]*}
                if [[ $query =~ (^|\&)mport=[^\&]* ]]; then
                    old_parameter=${BASH_REMATCH[0]}
                    link_tail="${link_tail%%\?*}?${query/"$old_parameter"/"${BASH_REMATCH[1]}mport=$ports"}"
                else
                    append_link_parameter mport "$ports"
                fi
            else
                add_link_udp_ports "$orig_port"
                if [[ $query =~ (^|\&)mport=([^\&]+) ]]; then
                    mport_raw=${BASH_REMATCH[2]//%2[Cc]/,}
                    if valid_hysteria_ports "$mport_raw"; then
                        add_link_udp_ports "$mport_raw"
                    fi
                fi
            fi
            preserve_tls_name "$host"
            ;;
        tuic)
            add_link_udp_ports "$link_port"
            preserve_tls_name "$host"
            ;;
        anytls) preserve_tls_name "$host" ;;
        trojan|vless)
            if [[ $query =~ (^|\&)security=([^\&]*) ]]; then security=${BASH_REMATCH[2]}; fi
            if [[ ( $security == tls || $security == reality || ( $link_scheme == trojan && -z $security ) ) &&
                ! $query =~ (^|\&)(host|authority)=[^\&]+ ]]; then
                preserve_tls_name "$host"
            fi
            ;;
    esac
    link_name=''
    if [[ $after == *'#'* ]]; then link_name=${after#*#}; fi
    if [[ $link_name =~ ${V6_NAME_SUFFIX}$ ]]; then link_name=${link_name%"${BASH_REMATCH[0]}"}; fi
}

ask_count() {
    local entered
    while read -r -p '生成数量 [10，范围 1–100]：' entered; do
        entered=${entered:-10}
        if [[ $entered =~ ^[0-9]{1,3}$ ]] && (( 10#$entered >= 1 && 10#$entered <= 100 )); then
            count=$((10#$entered))
            return 0
        fi
        error '请输入 1 到 100 之间的整数。'
    done
    return 1
}

print_nodes() {
    info '--------------------'
    cat "$NODES" || return 1
    info '--------------------'
}

print_import_line() {
    local encoded
    encoded=$(base64 < "$NODES" | tr -d '\n') || return 1
    info 'v2rayN 单行导入串。复制分割线之间的全部字符，再到 v2rayN 主界面按 Ctrl+V。' \
        '--------------------' "$encoded" '--------------------'
}

warn_foreign_host() {
    local expanded _num _dev family cidr addr has_public_v4=0 matched_v4=0 v4_snapshot
    [[ -n ${link_host:-} ]] || return 0
    if [[ $link_host == *:* ]] && expand_ipv6 "$link_host"; then
        if [[ ! ${present[$expanded]+yes} ]]; then
            info "提示：原链接中的 IPv6（$link_host）不在本机网卡上，请确认没有贴错其他 VPS 的节点（贴错可选 2 重贴）。"
        fi
    elif ipv4_valid "$link_host"; then
        v4_snapshot=$(ip -o -4 addr show scope global 2>/dev/null) || return 0
        while read -r _num _dev family cidr _; do
            [[ $family == inet && $cidr == */* ]] || continue
            addr=${cidr%/*}
            if [[ $addr == "$link_host" ]]; then matched_v4=1; break; fi
            if ipv4_public "$addr"; then has_public_v4=1; fi
        done <<< "$v4_snapshot"
        if (( ! matched_v4 && has_public_v4 )); then
            info "提示：原链接中的 IPv4（$link_host）与本机公网 IPv4 不一致，若非中转/NAT 机器，请确认没有贴错节点（贴错可选 2 重贴）。"
        fi
    fi
}

read_node_link() {
    local link
    while read -r -p '粘贴一条原节点链接（回车取消）：' link; do
        link=${link%$'\r'}
        link=${link#"${link%%[![:space:]]*}"}
        link=${link%"${link##*[![:space:]]}"}
        [[ -n $link ]] || return 1
        if parse_link "$link"; then
            warn_foreign_host
            return 0
        fi
        error "${link_error:-链接无效，请检查后重新粘贴。}"
    done
    return 1
}

build_links() {
    local address serial name index=0
    if [[ $link_scheme == vmess ]]; then
        vmess_links "$@"
        return
    fi
    for address in "$@"; do
        printf -v serial 'v6-%02d' "$((++index))"
        name=${link_name:+$link_name-}$serial
        printf '%s\n' "$link_scheme://$link_auth@[$address]:$link_port$link_tail#$name"
    done
}

show_result() {
    print_import_line || return 1
    info "已保存到 $NODES。请确保防火墙已放行对应端口的 IPv6 流量。"
}

probe_ipv6_target() {
    local src=$1 target=$2
    if has curl; then
        curl -6 --interface "$src" --connect-timeout 2 -m 3 -s -o /dev/null -k "https://[$target]/"
    elif has ping; then
        ping -6 -c 1 -W 2 -I "$src" "$target" >/dev/null 2>&1
    elif has ping6; then
        ping6 -c 1 -W 2 -I "$src" "$target" >/dev/null 2>&1
    else
        return 2
    fi
}

# 用原生 IPv6 与新绑定地址做对比探测，识别“掩码为 /64 但宿主机仅放行单个 IPv6”或限额环境。
verify_pool_reachability() {
    local target address tested=0 failed_count=0 ok native_shown=${detected_ip_raw:-$detected_ip}
    local -a targets=(2606:4700:4700::1111 2001:4860:4860::8888 2620:fe::fe)
    local -a usable_targets=() samples=()
    local count=${#next_pool[@]}
    [[ -n $detected_ip && $count -gt 0 ]] || return 0
    if ! has curl && ! has ping && ! has ping6; then return 0; fi

    for target in "${targets[@]}"; do
        if probe_ipv6_target "$detected_ip" "$target"; then
            usable_targets+=("$target")
            (( ${#usable_targets[@]} >= 2 )) && break
        fi
    done
    # 原生 IPv6 自身无法连通任何探测目标（如无公网/离线测试/出站受限）时跳过，避免误杀。
    (( ${#usable_targets[@]} )) || return 0

    samples=("${next_pool[0]}")
    if (( count == 2 )); then
        samples+=("${next_pool[1]}")
    elif (( count >= 3 )); then
        samples+=("${next_pool[count / 2]}" "${next_pool[count - 1]}")
    fi

    info "正在验证新绑定的 IPv6 是否可连通外网（抽测 ${#samples[@]} 个地址）..."
    for address in "${samples[@]}"; do
        tested=$((tested + 1))
        ok=0
        for target in "${usable_targets[@]}"; do
            if probe_ipv6_target "$address" "$target"; then
                ok=1
                break
            fi
        done
        if (( ! ok )); then
            failed_count=$((failed_count + 1))
            # 连续 2 个不同新地址在多个公网目标上均超时，足以确认整段未放行，提前结束等待。
            if (( failed_count >= 2 && failed_count == tested )); then break; fi
        fi
    done

    if (( failed_count == tested )); then
        error "原生 IPv6（$native_shown）可连外网，但抽测的 ${tested} 个新绑定 IPv6 均无法连通。"
        error "这台 VPS 虽然网卡掩码为 /${mask}，但商家可能仅放行了面板分配的单个 IPv6，不支持自建多 IP 地址池（已自动撤销绑定）。"
        error "你可以直接把原节点地址改为原生 IPv6（[$native_shown]）单 IP 使用。"
        return 1
    fi
    if (( failed_count > 0 )); then
        error "抽测的 ${tested} 个新绑定 IPv6 中有 ${failed_count} 个无法连通外网，商家可能限制了同时可用的 IPv6 数量。"
        error "已自动撤销本次绑定，建议减少生成数量后重试。"
        return 1
    fi
    return 0
}

prepare_pool_commit() {
    local count=$1 result index
    local -a links=() records=()
    stage_pool "$count" || return 1
    verify_pool_reachability || return 1
    result=$(build_links "${next_pool[@]}") || return 1
    mapfile -t links <<< "$result"
    (( ${#links[@]} == ${#next_pool[@]} )) || return 1
    for index in "${!next_pool[@]}"; do
        records+=("${next_pool[index]}"$'\t'"${links[index]}")
    done
    install_boot && write_file "$TRANSITION" "${records[@]}"
}

generate() {
    local count fresh_init=0 initial_protected=0
    check_network || return 1
    if ! ask_count || ! read_node_link; then return 0; fi
    if [[ -z $device ]]; then fresh_init=1; fi
    init_pool && recover_pending && prune_owned || return 1
    initial_protected=${#protected[@]}
    if ! prepare_pool_commit "$count"; then
        if ! read_state || ! recover_pending || ! prune_owned; then
            error '候选地址未能完全清理，重新运行后可继续清理。'
        elif (( fresh_init && ! ${#pool[@]} && ! ${#owned[@]} && ${#protected[@]} == initial_protected )) &&
            [[ ! -e $PENDING && ! -e $TRANSITION ]]; then
            rm -f "$CONFIG" "$PROTECTED" "$IPS" "$OWNED" "$PROOFS" "$UDP_PORTS"
            device='' prefix='' mask='' protected=() udp_ports=() udp_port_set=()
        fi
        return 1
    fi
    finish_transition || return 1
    if ! prune_owned; then error '新地址池已保存，部分旧托管地址等待清理。'; fi
    record_link_udp_ports || return 1
    if (( ${#link_udp_ports[@]} )); then
        sync_udp_nat 1
    elif (( ${#udp_ports[@]} )); then
        sync_udp_nat 0
    fi
    show_result
}

reuse_pool() {
    local result
    local -a links=()
    if (( ! ${#pool[@]} )); then error '还没有已生成的 IPv6 地址，请先选 1。'; return 1; fi
    check_network || return 1
    read_node_link || return 0
    result=$(build_links "${pool[@]}") || return 1
    mapfile -t links <<< "$result"
    (( ${#links[@]} == ${#pool[@]} )) || return 1
    reconcile && install_boot && write_file "$NODES" "${links[@]}" || return 1
    record_link_udp_ports || return 1
    if (( ${#link_udp_ports[@]} )); then sync_udp_nat 1; fi
    show_result
}

cleanup() {
    if [[ -n $device ]]; then
        write_file "$IPS" && read_state && reconcile || return 1
    fi
    remove_udp_nat
    remove_boot || return 1
    local path
    for path in "$OWNED" "$IPS" "$PROOFS" "$PENDING" "$TRANSITION" "$UDP_PORTS" "$CONFIG" "$PROTECTED" "$NODES" "$RUNNER" "$STATE/rc-local.mode"; do
        rm -f "$path" "$path.new" || return 1
    done
    rmdir "$STATE" || return 1
    info '已移除托管地址、开机恢复和状态文件。'
}

menu() {
    local choice shown_prefix shown_mask
    while :; do
        if ! read_state || ! finish_transition; then die '无法载入地址池状态。'; fi
        detect_network || :
        shown_prefix=${prefix:-$detected_prefix}
        shown_mask=${mask:-$detected_mask}
        if [[ -n $shown_prefix ]]; then
            if [[ $shown_mask != 64 ]]; then shown_prefix+="::/64（掩码 /$shown_mask）"
            else shown_prefix+='::/64'; fi
        else
            shown_prefix=未检测到
        fi
        printf '\n网卡 %s | IPv6 网段 %s | 已管理 %d 个地址\n' "${device:-${detected_dev:-未检测到}}" \
            "$shown_prefix" "${#owned[@]}"
        if [[ -n $detection_error && -z $detected_prefix ]]; then
            error "$detection_error"
        fi
        info '1. 新建 IPv6 地址池并生成节点链接' '2. 用现有地址重新生成节点链接' \
            '3. 换一批地址并生成新节点链接' '4. 查看上次生成的节点链接' \
            '5. 删除脚本管理的地址并卸载' '0. 退出'
        read -r -p '请输入选项数字（0-5）：' choice || return 0
        case $choice in
            1) if (( ${#pool[@]} )); then error '已经有地址池。选 2 使用现有地址，选 3 更换地址。'
               else generate || error '生成未完成，可在菜单中继续操作。'; fi ;;
            2) reuse_pool || error '未能重新生成节点链接。' ;;
            3) generate || error '更换地址未完成，可在菜单中继续操作。' ;;
            4) if [[ ! -s $NODES ]]; then info '还没有生成过节点链接。'
               elif ! print_nodes || ! print_import_line; then error '未能读取上次生成的节点链接。'; fi ;;
            5) if cleanup; then return 0; else error '卸载未完成，可以重试。'; fi ;;
            0) return 0 ;;
            *) error '请选择 0 到 5。' ;;
        esac
    done
}

main() {
    local mode=${1:-menu} command file attempt
    case $mode in
        -h|--help) info '用法：bash ipv6-pool.sh [--restore | --help]'; return 0 ;;
        menu|--restore) (( $# <= 1 )) || die '参数过多。' ;;
        *) die '未知参数。请使用 --help。' ;;
    esac
    (( EUID == 0 )) || die '请使用 root 权限运行。'
    local version
    version=$(ip -V 2>&1) || version=''
    [[ $version == *iproute2* ]] ||
        die '需要完整版 iproute2。Alpine 可运行 apk add bash iproute2。'
    for command in awk grep od base64 tr chmod cp mv rm mkdir rmdir cat sleep; do
        has "$command" || die "缺少基础命令 $command。"
    done
    if ! has flock; then die '需要 flock 锁定地址池。Alpine 可运行 apk add flock。'; fi
    if ! read -r boot_id < /proc/sys/kernel/random/boot_id || [[ ! $boot_id =~ ^[0-9a-f-]{36}$ ]]; then
        die '无法读取 Linux 启动 ID。'
    fi
    if [[ $mode == --restore && ! -e $STATE ]]; then return 0; fi
    [[ ! -L $STATE ]] || die '状态目录不能是符号链接。'
    if ! mkdir -p "$STATE" || [[ ! -d $STATE || ! -O $STATE ]] || ! chmod 700 "$STATE"; then
        die "无法安全使用状态目录 $STATE。"
    fi
    exec 9< "$STATE" || die '无法打开状态目录。'
    flock -n 9 || die '已有另一个实例在操作地址池。'
    for file in "$CONFIG" "$PROTECTED" "$IPS" "$OWNED" "$PROOFS" "$PENDING" "$TRANSITION" "$UDP_PORTS" "$NODES" "$RUNNER" "$STATE/rc-local.mode"; do
        [[ ! -L $file && ! -L $file.new && ( ! -e $file || ( -f $file && -O $file ) ) &&
            ( ! -e $file.new || ( -f $file.new && -O $file.new ) ) ]] || die "状态文件不安全：$file"
    done
    if [[ $mode == --restore ]]; then
        if ! read_state || ! finish_transition; then die '无法载入地址池状态，停止恢复。'; fi
        [[ -n $device ]] || return 0
        if (( ${#pool[@]} )); then
            for ((attempt=0; attempt<15; attempt++)); do
                if check_network; then break; fi
                if (( attempt < 14 )); then sleep 2; fi
            done
            (( attempt < 15 )) || die '等待原生 IPv6 网络就绪超时。'
        fi
        reconcile || die '地址池恢复未完成。'
    else
        menu
    fi
}

main "$@"
