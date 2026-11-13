# dialhome

把**没有公网 IP、不能开入站端口、不给管理员**的机器（Windows 为主）"拨回家"：
机器主动出站连到一台中转机（*relay*），你在中转机上回拨进去。

隧道里跑什么**不再限于 magpie**——它只是一条 TCP 通道，可以承载：

- **交互 shell**（本项目的主用途：便携 rootless sshd）
- **任意 TCP 服务**：RDP、magpie/LLM 网关、web 页面、数据库……
- **一次性的命令管道**（客户端 `dial.py` 的 stdin 技巧）

约束同样不限于某台机器：**零管理员、零 UAC、不装服务、不改防火墙**，
relay 侧**不装任何自定义组件**（原版 sshd + `authorized_keys` 选项就够）。

> 客户端形态照搬你桌面的 `school-ssh.bat`：多锚点自动切换、stdin 管道绕引号、
> 失败给排障清单 —— 通用化后是 [`client/dial.py`](client/dial.py)。
>
> 动手前先读 [`docs/PITFALLS.md`](docs/PITFALLS.md)（28 条症状→根因→修法）；
> "有没有人做过类似的"见 [`docs/PRIOR-ART.md`](docs/PRIOR-ART.md)。

---

## 拓扑（一台 relay，N 台机器）

```
   节点（NAT 后的 Windows）                 relay（102，Linux）              你的工作站
 ┌───────────────────────────┐      ┌────────────────────────────┐
 │ rootless sshd  :19022     │◄─────┤ 127.0.0.1:<ssh端口>         │── ssh ──► 你
 │ magpie/RDP/…   :本地服务   │◄─────┤ 127.0.0.1:<服务端口>        │
 │                           │  -R  │                            │
 │ ssh.exe ── 出站 ──────────┼─────►│ sshd :18322（唯一对外端口）  │
 └───────────────────────────┘      └────────────────────────────┘
```

- 路由器**永远只映射一个端口**（relay 的 sshd）；新机器只是在 relay 上多一对回环端口，
  外部扫描不到任何节点 → 见 [`docs/PORTS.md`](docs/PORTS.md)。
- 每台机器一把**受限 key**：拿不到 relay 的 shell、不能读文件、不能 `-L` 当跳板、
  只能占自己那一对回环端口（四条负向测试见 [`docs/STATUS.md`](docs/STATUS.md)）。
- 反向的信任是另一把 key（`relay:~/.ssh/win-ssh`，私钥只在 relay）→ 节点拿到的是
  **它自己账号的完整 shell**。

---

## 快速上手

### 0) relay 一次性布置（工作站上跑，只做一次）

```bash
scp relay/* node/sshserver.ps1 node/setup-magpie.ps1 deb-h61:.magpie-connector/
ssh deb-h61 'bash -s' < relay/stage-relay.sh   # 校验并放置 OpenSSH zip / 便携 magpie
```

### 1) 任何一台新机：**同一行**（按 COMPUTERNAME 自动区分）

```powershell
`powershell
USB 里的 `client/onboard.cmd`（SSH 版，内嵌登记私钥，双击即装）。
没有公网开户口：接入只走 18322，硬件指纹决定槽位。

