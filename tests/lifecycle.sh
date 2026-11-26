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
        printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> /run/systemctl.calls' > /run/bin/systemctl
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
run 1 0 101 2 'trojan://user@example.test:99999' "$original" 4 0 > /run/first 2>&1
[[ $(wc -l < "$state/ips.list") -eq 2 && $(wc -l < "$state/nodes.txt") -eq 2 ]]
[[ $(stat -c '%a' "$state/nodes.txt") == 600 ]]
[[ $(grep -c 'vless://' /run/first) -eq 4 ]]
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
"$state/ipv6-pool.sh" --restore
test_ip "${old[0]}" 128
test_ip "${old[1]}" 128

run 2 'ss://YWVzLTEyOC1nY206dGVzdA@203.0.113.1:8388/?plugin=v2ray-plugin%3Bserver%3Dyes' 0 > /run/reused
grep -Fxq "ss://YWVzLTEyOC1nY206dGVzdA@[${old[0]}]:8388/?plugin=v2ray-plugin%3Bserver%3Dyes#v6-01" "$state/nodes.txt"
run 2 'trojan://secret%40test@example.test:0443?x=a/b+c%26#already' 0 > /run/reused
grep -Fxq "trojan://secret%40test@[${old[0]}]:0443?x=a/b+c%26#already-v6-01" "$state/nodes.txt"
run 2 'hy2://secret@[::ffff:192.0.2.1]:8443?sni=example.test&obfs-password=A%2BB#' 0 > /run/reused
grep -Fxq "hy2://secret@[${old[0]}]:8443?sni=example.test&obfs-password=A%2BB#v6-01" "$state/nodes.txt"

if command -v python3 >/dev/null; then
    vmess='{"v":"2","add":"example.test","port":"443","id":"test","ps":"a/b+c","sni":"example.test","extra":{"nested":true}}'
    encoded=$(printf '%s' "$vmess" | base64 | tr -d '\n=' | tr '+/' '-_')
    run 2 "vmess://$encoded" 0 > /run/reused
    python3 - "$state/nodes.txt" "${old[0]}" "$vmess" <<'PY'
import base64, json, sys
with open(sys.argv[1], encoding="ascii") as nodes:
    actual = json.loads(base64.b64decode(nodes.readline().strip().removeprefix("vmess://")))
expected = json.loads(sys.argv[3])
expected.update(add=sys.argv[2], ps="a/b+c-v6-01")
assert actual == expected
PY
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
test_ip "$native" 128
test_ip "${old[0]}" 128
if test_ip "$new" 128; then fail 'New managed address survived uninstall'; fi
case $backend in
    rc.local) cmp /etc/rc.local /run/rc.original; [[ ! -x /etc/rc.local ]] ;;
    systemd) [[ ! -e $unit ]]; grep -Fxq 'disable ipv6-pool-restore.service' /run/systemctl.calls ;;
    openrc) [[ ! -e $hook ]] ;;
esac

# /48 保留原生地址所在的 /64，绑定时沿用 /48 掩码。
ip -6 addr del "$native/64" dev "$dev"
ip -6 addr add 2402:1920:0:1234::2/48 dev "$dev" nodad
run 1 2 '' 0 > /run/subnet48
read -r address < "$state/ips.list"
[[ $address == 2402:1920:0000:1234:* ]]
ip -o -6 addr show dev "$dev" to "$address/128" | grep -Fq '/48'
ip -6 route replace default via fe80::1 dev "$dev" src "$address"
run 5 > /run/removed
test_ip 2402:1920:0:1234::2 128
test_ip "$address" 128
[[ ! -e $state ]]
bash "$script" --restore
printf 'IPv6 lifecycle passed (%s)\n' "$backend"
