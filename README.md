# IPv6 节点池

在 Linux VPS 的原生 IPv6 网段上绑定一组 IPv6，把一条已有代理链接转换成可批量导入的节点链接。脚本执行完即退出。

## 一键部署

登录 VPS 的 root 终端，复制并运行下面的命令。仓库公开，下载无需登录 GitHub。

```bash
curl -fL https://github.com/tinkerlab-tech/ipv6-pool/raw/main/ipv6-pool.sh -o v6.sh && bash v6.sh
```

有 `wget` 的系统也可使用以下命令。

```bash
wget -O v6.sh https://github.com/tinkerlab-tech/ipv6-pool/raw/main/ipv6-pool.sh && bash v6.sh
```

选 **1**，输入数量或回车使用默认的 **10**，再粘贴现有节点链接。脚本收到有效链接后绑定地址。复制分割线之间的 Base64 单行导入串，在 v2rayN 主界面按一次 `Ctrl + V`，即可批量导入整组节点。终端可能自动折行，复制时请完整选中分割线之间的内容。[v2rayN 剪贴板导入说明](https://github.com/2dust/v2rayN/wiki/Description-of-some-ui)

之后运行 `bash v6.sh` 可重新打开菜单。已有节点可以选 **4** 重新显示单行导入串。

生成节点时，备注末尾已有的 `-v6` 或 `-v6-序号` 会替换成新序号。

## 使用条件

- VPS 的 IPv6 默认出口网卡需要有可用的全局单播 IPv6，地址掩码为 `/48` 至 `/64`（如 `/64`、`/56`、`/48`）。掩码小于 `/64` 时，生成地址位于原生地址所在的 `/64` 子网内，绑定沿用原掩码。
- VPS 商家需将对应 IPv6 地址路由到你的实例。新建或更换地址池时，脚本会自动用原生 IPv6 与抽样的新地址做公网连通性对比；若商家仅放行单个 IPv6 或限制可用数量，会自动撤销绑定并提示。节点服务应监听 IPv6，系统和商家防火墙都需放行对应端口及传输协议。
- 需要 Bash 4.2+、完整版 `iproute2`、`flock` 和常见系统命令。Alpine 可运行 `apk add bash iproute2`，缺少 `flock` 时运行 `apk add flock`。下载命令使用 `curl` 或 `wget`，也可以直接上传 `ipv6-pool.sh`。
- 原生支持 VLESS、Trojan、Hysteria 2（`hysteria2://` 和 `hy2://`）、Shadowsocks SIP002、AnyTLS（`anytls://`）和 TUIC v5（`tuic://`）。VMess 需要 `python3` 或 `jq`。
- AnyTLS 和 Hysteria 2 省略端口时使用 443。Hysteria 2 地址里的跳跃端口列表或范围会写入 v2rayN 和 v2rayNG 可识别的 `mport` 参数。Trojan、AnyTLS、TUIC、Hysteria 2 和启用 TLS 的 VLESS、VMess 会沿用原先的校验名称。使用 TUIC 或 Hysteria 2 时，代理端口需放行 UDP。

## 管理地址池

| 菜单 | 操作 |
| --- | --- |
| 1 | 新建 IPv6 地址池并生成节点链接 |
| 2 | 用现有地址重新生成节点链接 |
| 3 | 换一批地址并生成新节点链接。新地址检查通过后才更换旧地址 |
| 4 | 查看上次生成的节点链接和单行导入串 |
| 5 | 删除脚本管理的地址并卸载 |

状态目录为 `/var/lib/ipv6-pool/`，地址存于 `ips.list`，含节点凭据的逐条链接存于仅 root 可读写的 `nodes.txt`。单行导入串也包含这些凭据。开机恢复依次适配 systemd、OpenRC 和 `/etc/rc.local`。使用 `rc.local` 的系统需在启动时执行该文件。

需要立即恢复已有地址时，运行 `bash v6.sh --restore`。新池遇到 IPv6 重复地址冲突时会补抽。已发布的地址在冲突排除后会按原地址恢复，已经导入的节点可以继续使用。

洗牌和卸载会核对启动 ID、内核绑定创建时间、原生地址快照和默认路由源地址。来源无法确认的地址会保留，包括旧版已绑定而新版还没有记录归属的地址。升级后可用选项 **2** 更新开机恢复副本，下一次启动由新版重新绑定的地址会自动建立归属记录。

## 验证

在具备 `unshare` 和网络管理权限的 Linux 上，可以在隔离的网络与挂载命名空间运行测试。systemd 和 OpenRC 测试使用模拟的服务管理命令。

```bash
sudo bash tests/lifecycle.sh rc.local
sudo bash tests/lifecycle.sh systemd
sudo bash tests/lifecycle.sh openrc
```
