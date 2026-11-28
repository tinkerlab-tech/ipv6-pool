#!/usr/bin/env bash
# 通过独立的网络与挂载命名空间测试，宿主网络、启动配置和状态目录不参与。
set -euo pipefail
export LC_ALL=C
if [[ ${1:-} != --inside ]]; then
    (( EUID == 0 )) || { printf '%s\n' 'Run with sudo.' >&2; exit 1; }
    exec unshare --mount --net --propagation private bash "$0" --inside "${1:-rc.local}"
fi
backend=$2
script=$(cd "$(dirname "$0")/.." && pwd)/ipv6-pool.sh
awk_bin=$(readlink -f "$(command -v awk)")
IPV6_POOL_TEST_OD=$(command -v od)
IPV6_POOL_TEST_IP=$(command -v ip)
IPV6_POOL_TEST_MV=$(command -v mv)
export IPV6_POOL_TEST_OD IPV6_POOL_TEST_IP IPV6_POOL_TEST_MV
mount -t tmpfs tmpfs /etc
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /var/lib
mkdir -p /run/bin
ln -s "$awk_bin" /run/bin/awk
export PATH=/run/bin:$PATH
show_logs() {
    local log
    for log in /run/{rejected,first,reused,shuffle,removed,subnet48}; do
        if [[ -f $log ]]; then printf '\n%s\n' "$log" >&2; cat "$log" >&2; fi
    done
}
trap show_logs ERR

state=/var/lib/ipv6-pool
dev=ipv6net
native=2402:1920::2
unit=/etc/systemd/system/ipv6-pool-restore.service
hook=/etc/local.d/ipv6-pool-restore.start

fail() { printf '%s\n' "$*" >&2; exit 1; }
test_ip() { ip -o -6 addr show dev "$dev" to "$1/$2" | grep -q inet6; }
run() { printf '%s\n' "$@" | bash "$script"; }

case $backend in
    rc.local)
        printf '%s\n' '#!/bin/sh' '# original' 'exit 0' > /etc/rc.local
        cp /etc/rc.local /run/rc.original
        ;;
    systemd)
        mkdir -p /run/systemd/system /etc/systemd/system /run/bin
        cat > /run/bin/systemctl <<'SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> /run/systemctl.calls
if [ "$1" = daemon-reload ] && [ -e /run/systemd.fail-reload ]; then exit 1; fi
SYSTEMCTL
        chmod +x /run/bin/systemctl
        ;;
    openrc)
        mkdir -p /etc/local.d /etc/init.d /run/bin
        printf '%s\n' '#!/bin/sh' 'exit 0' > /etc/init.d/local
        printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> /run/rc-update.calls' > /run/bin/rc-update
        chmod +x /run/bin/rc-update /etc/init.d/local
        ;;
    *) fail "Unknown boot backend: $backend" ;;
esac

ip link add "$dev" type dummy
ip link set "$dev" up
ip -6 addr add fe80::2/64 dev "$dev" nodad
ip -6 addr add "$native/128" dev "$dev" nodad
ip -6 route add default dev "$dev"
if ! run 1 0 > /run/rejected 2>&1; then cat /run/rejected >&2; fail 'Could not run menu'; fi
grep -q '/128' /run/rejected
[[ ! -e $state/ips.list ]]
ip -6 addr del "$native/128" dev "$dev"
ip -6 addr add "$native/64" dev "$dev" nodad

# 固定随机序列依次覆盖保留段、全零、原生地址以及池内重复。
cat > /run/bin/od <<'OD'
#!/bin/sh
if [ "$*" != '-An -v -tx1 -N8 /dev/urandom' ]; then exec "$IPV6_POOL_TEST_OD" "$@"; fi
step=0
if [ -r /run/od.step ]; then read -r step < /run/od.step; fi
echo "$((step + 1))" > /run/od.step
case $step in
    0) echo ' fd ff ff ff ff ff ff 80' ;;
    1) echo ' 00 00 00 00 00 00 00 00' ;;
    2) echo ' 00 00 00 00 00 00 00 02' ;;
    3|4) echo ' 00 00 00 00 00 00 12 34' ;;
    *) echo ' 00 00 00 00 00 00 56 78' ;;
