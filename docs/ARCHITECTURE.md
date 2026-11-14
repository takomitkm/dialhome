# ARCHITECTURE — dialhome Go 重构设计（Phase 2 冻结稿 v1）

> 前置阅读：`REFACTOR_BASELINE.md`（旧实现事实）、`SSH_BACKEND_MATRIX.md`（后端选型证据）。
> 本文冻结接口与边界；与规格冲突时以规格为准。

## 1. 角色与进程模型

```
Node（受控机）                Relay（Linux 中继）              Controller（总控）
┌──────────────────┐   出站ssh   ┌────────────────┐    ssh    ┌──────────────┐
│ dialhomed.exe     │──────────→│ 系统OpenSSH sshd │←─────────│ dialhome.exe  │
│  ├ sshd (-D子进程) │  -R 回环  │  authorized_keys │  经回环口 │  controller.* │
│  ├ tunnel ssh ×N  │           │  forced command  │          │  经回环登节点  │
│  └ supervisor     │           └────────────────┘          └──────────────┘
└──────────────────┘
```

- **一个 Go module，一个二进制**：`cmd/dialhome`，子命令区分角色（`node / controller / relay / autostart / service / doctor / migrate`）。
- Windows 发布两型：`dialhome.exe`（console 子系统——Controller 与交互）与 `dialhomed.exe`（`-ldflags -H=windowsgui`——Node 后台/自启入口，无窗口）；同一份代码，构建标签仅切入口与资源。Linux/macOS 单一二进制。
- Relay **不跑常驻 dialhome 进程**：只有 (a) SSH forced-command helper（`dialhome relay-helper` 被 forced command 调起，一次一进程），(b) Controller 经 SSH 调起的一次性 `dialhome relay <sub>` 命令。

## 2. 数据布局（全部用户级，Go path 库生成）

| 角色 | 根路径 | 内容 |
|---|---|---|
| Node Windows | `%LOCALAPPDATA%\dialhome\` | `config.json` `identity.json` `keys/`（tunnel 私钥+host key）`openssh\` `logs\` `state\` |
| Node Linux | `$XDG_DATA_HOME/dialhome`（默认 `~/.local/share/dialhome`） | 同上 |
| Node macOS | `~/Library/Application Support/dialhome` | 同上 |
| Controller | `~/.config/dialhome/`（Win: `%APPDATA%\dialhome\`） | `machines.json`（节点注册表+多锚点）`keys/`（管理私钥）`known_hosts` |
| Relay | `~/.dialhome/` | `registry.json`（节点登记）`credentials.json`（登记凭证）`authorized_keys`（独立文件，被系统 AK include 或由 helper 直接维护系统 AK——见 PROTOCOL §3）`logs/` |

**删除旧实现概念**：D:\ 根脚本、C: 双份备份、PS 生成器、bootstrap-names.json（IP 名）——fp 身份直接来自节点本机生成。

## 3. 包结构（规格 §1.3 落地）

```
cmd/dialhome/main.go        子命令路由
internal/config/            JSON 读写+版本迁移+校验
internal/identity/          三平台硬件指纹（IdentityProvider 接口）
internal/crypto/            ed25519 keygen、AK 行格式化、authorized_keys 解析/原子写
internal/openssh/           发行包获取（版本+sha256 固定）、配置生成、-t 测试、版本读取
internal/process/           子进程生命周期（Windows CREATE_NO_WINDOW/job tree 语义）
internal/supervisor/        每通道独立守护：状态机+重试梯+开机等待+互斥单实例
internal/tunnel/            通道定义（ssh+通用TCP）、参数构造（127.0.0.1 严格）
internal/enrollment/        凭证生成/消费、登记流程编排（节点侧）
internal/relay/             relay 子命令（enroll/list/revoke/reconcile/ports/verify）+ helper
internal/controller/        注册表、多锚点 failover、shell/exec（exec.Command 参数数组）
internal/autostart/         三平台用户级自启动（Windows Startup lnk+HKCU Run 二选一主机制=HKCU Run；
                            Linux systemd --user 单元（无 systemd→XDG autostart）；macOS LaunchAgent）
