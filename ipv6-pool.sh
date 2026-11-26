#!/bin/sh
# IPv6 节点池。直接运行或用 bash ipv6-pool.sh 启动。
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
    printf '%s\n' '此脚本需要 Bash。Alpine 可运行 apk add bash iproute2。' >&2
    exit 1
fi

set +x
set -o pipefail
export LC_ALL=C
umask 077

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
PENDING=$STATE/pending.ip
NODES=$STATE/nodes.txt
# 匹配备注末尾的旧池标记，也能清理过去重复追加的标记。
V6_NAME_SUFFIX='(^|-)v6(-([0-9]{2}|100))?(-v6(-([0-9]{2}|100))?)*'

declare -a pool=()
declare -A protected=() owned=() wanted=() present=() live=() route_sources=()
device='' prefix='' mask=''
detected_dev='' detected_prefix='' detected_mask='' detection_error=''
address_snapshot='' routes=''

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
valid_mask() { [[ $1 == 48 || $1 == 64 ]]; }

valid_pool_ip() {
    local address=$1 suffix
    [[ $address =~ ^([0-9a-f]{4}:){7}[0-9a-f]{4}$ && $address == "$prefix":* ]] || return 1
    suffix=${address#"$prefix":}
    [[ $suffix != 0000:0000:0000:0000 && $suffix != fdff:ffff:ffff:ff[89a-f][0-9a-f] ]]
}

read_state() {
    local address extra
    device='' prefix='' mask=''
    pool=() protected=() owned=() wanted=()
    if [[ ! -e $CONFIG ]]; then
        [[ ! -e $IPS && ! -e $OWNED && ! -e $PENDING ]]
        return
    fi
    read -r device prefix mask extra < "$CONFIG" || return 1
    valid_device "$device" && valid_mask "$mask" && [[ -z $extra ]] || return 1
    [[ $prefix =~ ^[23][0-9a-f]{3}(:[0-9a-f]{4}){3}$ ]] || return 1
    [[ -f $PROTECTED ]] || return 1
    while IFS= read -r address || [[ -n $address ]]; do
        [[ $address =~ ^([0-9a-f]{4}:){7}[0-9a-f]{4}$ ]] || return 1
        protected[$address]=1
    done < "$PROTECTED"
    if [[ -e $IPS ]]; then
        while IFS= read -r address || [[ -n $address ]]; do
            valid_pool_ip "$address" && [[ ! ${wanted[$address]+yes} ]] || return 1
            pool+=("$address")
            wanted[$address]=1
        done < "$IPS"
    fi
    if [[ -e $OWNED ]]; then
        while IFS= read -r address || [[ -n $address ]]; do
            valid_pool_ip "$address" || return 1
            owned[$address]=1
        done < "$OWNED"
    fi
    (( ${#pool[@]} <= 100 ))
}

scan_addresses() {
    local _number dev family cidr details expanded
    address_snapshot=$(ip -o -6 addr show) || return 1
    present=() live=()
    while read -r _number dev family cidr details; do
        [[ $family == inet6 ]] || continue
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
    detected_dev='' detected_prefix='' detected_mask=''
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
        [[ ${dev%%@*} == "$route_dev" && $family == inet6 && " $details " == *' scope global '* ]] || continue
        expand_ipv6 "${cidr%/*}" || continue
        [[ $expanded == [23]* && ! ${owned[$expanded]+yes} && ! ${wanted[$expanded]+yes} ]] || continue
        [[ " $details " != *' tentative '* && " $details " != *' dadfailed '* ]] || continue
        if [[ -n $source && $expanded != "$source" ]]; then continue; fi
        if [[ " $details " == *' deprecated '* && -z $source ]]; then continue; fi
        if [[ -z $first_mask ]]; then first_mask=${cidr##*/}; fi
        if valid_mask "${cidr##*/}"; then
            detected_prefix=${expanded%:*:*:*:*}
            detected_mask=${cidr##*/}
            return 0
        fi
    done <<< "$address_snapshot"
    if [[ -n $first_mask ]]; then
        detection_error="网卡 $route_dev 的原生 IPv6 掩码为 /${first_mask}，仅支持 /64 或 /48。"
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

# 只动已记账地址，并再次检查原生快照、显式默认源地址及绑定属性。
remove_owned() {
    local address=$1 details
    scan_routes && scan_addresses || return 1
    details=${live["$device/$address/$mask"]-}
    if [[ -n $details ]]; then
        if [[ ${protected[$address]+yes} || ${route_sources[$address]+yes} ||
            $details != *' scope global '* || $details != *' noprefixroute '* ||
            $details != *' valid_lft forever '* || ! $details =~ [[:space:]]preferred_lft\ 0(sec)?[[:space:]] ]]; then
            error "保留 $address，当前地址属性或路由用途已变化。"
        elif ! ip -6 addr del "$address/$mask" dev "$device"; then
            return 1
        fi
    fi
    unset 'owned[$address]'
    write_file "$OWNED" "${!owned[@]}"
}

recover_pending() {
    local address expanded
    [[ -e $PENDING ]] || return 0
    IFS= read -r address < "$PENDING" && valid_pool_ip "$address" || return 1
    scan_addresses || return 1
    if [[ ! ${owned[$address]+yes} && ${present[$address]+yes} ]]; then
        error "保留上次中断时出现的 $address，无法确认它的绑定来源。"
        protected[$address]=1
        write_file "$PROTECTED" "${!protected[@]}" || return 1
    fi
    rm -f "$PENDING"
}

bind_address() {
    local address=$1
    if [[ ${live["$device/$address/$mask"]+yes} ]]; then return 0; fi
    if [[ ${protected[$address]+yes} || ${present[$address]+yes} ]]; then
        error "地址 $address 已被保护或在其他接口/掩码上使用。"
        return 1
    fi
    write_file "$PENDING" "$address" || return 1
    # deprecated 避免抢占首选源地址。noprefixroute 保留原有前缀路由策略。
    if ! ip -6 addr add "$address/$mask" dev "$device" preferred_lft 0 noprefixroute; then
        recover_pending || return 1
        [[ ${live["$device/$address/$mask"]+yes} ]]
        return
    fi
    owned[$address]=1
    write_file "$OWNED" "${!owned[@]}" && rm -f "$PENDING"
}

wait_for_dad() {
    local attempt address details pending
    for ((attempt=0; attempt<=10; attempt++)); do
        scan_addresses || return 1
        pending=0
        for address in "${pool[@]}"; do
            details=${live["$device/$address/$mask"]-}
            if [[ -z $details || $details == *' dadfailed '* ]]; then
                error "地址 $address 未绑定或重复地址检测失败。"
                return 1
            fi
            if [[ $details == *' tentative '* ]]; then pending=1; fi
        done
        (( pending )) || return 0
        if (( attempt < 10 )); then sleep 1; fi
    done
    error '等待 IPv6 重复地址检测超时。'
    return 1
}

reconcile() {
    local address
    recover_pending || return 1
    for address in "${!owned[@]}"; do
        if [[ ! ${wanted[$address]+yes} ]]; then remove_owned "$address" || return 1; fi
    done
    (( ${#pool[@]} )) || return 0
    scan_addresses || return 1
    for address in "${pool[@]}"; do bind_address "$address" || return 1; done
    wait_for_dad
}

make_pool() {
    local count=$1 address suffix attempt
    local -a bytes next=()
    local -A chosen=()
    for ((attempt=0; attempt<count*20 && ${#next[@]}<count; attempt++)); do
        bytes=()
        read -r -a bytes <<< "$(od -An -v -tx1 -N8 /dev/urandom)"
        [[ ${bytes[*]} =~ ^[0-9a-f]{2}(\ [0-9a-f]{2}){7}$ ]] || return 1
        printf -v suffix '%s%s:%s%s:%s%s:%s%s' "${bytes[@]}"
        address=$prefix:$suffix
        valid_pool_ip "$address" || continue
        if [[ ${present[$address]+yes} || ${protected[$address]+yes} || ${wanted[$address]+yes} ||
            ${owned[$address]+yes} || ${chosen[$address]+yes} ]]; then continue; fi
        next+=("$address")
        chosen[$address]=1
    done
    (( ${#next[@]} == count )) || return 1
    write_file "$IPS" "${next[@]}" && read_state
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
    if is_systemd; then systemctl disable ipv6-pool-restore.service || return 1; fi
    rm -f "$UNIT" || return 1
    if is_systemd; then systemctl daemon-reload; fi
}

install_boot() {
    [[ -f ${BASH_SOURCE[0]} ]] || return 1
    if [[ ! ${BASH_SOURCE[0]} -ef $RUNNER ]]; then
        cp "${BASH_SOURCE[0]}" "$RUNNER.new" && chmod 700 "$RUNNER.new" &&
            mv -f "$RUNNER.new" "$RUNNER" || return 1
    fi
    if is_systemd; then
        if install_systemd; then info '开机恢复已启用（systemd）。'; return 0; fi
        remove_systemd || return 1
    fi
    if is_openrc; then
        if install_openrc; then info '开机恢复已启用（OpenRC）。'; return 0; fi
        if has_hook "$OPENRC"; then rm -f "$OPENRC" || return 1; fi
    fi
    edit_rc_local add && info '开机恢复命令已写入 /etc/rc.local。'
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
    local address addresses=''
    if has python3; then
        decode_base64 "$vmess_payload" | python3 -c '
import base64, json, re, sys
profile = json.loads(sys.stdin.buffer.read().decode("utf-8"))
if (not isinstance(profile, dict) or not isinstance(profile.get("add"), str)
        or not profile["add"] or not isinstance(profile.get("ps"), (str, type(None)))):
    sys.exit(1)
name = re.sub(sys.argv[1] + r"\Z", "", profile.get("ps") or "")
for index, address in enumerate(sys.argv[2:], 1):
    profile["add"] = address
    profile["ps"] = (name + "-" if name else "") + "v6-{:02d}".format(index)
    data = json.dumps(profile, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    print("vmess://" + base64.b64encode(data.encode("utf-8")).decode("ascii"))
' "$V6_NAME_SUFFIX" "$@"
    else
        for address in "$@"; do addresses+="$address"$'\n'; done
        decode_base64 "$vmess_payload" | jq -scr --arg addresses "$addresses" --arg suffix "$V6_NAME_SUFFIX" '
            if length != 1 then error("expected one object") else .[0] end |
            if type != "object" or (.add | type != "string" or length == 0)
               or ((.ps // "") | type != "string") or .ps == false
            then error("invalid profile") else . end |
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
        if [[ $link_tail != *\?* ]]; then link_tail+='?'
        elif [[ -n $query && $query != *\& ]]; then link_tail+='&'; fi
        link_tail+="sni=$name"
    fi
}

parse_link() {
    local link=$1 body authority endpoint host after expanded
    link_scheme=${link%%://*}
    body=${link#*://}
    [[ $link != "$body" && -n $body && ! $link =~ [[:space:][:cntrl:]] ]] || return 1
    case $link_scheme in
        vmess)
            if ! has python3 && ! has jq; then
                error 'VMess 需要 python3 或 jq。你也可以粘贴其他受支持的协议链接。'
                return 2
            fi
            vmess_payload=$body
            vmess_links >/dev/null 2>&1
            return
            ;;
        vless|trojan|hysteria2|hy2|ss|anytls|tuic) ;;
        *) return 1 ;;
    esac
    authority=${body%%[/?#]*}
    link_auth=${authority%@*}
    endpoint=${authority##*@}
    [[ -n $link_auth && $authority == *@* && $link_auth != *@* ]] || return 1
    if [[ $link_scheme == tuic ]]; then
        [[ $link_auth == *:* && -n ${link_auth%%:*} && -n ${link_auth#*:} ]] || return 1
    fi
    if [[ $endpoint == \[* ]]; then
        [[ $endpoint =~ ^\[([^]]+)\](:([0-9]{1,5}))?$ ]] || return 1
        host=${BASH_REMATCH[1]}
        link_port=${BASH_REMATCH[3]}
        if [[ $host == *%25* ]]; then
            [[ ${host#*%25} =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
            host=${host%%\%25*}
        fi
        expand_ipv6 "$host" || return 1
    else
        [[ $endpoint =~ ^([A-Za-z0-9_][A-Za-z0-9_.-]*)(:([0-9]{1,5}))?$ ]] || return 1
        host=${BASH_REMATCH[1]}
        link_port=${BASH_REMATCH[3]}
        if [[ $host =~ ^[0-9.]+$ && $host == *.* ]]; then ipv4_valid "$host" || return 1; fi
    fi
    if [[ -z $link_port && $link_scheme == anytls ]]; then link_port=443; fi
    [[ -n $link_port ]] || return 1
    (( 10#$link_port >= 1 && 10#$link_port <= 65535 )) || return 1
    after=${body#"$authority"}
    link_tail=${after%%#*}
    if [[ $link_scheme == anytls || $link_scheme == tuic ]]; then preserve_tls_name "$host"; fi
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

emit_nodes() {
    local link result address serial name index=0
    local -a links=()
    while read -r -p '粘贴一条原节点链接（回车取消）：' link; do
        link=${link%$'\r'}
        [[ -n $link ]] || return 0
        parse_link "$link"
        result=$?
        if (( result == 0 )); then
            if [[ $link_scheme == vmess ]]; then
                result=$(vmess_links "${pool[@]}") || { error 'VMess 转换失败，请检查链接。'; continue; }
                mapfile -t links <<< "$result"
            else
                for address in "${pool[@]}"; do
                    printf -v serial 'v6-%02d' "$((++index))"
                    name=${link_name:+$link_name-}$serial
                    links+=("$link_scheme://$link_auth@[$address]:$link_port$link_tail#$name")
                done
            fi
            (( ${#links[@]} == ${#pool[@]} )) && write_file "$NODES" "${links[@]}" || return 1
            print_import_line || return 1
            info "已保存到 $NODES。请确保防火墙已放行对应端口的 IPv6 流量。"
            return 0
        fi
        if (( result != 2 )); then error '链接无效，请检查协议、凭据、地址和端口后重新粘贴。'; fi
    done
}

generate() {
    local count
    check_network && ask_count && init_pool && make_pool "$count" &&
        reconcile && install_boot && emit_nodes
}

reuse_pool() {
    if (( ! ${#pool[@]} )); then error '还没有可复用的 IPv6 地址池。'; return 1; fi
    check_network && reconcile && install_boot && emit_nodes
}

cleanup() {
    if [[ -n $device ]]; then
        write_file "$IPS" && read_state && reconcile || return 1
    fi
    remove_boot || return 1
    local path
    for path in "$OWNED" "$IPS" "$PENDING" "$CONFIG" "$PROTECTED" "$NODES" "$RUNNER" "$STATE/rc-local.mode"; do
        rm -f "$path" "$path.new" || return 1
    done
    rmdir "$STATE" || return 1
    info '已移除托管地址、开机恢复和状态文件。'
}

menu() {
    local choice shown_prefix shown_mask
    while :; do
        read_state || die '状态文件无效，停止操作。'
        detect_network || :
        shown_prefix=${prefix:-$detected_prefix}
        shown_mask=${mask:-$detected_mask}
        if [[ -n $shown_prefix ]]; then shown_prefix+="::/$shown_mask"; else shown_prefix=未检测到; fi
        printf '\n网卡 %s | 前缀 %s | 已托管 %d\n' "${device:-${detected_dev:-未检测到}}" \
            "$shown_prefix" "${#owned[@]}"
        if [[ -n $detection_error && -z $detected_prefix ]]; then
            error "$detection_error"
        fi
        info '1. 一键生成 IPv6 池并裂变节点' '2. 复用现有 IPv6 池重新裂变' \
            '3. 一键洗牌换血' '4. 查看历史链接与单行导入串' '5. 一键清理并彻底卸载' '0. 退出'
        read -r -p '选择操作：' choice || return 0
        case $choice in
            1) if (( ${#pool[@]} )); then error '现有地址池可通过选项 2 复用，或通过选项 3 更换。'
               else generate || error '生成未完成，可在菜单中继续操作。'; fi ;;
            2) reuse_pool || error '复用未完成。' ;;
            3) generate || error '洗牌未完成，可在菜单中继续操作。' ;;
            4) if [[ ! -s $NODES ]]; then info '暂无历史节点链接。'
               elif ! print_nodes || ! print_import_line; then error '读取历史节点链接失败。'; fi ;;
            5) if cleanup; then return 0; else error '清理未完成，可以重试。'; fi ;;
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
    (( BASH_VERSINFO[0] > 4 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2 )) ||
        die '需要 Bash 4.2 或更新版本。Alpine 可运行 apk add bash iproute2。'
    local version
    version=$(ip -V 2>&1) || version=''
    [[ $version == *iproute2* ]] ||
        die '需要完整版 iproute2。Alpine 可运行 apk add bash iproute2。'
    for command in awk grep od base64 tr chmod cp mv rm mkdir rmdir cat sleep; do
        has "$command" || die "缺少基础命令 $command。"
    done
    if ! has flock; then die '需要 flock 锁定地址池。Alpine 可运行 apk add flock。'; fi
    if [[ $mode == --restore && ! -e $STATE ]]; then return 0; fi
    [[ ! -L $STATE ]] || die '状态目录不能是符号链接。'
    if ! mkdir -p "$STATE" || [[ ! -d $STATE || ! -O $STATE ]] || ! chmod 700 "$STATE"; then
        die "无法安全使用状态目录 $STATE。"
    fi
    exec 9< "$STATE" || die '无法打开状态目录。'
    flock -n 9 || die '已有另一个实例在操作地址池。'
    for file in "$CONFIG" "$PROTECTED" "$IPS" "$OWNED" "$PENDING" "$NODES" "$RUNNER" "$STATE/rc-local.mode"; do
        [[ ! -L $file && ! -L $file.new && ( ! -e $file || ( -f $file && -O $file ) ) &&
            ( ! -e $file.new || ( -f $file.new && -O $file.new ) ) ]] || die "状态文件不安全：$file"
    done
    if [[ $mode == --restore ]]; then
        read_state || die '状态文件无效，停止恢复。'
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