esac
OD
chmod +x /run/bin/od

original='vless://b0e0796f-fb83-452b-9179-fecd0a5fb8a3@[2400::1]:443?security=reality&sni=example.test&pbk=ab%2B%2F%3D&sid=aa&flow=xtls-rprx-vision&x=a+b/c=d#Test%20node'
run 1 0 101 2 'trojan://user@example.test:99999' "$original-v6" 4 0 > /run/first 2>&1
[[ $(wc -l < "$state/ips.list") -eq 2 && $(wc -l < "$state/nodes.txt") -eq 2 ]]
[[ $(stat -c '%a' "$state/nodes.txt") == 600 ]]
[[ $(grep -c 'vless://' /run/first) -eq 2 ]]
grep -Fq '不在本机网卡上' /run/first
mapfile -t imports < <(grep -E '^[A-Za-z0-9+/]+={0,2}$' /run/first)
[[ ${#imports[@]} -eq 2 && ${imports[0]} == "${imports[1]}" ]]
printf '%s' "${imports[0]}" | base64 -d | cmp - "$state/nodes.txt"
mapfile -t old < "$state/ips.list"
mapfile -t links < "$state/nodes.txt"
[[ ${old[0]} == 2402:1920:0000:0000:0000:0000:0000:1234 ]]
[[ ${old[1]} == 2402:1920:0000:0000:0000:0000:0000:5678 ]]
rm /run/bin/od
for index in 0 1; do
    address=${old[index]}
    [[ $address == 2402:1920:0000:0000:* ]]
    ip -o -6 addr show dev "$dev" to "$address/128" | grep -E 'deprecated .*preferred_lft 0(sec)?' >/dev/null
    [[ ${links[index]} == "${original/"[2400::1]"/"[$address]"}-v6-0$((index + 1))" ]]
done
test_ip "$native" 128

case $backend in
    rc.local)
        [[ -x /etc/rc.local ]]
        [[ $(sed -n '4p' /etc/rc.local) == "$state/ipv6-pool.sh --restore || :" ]]
        ;;
    systemd)
        grep -Fxq 'After=network-online.target' "$unit"
        grep -Fxq 'Type=oneshot' "$unit"
        grep -Fxq 'enable ipv6-pool-restore.service' /run/systemctl.calls
        ;;
    openrc)
        [[ -x $hook ]]
        grep -Fxq 'add local default' /run/rc-update.calls
        ;;
esac

ip -6 addr del "${old[0]}/64" dev "$dev"
"$state/ipv6-pool.sh" --restore
# RHEL 系列可能通过名为 sh 的 Bash 启动开机恢复脚本。
ln -s "$(command -v bash)" /run/bin/sh
/run/bin/sh "$state/ipv6-pool.sh" --restore
test_ip "${old[0]}" 128
test_ip "${old[1]}" 128

run 2 'ss://YWVzLTEyOC1nY206dGVzdA@203.0.113.1:8388/?plugin=v2ray-plugin%3Bserver%3Dyes' 0 > /run/reused
grep -Fxq "ss://YWVzLTEyOC1nY206dGVzdA@[${old[0]}]:8388/?plugin=v2ray-plugin%3Bserver%3Dyes#v6-01" "$state/nodes.txt"
run 2 'trojan://secret%40test@example.test:0443?x=a/b+c%26#already-v6-v6-02' 0 > /run/reused
grep -Fxq "trojan://secret%40test@[${old[0]}]:0443?x=a/b+c%26&sni=example.test#already-v6-01" "$state/nodes.txt"
run 2 'hy2://secret@[::ffff:192.0.2.1]:8443?sni=example.test&obfs-password=A%2BB#v6-01' 0 > /run/reused
grep -Fxq "hy2://secret@[${old[0]}]:8443?sni=example.test&obfs-password=A%2BB#v6-01" "$state/nodes.txt"
run 2 'hysteria2://secret@example.test/?insecure=0#Default' 0 > /run/reused
grep -Fxq "hysteria2://secret@[${old[0]}]:443/?insecure=0&sni=example.test#Default-v6-01" "$state/nodes.txt"
run 2 'not-a-link' \
    'ssr://example.test:443' \
    'hysteria://example.test:443' \
    'ss://YWVzLTEyOC1nY206dGVzdEAxLjIuMy40OjgzODg=#Legacy' \
    'tuic://onlyuuid@example.test:443#NoPass' \
    'vless://b0e0796f-fb83-452b-9179-fecd0a5fb8a3@example.test:443#Has Space' \
    'hy2://secret@example.test:6000-5000/#Invalid' \
    $'  HY2://secret@[2001:db8::2]:443,5000-6000/?sni=example.test#Hop \r' 0 > /run/reused 2>&1
