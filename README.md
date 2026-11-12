# magpie-tunnel

把一台**没有公网 IP、不能开入站端口、不给管理员权限**的 Windows 机器，
变成可以从指定的 Linux 中转机（下文称 *relay*，本项目的实例是 102）远程使用的节点：

- **反向 SSH 全权限 shell**：relay 上 `ssh -p 13437 <user>@127.0.0.1` 直接进 Windows（装载便携 sshd）
- **magpie 网关隧道**：Windows 上的 magpie gateway（`127.0.0.1:3425`）被映射到 relay 的回环端口，
  relay 上的 magpie 用一个 `remote magpie` provider 就能用这台机器的模型

全程 **Windows 主动出站**；Windows 和笔记本都不开任何入站端口，不需要管理员、不需要 UAC、
不改防火墙、不装 Windows 服务。

> 这套是 2026-11 在真实机器上跑通并复盘过的。踩过的坑全部记录在
> [`docs/PITFALLS.md`](docs/PITFALLS.md)——**动手前先读那个表**，能省掉一整晚。

---

## 拓扑

```
        Windows 节点（无公网 IP）                      relay（102, Linux）
  ┌────────────────────────────────┐         ┌──────────────────────────────┐
  │ portable sshd (rootless)       │         │                              │
  │   127.0.0.1:19022              │◄────────┤ 127.0.0.1:13437  (accept)    │
  │                                │  -R     │                              │
  │ magpie gateway                 │         │ 127.0.0.1:13435  (provider)  │
  │   127.0.0.1:3425               │◄────────┤                              │
  │                                │  -R     │ magpie gateway 127.0.0.1:3425│
  │ ssh.exe  ── 出站 ──────────────┼────────►│ sshd 10.101.54.192:18322     │
  └────────────────────────────────┘         └──────────────────────────────┘
                                                          ▲
                                                          │ ssh deb-h61
                                                    你的工作站
```

两条通道**互相独立**（各自一条 ssh 连接）：

| 通道 | 节点侧 | relay 侧落地 | 用途 |
|---|---|---|---|
| SSH 通道 | `-R 127.0.0.1:13437:127.0.0.1:19022` | `127.0.0.1:13437` | 从 relay 登进 Windows，全权限 |
| magpie 通道 | `-R 127.0.0.1:13435:127.0.0.1:3425` | `127.0.0.1:13435` | relay 上的 magpie 用这台的模型 |

端口**一个节点一份**（见下表），不要复用：reuse 会导致 relay 上 `known_hosts`
主机密钥冲突（`REMOTE HOST IDENTIFICATION HAS CHANGED`）。

| 端口 | 归属 |
|---|---|
| 13435 | magpie 通道（节点 A） |
| 13437 | SSH 通道（节点 A） |
| 13425 / 13426 / 13427 / 13499 | 历史测试，已废弃/已撤销 |
| 13440+ | 新节点按需分配，一个节点一组（magpie, ssh）= (13440,13441) … |

---

## 快速上手

### 0) relay 侧一次性布置（在工作站上跑，只做一次）

```bash
ssh deb-h61 'bash -s' < relay/stage-relay.sh
# 把 OpenSSH-Win64.zip（校验 sha256）与便携 magpie 放到 ~/.magpie-connector/，
# 并列出还缺哪些文件（sshserver.ps1 / enroll.sh / setup-magpie.ps1 从本仓库复制过去）
```

relay 上需要的文件（一次拷过去，之后不用管）：

```bash
scp relay/* node/sshserver.ps1 node/setup-magpie.ps1 deb-h61:.magpie-connector/
```

### 1) 任何一台新机：**同一行**（不需要改任何参数）

```powershell
ssh -p 18322 user@10.101.54.192 "bash ~/.magpie-connector/enroll.sh $env:COMPUTERNAME" > "$env:TEMP\enroll.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\enroll.ps1"
```

- 会问**一次** 102 密码（取 installer 用）
- relay 侧 `enroll.sh` 按 `COMPUTERNAME` 给这台机器**现场生成独立 key**、**分配独立的一对回环端口**，
  写一条受限 `authorized_keys`，然后把这台的安装器（含它的 key）打到 stdout
- 安装器再调 `node/sshserver.ps1`：便携 sshd + 两条独立反向通道 + 登录自启
- **幂等**：同一台机器再跑一次，复用原来的 key 和端口，不会越建越多

### 2) magpie 侧（可选，但要"用这台机器的模型"就必须做）

```powershell
ssh -p 18322 user@10.101.54.192 "cat ~/.magpie-connector/setup-magpie.ps1" > "$env:TEMP\sm.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\sm.ps1"
```

它做三件事：找到（或从 relay 拉）magpie → 用**用户级计划任务**把 gateway 常驻在
`serve` 模式（**不需要 WebView2**）→ 把 zcode 插件装进**独立计划任务**里跑
（`plugin add` 第一步要下 Bun，放会话里会被会话回收打断）。

登录那一步只能你本人做（浏览器 OAuth）：节点上
`"<magpie exe>" plugin login zcode`；或者按 `docs/PORTS.md` 把 relay 的 magpie web
用 `ssh -L 3430:127.0.0.1:3430 deb-h61` 映射到本机再操作。

