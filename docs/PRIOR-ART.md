# PRIOR ART — 有没有人做过类似的东西？

结论先说：**机制本身不新**（反向 SSH + 受限 key 是老手艺），**"一行接入"的 UX** 也不新
（ngrok/cloudflared 的招牌）。但**我们这套约束的组合**在现成项目里没有完整的对应物：

> Windows 节点**零管理员/UAC**（便携 rootless sshd + 启动文件夹自启）+
> relay 侧**不装任何自定义服务**（只有原版 sshd + authorized_keys 选项）+
> 每节点一把**受限 key**（拿不到 relay shell、不能 -L 跳板、只能占自己的回环端口）+
> **一行 enroll**（按主机名发身份）+ 客户端**多锚点自动切换**的拨号器。

## 最接近的现成项目

| 项目 | 与本项目的重合 | 差在哪 |
|---|---|---|
| [bindreams/ssh-tunnel-windows](https://github.com/bindreams/ssh-tunnel-windows) | Windows 上自重启的反向 SSH 隧道（WinSW 服务壳） | **要装服务（管理员）**；不做受限 key 收纳/登记；没有 enroll |
| [bjarneo/stairway](https://github.com/bjarneo/stairway) | 纯 bash 的自托管 ngrok 替代：`init`/`up` 一行、autossh、自动分端口 | 方向相反：是把**笔记本端口暴露到公网**，不是把 NAT 后的机器**收进来管** |
| [rathole](https://github.com/rathole-org/rathole) / [frp](https://github.com/fatedier/frp) | 高性能反向代理，节点主动连服务端 | 要在两端跑**自定义二进制**；隔离靠 token，不是 SSH key 语义；Windows 服务化同样要管理员 |
| [v1k70rk4/RemoteAppClient](https://github.com/v1k70rk4/RemoteAppClient) | 精神上最像：Windows 设备注册（token）、agent 主动出站、经 bastion 反向隧道、受限 `agent` 用户、host key pinning | .NET 10 + SYSTEM 服务 + MariaDB + mTLS 的整套舰队管理系统，重；目标也是 VNC 远控而非通用 shell |
| ngrok / cloudflared / Tailscale / Teleport | "一行接入"或零信任接管的标杆 | 要么第三方 SaaS，要么服务端组件/账号体系全套上 |

## 我们这套的不可替代点

1. **Windows 节点全程零管理员**：rootless sshd（Win32-OpenSSH zip 解压即用）+ 启动文件夹
   快捷方式。上面列的项目要么装服务、要么跑 SYSTEM agent——在"不给管理员"的机器上全部出局。
2. **relay 零新增组件**：不装 frp/rathole/Teleport，原版 sshd 的
   `restrict,command=…,permitlisten,permitopen` 就把每个节点关进自己的回环端口对里
   （拿不到 shell、不能读文件、不能当跳板进 LAN——四条负向测试见 `STATUS.md`）。
3. **一台中转机复用全部节点**：路由器只映射一个端口（relay 的 sshd），新节点只是在 relay
   上多一对回环端口（见 `PORTS.md`）。
4. **客户端拨号器沿用你已有的 school-ssh.bat 形态**：多锚点自动切换 + stdin 管道绕引号地狱
   + rc=255 给出排障清单（`client/dial.py`）。

## 已知同类思路（不重复造，但可借鉴）

- **autossh** 的断线重连语义 → 我们用"5 次内 5→60s，之后每小时一次"的确定性退避替代，
  避免离线期刷请求。
- **WinSW**（服务壳）→ 我们刻意不用：它需要管理员。若某天允许管理员，它是最短路径。
- **Tailscale/Headscale** → 如果有一天可以装内核级组件，它比任何 SSH 方案都省心；
  但在"不给管理员"的前提下进不去。