grep -Fq '未识别到节点链接' /run/reused
grep -Fq '不支持的协议「ssr://」' /run/reused
grep -Fq '不支持 Hysteria v1' /run/reused
grep -Fq 'SIP002' /run/reused
grep -Fq 'TUIC v5 链接凭据格式无效' /run/reused
grep -Fq '链接包含空格或控制字符' /run/reused
grep -Fq 'Hysteria 2 端口无效' /run/reused
grep -Fxq "hy2://secret@[${old[0]}]:443/?sni=example.test&mport=443%2C5000-6000#Hop-v6-01" "$state/nodes.txt"
run 2 'vless://b0e0796f-fb83-452b-9179-fecd0a5fb8a3@example.test:443?security=tls#TLS' 0 > /run/reused
grep -Fxq "vless://b0e0796f-fb83-452b-9179-fecd0a5fb8a3@[${old[0]}]:443?security=tls&sni=example.test#TLS-v6-01" "$state/nodes.txt"
run 2 'vless://b0e0796f-fb83-452b-9179-fecd0a5fb8a3@example.test:9443?type=kcp#KCP' 0 > /run/reused
grep -Fxq '9443' "$state/udp-ports.list"
run 2 'anytls://secret%3A%40@example.test/?insecure=0&vendor=q%3D%2B#AnyTLS' 0 > /run/reused
grep -Fxq "anytls://secret%3A%40@[${old[0]}]:443/?insecure=0&vendor=q%3D%2B&sni=example.test#AnyTLS-v6-01" "$state/nodes.txt"
run 2 'anytls://secret@198.51.100.1:8443?sni=&peer=tls.example.test&insecure=0#AnyTLS' 0 > /run/reused
grep -Fxq "anytls://secret@[${old[0]}]:8443?sni=tls.example.test&peer=tls.example.test&insecure=0#AnyTLS-v6-01" "$state/nodes.txt"
run 2 'anytls://secret@[2001:db8::1]#AnyTLS' 0 > /run/reused
grep -Fxq "anytls://secret@[${old[0]}]:443?sni=2001%3Adb8%3A%3A1#AnyTLS-v6-01" "$state/nodes.txt"
run 2 'tuic://00000000-0000-4000-8000-000000000001:secret%40test@[2001:db8::1]:8443/?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni=tls.example.test#TUIC' 0 > /run/reused
grep -Fxq "tuic://00000000-0000-4000-8000-000000000001:secret%40test@[${old[0]}]:8443/?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni=tls.example.test#TUIC-v6-01" "$state/nodes.txt"
run 2 'tuic://00000000-0000-4000-8000-000000000001:secret@example.test:443?vendor=q?#TUIC' 0 > /run/reused
grep -Fxq "tuic://00000000-0000-4000-8000-000000000001:secret@[${old[0]}]:443?vendor=q?&sni=example.test#TUIC-v6-01" "$state/nodes.txt"
grep -Fxq '8388' "$state/udp-ports.list"
grep -Fxq '8443' "$state/udp-ports.list"
grep -Fxq '443' "$state/udp-ports.list"
grep -Fxq '5000-6000' "$state/udp-ports.list"
if command -v nft >/dev/null; then
    nft list table ip6 ipv6_pool_udp | grep -Fq 'udp dport 8443 dnat to'
    nft list table ip6 ipv6_pool_udp | grep -Fq 'udp dport 443 dnat to'
    nft list table ip6 ipv6_pool_udp | grep -Fq 'udp dport 5000-6000 dnat to'
    nft delete table ip6 ipv6_pool_udp
    "$state/ipv6-pool.sh" --restore
    nft list table ip6 ipv6_pool_udp | grep -Fq 'udp dport 5000-6000 dnat to'