internal/service/           可选系统服务（Windows SCM / systemd system / LaunchDaemon），独立构建标签
internal/platform/          windows|linux|darwin 平台探测（路径、ACL、进程隐藏）
internal/logging/           slog + 轮转 + 脱敏（密钥/token/私钥体）
```

## 4. 生命周期

### 4.1 Node install（规格 §3.1 十九步的实现映射）
`node install [--mode temporary|persistent] [--relay user@host:port] [--name X] [--credential <file>]`
1-7 平台探测/目录/openssh 获取（`internal/openssh`：固定版本 URL+sha256，HTTP 失败回退 relay `helper get-openssh`）→ 8-9 **本机生成** host key 与 tunnel key（ed25519，0600）→ 10 接收 Controller 管理公钥（凭证内）→ 11-13 配置生成与 `sshd -t` → 14 端口探测 → 15-16 `sshd -D` 子进程启动+回环验证 → 17 隧道 supervisor 启动 → 18 register 上报 → 19 按模式收尾。

### 4.2 Supervisor（规格 §3.4 逐条）
- `--mode temporary`：install 进程**前台**跑 supervisor（信号处理：SIGINT/TERM → 关闭 sshd+全部 ssh 子进程，等待退出，不留孤儿）；Ctrl+C 即全链拆除。
- `--mode persistent`：install 写配置后退出；由 `autostart` 入口在登录时拉起 `dialhomed node run`（后台常驻）；supervisor 管理全部子进程，崩溃自动重启对应子进程；Windows 后台为 windowsgui 型（无窗口，日志进文件）。
- 状态机：`boot-wait`(≤10min 探 relay) → `backoff`(5/10/20/40/60s，≥5 次 60s，≥10 次 3600s，成功清零) → `connected`；keepalive 15s×3；单连接超时 10s；ExitOnForwardFailure 恒开。
- 单实例：配置文件锁（Windows: LockFileEx；Unix: flock）+ pid 记录；第二个 supervisor 检测到锁即退出。

### 4.3 Controller
- `controller list/status`：读注册表 + 经 relay 回环口做 TCP/SSH 探测（复用 forced-command `check`）。
- `controller shell/exec`：`exec.Command("ssh", args...)` **参数数组**（远端命令串只作为 ssh 的最后一个参数，绝不经本地 shell 二次解析）；stdin 脚本沿用旧管线模式；交互模式给 PTY（Windows conpty via ssh.exe 自带）。
- 多锚点：按 `machines.json` anchors 顺序探测（本地回环口 → SSH 健康命令），第一个可用者胜；兼容既有 `~/.ssh/config` 别名（不迁移用户 SSH 配置，只引用）。

### 4.4 Relay helper（forced command）
节点 key 的 `command=` 指向 `dialhome relay-helper --port <p>`，按 `$SSH_ORIGINAL_COMMAND` 分派：
- `check` → JSON 探活（原 checker 语义）
- `register {json}` → 校验调用者身份（由 port 反查 registry）后写入该节点 hardware 记录
- `get-openssh` / `get-config` → 白名单文件下发
helper 单进程短生命周期，flock 保护 registry.json 与 authorized_keys 写入。

## 5. 与旧实现的兼容边界

- 端口池 13440–13600 与 AK 行模板**逐字保留**（见 SECURITY_MODEL §3）
- 旧节点迁移经 `migrate --from-legacy`（读 REFACTOR_BASELINE §6 全部旧格式；保留 host key/node key/端口/AK，不重分配身份）
- 旧 PS/Python 文件在迁移验收（规格 §10 步骤 10）完成前一律不删

## 6. 平台矩阵（声明口径）

| 能力 | Windows | Linux | macOS |
|---|---|---|---|
| Node install/run（temporary） | ✅实测 | ✅实测 | UNVERIFIED |
| Node persistent + autostart | ✅实测（Startup/HKCU） | ✅实测（systemd --user，102 可验） | UNVERIFIED |
| Controller shell/exec | ✅实测 | ✅实测 | UNVERIFIED |
| Relay helper | n/a | ✅实测（Debian 13） | n/a |
| 可选系统服务 | 代码+单测，实机标记 UNVERIFIED* | 同左 | UNVERIFIED |

\* 规格允许代码完成+单元测试，实机验证标注状态；绝不虚报。
