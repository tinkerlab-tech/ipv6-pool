# IPv6 节点池

在 Linux VPS 的原生 IPv6 网段上绑定一组 IPv6，把一条已有代理链接转换成可批量导入的节点链接。脚本执行完即退出。

## 一键部署

登录 VPS 的 root 终端，复制并运行下面的命令。仓库公开，下载无需登录 GitHub。

```bash
curl -fL https://raw.githubusercontent.com/tinkerlab-tech/ipv6-pool/main/ipv6-pool.sh -o /root/ipv6-pool.sh && bash /root/ipv6-pool.sh
```

有 `wget` 的系统也可使用以下命令。

```bash
wget -O /root/ipv6-pool.sh https://raw.githubusercontent.com/tinkerlab-tech/ipv6-pool/main/ipv6-pool.sh && bash /root/ipv6-pool.sh
```

选 **1** 生成地址池，输入数量或回车使用默认的 **10**，再粘贴现有节点链接。复制分割线之间的 Base64 单行导入串，在 v2rayN 主界面按一次 `Ctrl + V`，即可批量导入整组节点。终端可能自动折行，复制时请完整选中分割线之间的内容。[v2rayN 剪贴板导入说明](https://github.com/2dust/v2rayN/wiki/Description-of-some-ui)

之后运行 `bash /root/ipv6-pool.sh` 可重新打开菜单。已有节点可以选 **4** 重新显示单行导入串。

## 使用条件

- VPS 的 IPv6 默认出口网卡需要有可用的全局单播 IPv6，地址掩码为 `/64` 或 `/48`。使用 `/48` 时，生成地址位于原生地址所在的 `/64` 子网内，绑定沿用 `/48`。
- VPS 商家需将对应 IPv6 地址路由到你的实例。节点服务应监听 IPv6，系统和商家防火墙都需放行对应端口及传输协议。
- 需要 Bash 4.2+、完整版 `iproute2`、`flock` 和常见系统命令。Alpine 可运行 `apk add bash iproute2`，缺少 `flock` 时运行 `apk add flock`。下载命令使用 `curl` 或 `wget`，也可以直接上传 `ipv6-pool.sh`。
- 原生支持 VLESS、Trojan、Hysteria 2（`hysteria2://` 和 `hy2://`）及 Shadowsocks SIP002。VMess 需要 `python3` 或 `jq`。

## 管理地址池

| 菜单 | 操作 |
| --- | --- |
| 1 | 生成并绑定地址、配置开机恢复、输出单行导入串 |
| 2 | 保留现有地址，使用另一条链接重新生成节点 |
| 3 | 删除旧托管地址，生成并绑定全新地址 |
| 4 | 查看最近一次生成的逐条节点链接和单行导入串 |
| 5 | 清理托管地址、开机恢复和运行状态 |

状态目录为 `/var/lib/ipv6-pool/`，地址存于 `ips.list`，含节点凭据的逐条链接存于仅 root 可读写的 `nodes.txt`。单行导入串也包含这些凭据。开机恢复依次适配 systemd、OpenRC 和 `/etc/rc.local`。使用 `rc.local` 的系统需在启动时执行该文件。

需要立即恢复已有地址时，运行 `bash /root/ipv6-pool.sh --restore`。洗牌和卸载会检查绑定记录、原生地址快照、默认路由源地址以及当前绑定属性。如果进程恰好在内核绑定成功后、写入归属记录前中断，恢复时会将来源不明的地址保留为受保护地址。

## 验证

在具备 `unshare` 和网络管理权限的 Linux 上，可以在隔离的网络与挂载命名空间运行测试。systemd 和 OpenRC 测试使用模拟的服务管理命令。

```bash
sudo bash tests/lifecycle.sh rc.local
sudo bash tests/lifecycle.sh systemd
sudo bash tests/lifecycle.sh openrc
```