fi
if command -v ip6tables >/dev/null; then
    bash_bin=$(command -v bash)
    mkdir -p /run/ip6t-bin
    for tool in bash ip flock awk grep od base64 tr chmod cp mv rm mkdir rmdir cat sleep ip6tables systemctl rc-update; do
        if tool_path=$(command -v "$tool" 2>/dev/null); then
            ln -sf "$tool_path" "/run/ip6t-bin/$tool"
        fi
    done
    printf '%s\n' 2 'hysteria2://secret@example.test:13411?obfs=salamander&obfs-password=abc#HY2' 0 |
        PATH=/run/ip6t-bin "$bash_bin" "$script" > /run/reused 2>&1
    grep -Fxq '13411' "$state/udp-ports.list"
    ip6tables -t nat -C PREROUTING -j IPV6_POOL_UDP
    ip6tables -t nat -S IPV6_POOL_UDP | grep -Fq -- '--dport 13411 -j DNAT'
    ip6tables -t nat -S IPV6_POOL_UDP | grep -Fq -- '--dport 5000:6000 -j DNAT'
    rm -rf /run/ip6t-bin
    if command -v nft >/dev/null; then
        "$state/ipv6-pool.sh" --restore
        nft list table ip6 ipv6_pool_udp | grep -Fq 'udp dport 13411 dnat to'
        if ip6tables -t nat -S IPV6_POOL_UDP >/dev/null 2>&1; then fail 'Stale ip6tables chain survived nft restore'; fi
    fi
fi

if command -v python3 >/dev/null; then
    vmess='{"v":"2","add":"example.test","port":"443","id":"test","ps":"a/b+c-v6-prod-v6-100","tls":"tls","extra":{"nested":true}}'
    encoded=$(printf '%s' "$vmess" | base64 | tr -d '\n=' | tr '/+' '_-')
    run 2 "vmess://$encoded" 0 > /run/reused
    python3 - "$state/nodes.txt" "${old[0]}" "$vmess" <<'PY'
import base64, json, sys
with open(sys.argv[1], encoding="ascii") as nodes:
    line = nodes.readline().strip()
    assert line.startswith("vmess://")
    actual = json.loads(base64.b64decode(line[len("vmess://"):]))
expected = json.loads(sys.argv[3])
expected.update(add=sys.argv[2], ps="a/b+c-v6-prod-v6-01", sni="example.test")
assert actual == expected
PY
fi

if command -v jq >/dev/null; then
    bash_bin=$(command -v bash)
    mkdir -p /run/jq-bin
    for tool in bash ip flock awk grep od base64 tr chmod cp mv rm mkdir rmdir cat sleep jq systemctl rc-update; do
        if tool_path=$(command -v "$tool" 2>/dev/null); then
            ln -sf "$tool_path" "/run/jq-bin/$tool"
        fi
    done
    vmess_int='{"v":"2","add":"example.test","port":443,"id":"test","ps":"jq-v6-02","tls":"tls","extra":{"nested":true}}'
    encoded_int=$(printf '%s' "$vmess_int" | base64 | tr -d '\n')
    bad_vmess_port=$(printf '%s' '{"v":"2","add":"example.test","port":true,"id":"test"}' | base64 | tr -d '\n')
    vmess_zero_port='{"v":"2","add":"example.test","port":"07443","id":"test","ps":"zero","net":"KCP"}'
    encoded_zero=$(printf '%s' "$vmess_zero_port" | base64 | tr -d '\n')
    printf '%s\n' 2 "vmess://uuid@example.test:443" "vmess://$bad_vmess_port" "vmess://$encoded_int" 0 |
        PATH=/run/jq-bin "$bash_bin" "$script" > /run/reused 2>&1
    grep -Fq 'Base64 JSON' /run/reused
    grep -Fq 'VMess 链接无效' /run/reused
    if command -v python3 >/dev/null; then
        python3 - "$state/nodes.txt" "${old[0]}" "$vmess_int" <<'PY'