需要先把路由器的 18443 映射到 relay（一次性，见 PORTS.md）。token 就是能力：一轮接入完就换。
不想用公开口的话，用 USB 上的 client/onboard.cmd 或 Desktop\dialhome-magic.ps1（走 SSH 通道，不经过 18443）。
```

问一次 102 密码 → relay 现场发身份（独立 key + 独立回环端口对，幂等复用）→
节点装好便携 sshd + 两条独立反向通道（SSH 通道 + 一条自定义服务通道）+ 登录自启。

### 2) 想在这台机器上跑 magpie/LLM 网关（可选载荷）

```powershell
ssh -p 18322 user@10.101.54.192 "cat ~/.magpie-connector/setup-magpie.ps1" > "$env:TEMP\sm.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\sm.ps1"
```

serve 模式常驻（不需要 WebView2）；zcode 插件在独立计划任务里装
（`plugin add` 要下 Bun，放会话里会被会话回收打断——这条坑已写进 PITFALLS F2）。

### 3) 从你的工作站拨进去：`client/dial.py`

```powershell
python client\dial.py            # 菜单：选机器 → 开 shell
python client\dial.py status     # 所有机器、所有锚点的存活表
python client\dial.py school "git status"   # 一次性命令（stdin 管道，免引号地狱）
```

机器表在 `dial.py` 顶部的 `MACHINES` 里：每台机器一组 **anchors**（`~/.ssh/config`
里的别名，按顺序自动切换），以及那台机器的 shell 类型。

### 4) relay 上验证

```bash
ss -ltn | grep 1343            # 谁上线了，一目了然
ssh -p <该节点的ssh端口> <账号>@127.0.0.1 'hostname'
```

---

## 安全模型

| 问题 | 答案 |
|---|---|
| 外网能扫到节点吗？ | **不能**。节点只出站；它的 sshd 只绑 `127.0.0.1` |
| 节点 key 能在 relay 上干什么？ | **只一件事**：反代自己那一对回环端口 |
| 能登 relay / 读文件 / 跳进 LAN 吗？ | **都不能**（`restrict` + 强制命令 + `permitopen="127.0.0.1:1"`，实测） |
| 能占别的节点的端口吗？ | **不能**（`permitlisten` 精确匹配） |
| 信任的反向是谁？ | relay 的 `win-ssh` 私钥 → 节点自己账号的完整 shell；**别复制它** |

已知取舍：**用户级 = 只在登录会话里活**。重启后没人登录就不会自动起来
（要"开机即用"必须一次管理员装服务）；断网后按 5→60s、随后**每小时**重试，永久。

---

## 仓库结构

```
dialhome/
  README.md            ← 这里
  client/
    dial.py            ★ 工作站拨号器（多锚点切换 / status / 一次性命令）
  relay/               relay（Linux）侧
    enroll.sh          ★ 任一新机"同一行"：发身份（独立 key + 端口对，幂等）
    stage-relay.sh     一次性介质布置（OpenSSH zip / 便携 magpie）
    magpie-tunnel-check.sh / verify-tunnel.sh / add-win-provider.sh / revoke-node.sh
  node/                Windows 侧
    sshserver.ps1      ★ rootless sshd + 每通道独立守护 + 自启（可传参）
    setup-magpie.ps1   magpie 固定流程（可选载荷）
    connector.ps1 等   magpie 网关隧道的连接器（早期方案，保留）
  tools/pack-node.ps1  工作站侧旧流程（enroll.sh 更省事）
  docs/
    PITFALLS.md  ★      PORTS.md  ★      STATUS.md
    PRIOR-ART.md        RUNBOOK.md（历史）   FAST-PATH.md（历史）
    magpie-remote-provider-research.md
```

**不进仓库**（`.gitignore` 已挡）：`nodes/`（含私钥）、`secrets/`、`*.b64`、`*.zip`、日志。

---

## 当前哪台活着（2026-11-13 17:51 实测）

| 机器 | 锚点 | 状态 |
|---|---|---|
| 校机 Win11-HV1（`school-guest`，老隧道体系） | 笔记本 `127.0.0.1:13401` **听**；经 relay `127.0.0.1:13401` banner=`SSH-2.0-OpenSSH_for_Windows_10` | **活** |
| 节点 win2（DESKTOP-67S90N6，本项目 enroll） | relay `13435`/`13437` **监听消失** | **掉线**（机器没登录/关了；它登录即自动回来） |
| relay 上 `0.0.0.0:13402/13403` | 102 上**别人的** `ssh` 进程（pid 3938136），绑全网卡 | ⚠️ 不归本项目，建议改绑回环 |