### 3) 验证（在 relay 上）

```bash
ss -ltn | grep ':13437 '                       # 有监听 = 节点上线了
ssh -p 13437 <你的Windows账号>@127.0.0.1 'hostname && whoami'
curl -s 127.0.0.1:13435/api/hello              # magpie 通道（端口见节点自己的分配）
```

relay 侧 `~/.ssh/config` 建议加个别名（端口换成 `enroll.sh` 分给这台机器的 ssh 端口）：

```
Host winbox
  HostName 127.0.0.1
  Port <ssh 端口>
  User <你的Windows账号>
  IdentityFile ~/.ssh/win-ssh
  StrictHostKeyChecking accept-new
```

---

## 安全模型（这是本项目的核心约束）

| 问题 | 答案 |
|---|---|
| 别人能从外网连到 Windows 吗？ | **不能**。Windows 只做**出站**；sshd 只绑 `127.0.0.1` |
| 节点 key 能在 relay 上做什么？ | **只有一件事**：在自己那一个回环端口上做反向转发 |
| 能拿节点 key 登 relay 的 shell 吗？ | **不能**（`restrict` + 强制命令，sshd 只回一行 JSON） |
| 能读 relay 上的文件吗？ | **不能**（强制命令里没有读文件分支） |
| 能把 relay 当跳板进 LAN 吗？ | **不能**（`permitopen="127.0.0.1:1"`，实测连接被拒） |
| 能占别的节点的端口吗？ | **不能**（`permitlisten` 精确到自己的端口） |
| 能越权提管理员吗？ | **不能**（整套是用户级；管理员操作需要你本人 UAC） |

四条负向测试都做过，结果见 [`docs/STATUS.md`](docs/STATUS.md)。

反向的信任是另一把 key：`relay:~/.ssh/win-ssh`（私钥只在 relay）→ 节点 `authorized_keys`。
它给的是**那个 Windows 账号的完整 shell**，所以：**别把 `win-ssh` 复制到别处**。

---

## 已知限制（别当成 bug）

- **用户级 = 只在登录会话里活着。** 节点重启后没人登录，链路不会自己起来；
  注销也会断。要做到"开机即用、无需登录"必须装服务或 `AtStartup` 计划任务 → **需要一次管理员**。
  （上游项目对此的取舍见 `docs/RUNBOOK.md`。）
- **断网后最长间隔 1 小时。** 这是刻意的：避免离线时刷日志/刷请求。
- 节点换了 Windows 账号 → `AllowUsers` 不匹配，登不进去，需要改 `sshd_config` 重起 sshd。

---

## 仓库结构

```
magpie-tunnel/
  README.md                 ← 你在这里
  docs/
    PITFALLS.md             ★ 25+ 条症状→根因→修法，动手前先读
    PORTS.md                ★ 端口模型：为什么以后不用再动路由器
    STATUS.md               实测记录：证过什么、还没做什么（含现场取证一行命令）
    FAST-PATH.md            早期版快路径（历史，README 取代它）
    RUNBOOK.md              第一轮 GO 手册 + 上游取舍（历史）
    magpie-remote-provider-research.md   magpie remote provider 机制调研
  relay/                    relay（Linux）侧脚本
    enroll.sh               ★ 任一新机的"同一行"：现场发身份（独立 key + 独立端口）
    stage-relay.sh          一次性布置介质（OpenSSH zip / 便携 magpie）
    magpie-tunnel-check.sh  强制命令自检器（stdout 一行 JSON）
    verify-tunnel.sh        隧道验收（监听/探针/穿隧道 curl）
    add-win-provider.sh     在 relay 的 magpie 上挂 remote provider
    provider-probe.sh       provider 侧探针
    revoke-node.sh          撤销一个节点（key 行 + key 文件 shred）
  node/                     Windows 侧脚本
    sshserver.ps1           ★ 便携 sshd + 两条独立反向通道 + 自启
    setup-magpie.ps1        ★ magpie 固定流程（serve 常驻 + zcode 插件 detached 安装）
    connector.ps1           magpie 网关隧道的连接器（可选，另一条路）
    TunnelManager.ps1 / MagpieDiscovery.ps1   连接器模块
    install.ps1 / uninstall.ps1 / ensure-magpie.ps1 / migrate-to-D.ps1
    connector.config.template.json
  tools/
    pack-node.ps1           工作站侧旧流程（预生成 key+payload；enroll.sh 更省事，保留兼容）
```

**不放进仓库**（`.gitignore` 已挡）：`nodes/`（含私钥）、`secrets/`、`*.b64`、`*.zip`、日志。

---

## 排障入口

1. 先看 `docs/PITFALLS.md`——症状对号入座，20 秒能定位大半。
2. relay 上看 `ss -ltn | grep '<端口>'`：没监听 = 节点侧没起来（不是 relay 的问题）。
3. 节点侧看 `D:\zc\sshd\sshd.log` 与 `D:\zc\sshd\tunnel.err`。
4. 还不行就用 `docs/STATUS.md` 里的"现场打包"手法：一条命令把节点状态送回 relay。