import base64, json, sys
with open(sys.argv[1], encoding="ascii") as nodes:
    line = nodes.readline().strip()
    assert line.startswith("vmess://")
    actual = json.loads(base64.b64decode(line[len("vmess://"):]))
expected = json.loads(sys.argv[3])
expected.update(add=sys.argv[2], ps="jq-v6-01", sni="example.test")
assert actual == expected
PY
    fi
    printf '%s\n' 2 "vmess://$encoded_zero" 0 | PATH=/run/jq-bin "$bash_bin" "$script" > /run/reused 2>&1
    grep -Fq 'vmess://' "$state/nodes.txt"
    grep -Fxq '7443' "$state/udp-ports.list"
    rm -f /run/jq-bin/jq
    printf '%s\n' 2 "vmess://$encoded_int" '' 0 | PATH=/run/jq-bin "$bash_bin" "$script" > /run/reused 2>&1
    grep -Fq 'VMess 需要 python3 或 jq' /run/reused
    rm -rf /run/jq-bin
fi

# 人工接管地址后，洗牌只清除仍符合脚本绑定属性的地址。
ip -6 addr change "${old[0]}/64" dev "$dev" preferred_lft forever noprefixroute
ip -6 route del default dev "$dev"
ip -6 route add default via fe80::1 dev "$dev"
run 3 1 'hysteria2://secret@example.test:443?sni=example.test' 0 > /run/shuffle 2>&1
test_ip "${old[0]}" 128
if test_ip "${old[1]}" 128; then fail 'Old managed address survived shuffle'; fi
read -r new < "$state/ips.list"
[[ $new != "${old[0]}" && $new != "${old[1]}" ]]
test_ip "$new" 128
run 5 > /run/removed
[[ ! -e $state ]]
if command -v nft >/dev/null && nft list table ip6 ipv6_pool_udp >/dev/null 2>&1; then fail 'nft UDP NAT table survived uninstall'; fi
if command -v ip6tables >/dev/null && ip6tables -t nat -S IPV6_POOL_UDP >/dev/null 2>&1; then fail 'ip6tables UDP NAT chain survived uninstall'; fi
test_ip "$native" 128
test_ip "${old[0]}" 128
if test_ip "$new" 128; then fail 'New managed address survived uninstall'; fi
case $backend in
    rc.local) cmp /etc/rc.local /run/rc.original; [[ ! -x /etc/rc.local ]] ;;
    systemd) [[ ! -e $unit ]]; grep -Fxq 'disable ipv6-pool-restore.service --no-reload' /run/systemctl.calls ;;
    openrc) [[ ! -e $hook ]] ;;
esac

# /56 与 /48 均保留原生地址所在的 /64，绑定时沿用原掩码。
ip -6 addr del "$native/64" dev "$dev"
ip -6 addr add 2402:1920:0:5600::2/56 dev "$dev" nodad
run 1 1 "$original" 0 > /run/subnet48
grep -Fq '掩码 /56' /run/subnet48
read -r address < "$state/ips.list"
[[ $address == 2402:1920:0000:5600:* ]]
ip -o -6 addr show dev "$dev" to "$address/128" | grep -Fq '/56'
run 5 > /run/removed
[[ ! -e $state ]]
if command -v nft >/dev/null && nft list table ip6 ipv6_pool_udp >/dev/null 2>&1; then fail 'nft UDP NAT table survived uninstall'; fi
if command -v ip6tables >/dev/null && ip6tables -t nat -S IPV6_POOL_UDP >/dev/null 2>&1; then fail 'ip6tables UDP NAT chain survived uninstall'; fi
ip -6 addr del 2402:1920:0:5600::2/56 dev "$dev"

ip -6 addr add 2402:1920:0:1234::2/48 dev "$dev" nodad
run 1 2 "$original" 0 > /run/subnet48
read -r address < "$state/ips.list"
[[ $address == 2402:1920:0000:1234:* ]]
ip -o -6 addr show dev "$dev" to "$address/128" | grep -Fq '/48'
ip -6 route replace default via fe80::1 dev "$dev" src "$address"
run 5 > /run/removed
test_ip 2402:1920:0:1234::2 128
test_ip "$address" 128
[[ ! -e $state ]]
bash "$script" --restore

