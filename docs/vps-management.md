# VPS 管理与用户流量

安装或更新官方正式版（需 root）：

```sh
curl -fsSL https://raw.githubusercontent.com/syncmeta/PendingNet/main/deploy/vps-install.sh -o /tmp/pendingnet-install.sh
sudo bash /tmp/pendingnet-install.sh
```

安装完成直接显示标准节点链接、连接配对链接及管理链接。标准节点链接用于分享连接；管理链接仅授予服务器管理权限。

后续运行 `sudo pendingnet` 打开菜单，或使用命令：

```sh
sudo pendingnet links
sudo pendingnet users list
sudo pendingnet users rename <用户ID> --name "新名称"
sudo pendingnet users revoke <用户ID>
sudo pendingnet traffic
sudo pendingnet service status
sudo pendingnet update
sudo pendingnet engine-lock
```

每个用户拥有独立的 Reality UUID 与 Hysteria2 凭据。撤销同时移除两个协议的连接权限；用户改名保留凭据和累计流量。新版迁移会移除旧的共享代理凭据，需通过更新后的客户端刷新已配对节点，或重新导入该用户的标准节点链接。

流量按用户累计上传与下载，合并两个内核的数据，每 5 秒采样，保存在 `/etc/pendingnet/user-traffic.json`。受控配置更新和服务重启会先采样；进程突然退出时，最后一次采样后的流量可能丢失，累计统计并非计费账单。用户撤销后保留历史累计值。控制面凭据、代理凭据和统计文件均为私有文件，请勿公开。

`pendingnet update` 更新到 PendingNet 正式版及该版本锁定的内核，不在 VPS 上自行追逐上游最新版。`engine-lock` 显示准确目标版本。

客户端管理页的专用导出页面可选 Android / Windows、仅端口 / 系统代理 / TUN、协议、监听端口与局域网访问。端口是本地 HTTP/SOCKS 监听端口；TUN 通过虚拟网卡接管路由。Android 普通应用不能直接修改全局系统代理，通常使用 VPN/TUN。TUN 配置设置 `auto_detect_interface` 避免把出口再次路由回虚拟网卡；这不替代真实手机联网验证。
