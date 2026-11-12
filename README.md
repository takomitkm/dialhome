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

## 快速上手（两个动作）

### 1) relay 侧：把介质与授权准备好（在工作站上跑）

```powershell
# 需要：工作站能 ssh 到 relay（本项目里是 deb-h61）
pwsh -File tools\pack-node.ps1 -Node win2 -RemotePort 13435
```

它会在 relay 上：生成**无口令** ed25519（在 Linux 生成，避开 Windows 的引号坑）→ 把
`OpenSSH-Win64.zip`、节点 key、`node/sshserver.ps1` 放到 `~/.magpie-connector/` →
幂等写入受限 `authorized_keys`（`restrict` + 强制命令 + `permitlisten` + `permitopen`）→
打印一段**自检过**的粘贴命令。

### 2) Windows 节点：两行

```powershell
ssh -p 18322 user@10.101.54.192 "cat ~/.magpie-connector/sshserver.ps1" > "$env:TEMP\ss.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\ss.ps1"
```

它会（**用户级、零 UAC**）：
1. 下 `OpenSSH-Win64.zip`（校验 sha256；下不动就从 relay `scp` 过来）→ 解到 `D:\zc\sshd\OpenSSH-Win64`
2. 生成 host key、写 `sshd_config`：只听 `127.0.0.1:19022`、仅公钥、`AllowUsers` 只放当前账号
3. `authorized_keys` 只放 **relay 的登录公钥**（全权限 shell，无命令限制）
4. 起 sshd，并起**第二条独立连接** `-R 127.0.0.1:13437:127.0.0.1:19022`
5. 在 `启动` 文件夹建两个快捷方式 → 登录即自启
6. 断网重试：5 次内 5→60s，之后**每小时一次、永久**

### 3) 验证（在 relay 上）

```bash
ss -ltn | grep ':13437 '
ssh -p 13437 <你的Windows账号>@127.0.0.1 'hostname && whoami'
```

relay 侧 `~/.ssh/config` 建议加个别名：

```
Host winbox
  HostName 127.0.0.1
  Port 13437
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
  FAST-PATH.md              早期版快路径（历史，README 取代它）
  RUNBOOK.md                第一轮 GO 手册 + 上游取舍（历史）
  docs/
    PITFALLS.md             ★ 25+ 条症状→根因→修法，动手前先读
    STATUS.md               实测记录：证过什么、还没做什么
    magpie-remote-provider-research.md   magpie remote provider 机制调研
  relay/                    relay（Linux）侧脚本
    stage-relay.sh          一次性布置介质/授权
    magpie-tunnel-check.sh  强制命令自检器（stdout 一行 JSON）
    verify-tunnel.sh        隧道验收（监听/探针/穿隧道 curl）
    add-win-provider.sh     在 relay 的 magpie 上挂 remote provider
    provider-probe.sh       provider 侧探针
    revoke-node.sh          撤销一个节点（key 行 + payload）
  node/                     Windows 侧脚本
    sshserver.ps1           ★ 便携 sshd + 反向隧道 + 自启（本项目主角）
    connector.ps1           magpie 网关隧道的连接器（可选）
    TunnelManager.ps1 / MagpieDiscovery.ps1   连接器模块
    install.ps1 / uninstall.ps1 / ensure-magpie.ps1 / migrate-to-D.ps1
    connector.config.template.json
  tools/
    pack-node.ps1           在工作站上一键布置新节点
```

**不放进仓库**（`.gitignore` 已挡）：`nodes/`（含私钥）、`secrets/`、`*.b64`、`*.zip`、日志。

---

## 排障入口

1. 先看 `docs/PITFALLS.md`——症状对号入座，20 秒能定位大半。
2. relay 上看 `ss -ltn | grep '<端口>'`：没监听 = 节点侧没起来（不是 relay 的问题）。
3. 节点侧看 `D:\zc\sshd\sshd.log` 与 `D:\zc\sshd\tunnel.err`。
4. 还不行就用 `docs/STATUS.md` 里的"现场打包"手法：一条命令把节点状态送回 relay。