# 故障与迁移专项。其余启动后端已经跑过正常生命周期。
if [[ $backend == rc.local ]]; then
    ip -6 route replace default dev "$dev"
    run 1 2 "$original" 0 > /run/first
    mapfile -t before < "$state/ips.list"
    cp "$state/ips.list" /run/ips.before
    cp "$state/nodes.txt" /run/nodes.before
    run 3 2 '' 0 > /run/shuffle
    cmp "$state/ips.list" /run/ips.before
    cmp "$state/nodes.txt" /run/nodes.before

    # 第一条候选已成功绑定，第二条失败时要撤销第一条。
    ip -o -6 addr show dev "$dev" | awk '{print $4}' | sort > /run/network.before
    cat > /run/bin/ip <<'IP'
#!/bin/sh
if [ "$1 $2 $3" = '-6 addr add' ]; then
    [ ! -e /run/candidate.added ] || exit 2
    touch /run/candidate.added
fi
exec "$IPV6_POOL_TEST_IP" "$@"
IP
    chmod +x /run/bin/ip
    run 3 2 "$original" 0 > /run/shuffle 2>&1
    grep -Fq '更换地址未完成' /run/shuffle
    cmp "$state/ips.list" /run/ips.before
    cmp "$state/nodes.txt" /run/nodes.before
    ip -o -6 addr show dev "$dev" | awk '{print $4}' | sort | cmp - /run/network.before
    rm /run/bin/ip

    # 新池已经通过验证时，注入两份对外文件之间的提交故障。
    cat > /run/bin/mv <<'MV'
#!/bin/sh
if [ "$3" = /var/lib/ipv6-pool/nodes.txt ]; then exit 2; fi
exec "$IPV6_POOL_TEST_MV" "$@"
MV
    chmod +x /run/bin/mv
    if run 3 2 "$original" 0 > /run/shuffle 2>&1; then fail 'Incomplete commit should fail'; fi
    [[ -s $state/pool.next ]]
    cmp "$state/nodes.txt" /run/nodes.before
    test_ip "${before[0]}" 128
    test_ip "${before[1]}" 128
    rm /run/bin/mv
    bash "$script" --restore
    [[ ! -e $state/pool.next ]]
    if test_ip "${before[0]}" 128 || test_ip "${before[1]}" 128; then fail 'Old pool survived completed commit'; fi
    read -r rebuilt < "$state/ips.list"
    grep -Fq "@[$rebuilt]" "$state/nodes.txt"

    # 模拟重新配置同一个 IPv6，以及旧版本没有归属凭证的地址。
    mapfile -t current < "$state/ips.list"
    ip -6 addr del "${current[0]}/48" dev "$dev"
    sleep 0.1
    ip -6 addr add "${current[0]}/48" dev "$dev" preferred_lft 0 noprefixroute
    awk -v ip="${current[1]}" '$1 != ip' "$state/ownership.list" > /run/proofs
    cat /run/proofs > "$state/ownership.list"
    run 5 > /run/removed 2>&1
    test_ip "${current[0]}" 128
    test_ip "${current[1]}" 128
    [[ ! -e $state ]]

    # 在另一个网络命名空间里绑定冲突地址，触发真实的内核 DAD。
    ip link del "$dev"
    ip link add "$dev" type veth peer name ipv6peer
    ip link set "$dev" up
    ip -6 addr add 2001:db8:10::2/64 dev "$dev" nodad
    ip -6 route add default dev "$dev"
    unshare --net bash -c 'touch /run/peer.ready; exec sleep 120' &
    peer_pid=$!
    trap 'kill "$peer_pid" 2>/dev/null || :; wait "$peer_pid" 2>/dev/null || :' EXIT
    for _attempt in {1..30}; do
        if [[ -e /run/peer.ready ]]; then break; fi
        sleep 0.05
    done
    [[ -e /run/peer.ready ]]
    ip link set ipv6peer netns "$peer_pid"
    nsenter -t "$peer_pid" -n ip link set ipv6peer up
    nsenter -t "$peer_pid" -n ip -6 addr add 2001:db8:10::1234/64 dev ipv6peer nodad
    cat > /run/bin/od <<'OD'
#!/bin/sh
if [ "$*" != '-An -v -tx1 -N8 /dev/urandom' ]; then exec "$IPV6_POOL_TEST_OD" "$@"; fi
if [ ! -e /run/dad.first ]; then
    touch /run/dad.first
    printf '%s\n' ' 00 00 00 00 00 00 12 34'
else
    printf '%s\n' ' 00 00 00 00 00 00 56 78'
fi
OD
    chmod +x /run/bin/od
    run 1 1 "$original" 0 > /run/first 2>&1
    grep -Fq '将补抽新地址' /run/first
    rm /run/bin/od
    if test_ip 2001:db8:10::1234 128; then fail 'Conflicting candidate survived automatic replacement'; fi
    read -r published < "$state/ips.list"
    [[ $published == 2001:0db8:0010:0000:0000:0000:0000:5678 ]]
    test_ip "$published" 128

    # 已经发布的地址应在冲突消失后原样恢复。
    cp "$state/nodes.txt" /run/nodes.before
    ip -6 addr del "$published/64" dev "$dev"
    nsenter -t "$peer_pid" -n ip -6 addr add "$published/64" dev ipv6peer nodad
    if bash "$script" --restore > /run/shuffle 2>&1; then fail 'Restore should report real DAD conflict'; fi
    grep -Fq '重复地址检测失败' /run/shuffle
    nsenter -t "$peer_pid" -n ip -6 addr del "$published/64" dev ipv6peer
    bash "$script" --restore
    ip -o -6 addr show dev "$dev" to "$published/128" | grep -qv dadfailed
    cmp "$state/nodes.txt" /run/nodes.before
    run 5 > /run/removed

    # 模拟公网对比探测：商家仅放行原生单 IP、部分限额以及全段放行。
    cat > /run/bin/curl <<'CURL'
#!/bin/sh
src=''
while [ $# -gt 0 ]; do
    if [ "$1" = '--interface' ]; then
        src=$2
        shift 2
        continue
    fi
    shift
done
mode=$(cat /run/curl.mode)
case $mode in
    single)
        [ "$src" = '2001:0db8:0010:0000:0000:0000:0000:0002' ] && exit 0
        exit 28
        ;;
    partial)
        [ "$src" = '2001:0db8:0010:0000:0000:0000:0000:0002' ] && exit 0
        if [ ! -e /run/curl.first_new ]; then
            printf '%s\n' "$src" > /run/curl.first_new
            exit 0
        fi
        first=$(cat /run/curl.first_new)
        [ "$src" = "$first" ] && exit 0
        exit 28
        ;;
    all)
        exit 0
        ;;
esac
exit 28
CURL
    chmod +x /run/bin/curl
    printf '%s\n' single > /run/curl.mode
    run 1 3 "$original" 0 > /run/first 2>&1
    grep -Fq '商家可能仅放行了面板分配的单个 IPv6' /run/first
    [[ ! -e $state/pool.conf && ! -e $state/ips.list ]]
    [[ $(ip -o -6 addr show dev "$dev" scope global | wc -l) -eq 1 ]]

    printf '%s\n' partial > /run/curl.mode
    rm -f /run/curl.first_new
    run 1 3 "$original" 0 > /run/first 2>&1
    grep -Fq '限制了同时可用的 IPv6 数量' /run/first
    [[ ! -e $state/pool.conf && ! -e $state/ips.list ]]
    [[ $(ip -o -6 addr show dev "$dev" scope global | wc -l) -eq 1 ]]

    printf '%s\n' all > /run/curl.mode
    run 1 3 "$original" 0 > /run/first 2>&1
    [[ $(wc -l < "$state/ips.list") -eq 3 ]]
    run 5 > /run/removed
    rm -f /run/bin/curl /run/curl.mode /run/curl.first_new
elif [[ $backend == systemd ]]; then
    ip -6 route replace default dev "$dev"
    touch /run/systemd.fail-reload
    run 1 1 "$original" 0 > /run/first 2>&1
    [[ ! -e $unit && -x /etc/rc.local && -s $state/nodes.txt ]]
    grep -Fq '当前管理器未能重载配置' /run/first
    run 5 > /run/removed
fi
printf 'IPv6 lifecycle passed (%s)\n' "$backend"
