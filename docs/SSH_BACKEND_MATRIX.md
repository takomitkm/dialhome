# SSH_BACKEND_MATRIX — 三平台 SSH 后端可行性实验（Phase 1）

> 分支：`go-refactor` · 结论先行：**三平台均采用原生 OpenSSH（Go 只做部署/编排/守护），
> 不引入嵌入式 Go SSH server。** macOS 本轮无硬件，标记 UNVERIFIED（规格允许，不虚报）。

## 1. Linux（Debian 13，relay 102 实机实测）

| 项 | 读数 |
|---|---|
| 系统 / OpenSSH | Debian 13（trixie）/ **openssh 1:10.0p1-7+deb13u4** |
| 运行身份 | 普通用户 `user`（无 sudo，全程未提权） |
| 部署位置 | 全部在 `~/.dialhome-matrix/`（etc/logs/run/id/known_hosts），系统文件零改动 |
| 配置要点 | `Port 19443`（高位）、`ListenAddress 127.0.0.1`、用户目录 HostKey、`AuthorizedKeysFile` 指向用户目录、`PasswordAuthentication no`、`UsePAM no`、`AllowUsers user`、`Subsystem sftp internal-sftp`、独立 `PidFile` |
| 启动 | `/usr/sbin/sshd -f <user-config> -E <user-log>` → **rc=0 一次成功**（无需 `UsePrivilegeSeparation` 调整；系统级 `/run/sshd` privsep 目录天然存在） |
| 监听 | `ss -ltn`：**仅 127.0.0.1:19443** ✅ |
| exec | `ssh -i id_test user@127.0.0.1 -p 19443 'hostname && whoami'` → `debian-h61` / `user`，rc=0 ✅ |
| PTY | `ssh -tt ... 'echo PTY-$(tty...)'` → **PTY-HAS** ✅ |
| 负向：错 key | `Permission denied (publickey)` ✅ |
| 负向：密码 | 服务器仅提供 publickey → `Permission denied (publickey)`（密码通道不存在）✅ |
| 负向：系统目录 | 未写任何 `/etc`、`/run`（privsep 目录用系统 sshd 已有的 `/run/sshd`）✅ |
| 生命周期 | **daemon 化实例跨 ssh 会话存活**（实测 `ALIVE-ACROSS-SESSION`）；Go supervisor 仍将采用 `sshd -D` 子进程模型以获得崩溃检测与确定的生命周期（两种模式均可用，设计选择见 ARCHITECTURE.md） |

结论：**Linux rootless 用户态 sshd 完全满足规格 §1.2 全部条件**（无 sudo、无装包、无系统用户、不改 /etc/ssh、高位端口、用户目录 HostKey/AK/log、仅回环、shell/PTY/exec/密钥认证全过）。

## 2. Windows（生产证据 + 本机复测）

| 项 | 读数 |
|---|---|
| 发行包 | Win32-OpenSSH `OpenSSH-Win64.zip` 10.0.0.0p2-Preview，5,704,583 B，sha256 `23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5`（固定版本+哈希，不走 latest） |
| 运行身份 | 普通用户（HP66：Administrator 账户、无 UAC 提权动作；本机测试：takomi 非管理员） |
| 部署 | 解压到用户数据目录 `%USERPROFILE%\sshserver\OpenSSH-Win64` / `D:\zc\sshd\OpenSSH-Win64`；GitHub 下载失败时经 enroll gate 回退拉取（同 sha 校验） |
| sshd_config | `ListenAddress 127.0.0.1`、`Port 19022`（高位）、仅 HostKey（用户目录）、`AuthorizedKeysFile` 用户目录、`PasswordAuthentication no`、`AllowUsers <当前用户>`、独立 log/pid |
| 实测 | HP66 生产接入（2026-11-13）：`CONFIG-TEST rc=0`、`BANNER = SSH-2.0-OpenSSH_for_Windows_10.0`、双通道上线、Controller 经 relay 登录成功（`hostname` 返回） |
| PTY / exec / shell | 生产路径持续使用（interactive shell via `-t`、单次命令 via stdin 管道）✅ |
| ACL 坑 | Win32-OpenSSH 对 host key/AK 的 ACL 要求：用户目录+继承收紧即可（icacls /inheritance:r /grant:user:F 已实测）|
| 重构注意 | Go 不再经由 PS 生成配置；`sshd -V` 走 stderr 的观感问题随 Go 根除 |

结论：**Windows rootless 便携 sshd 满足全部条件（生产级证据）**。

## 3. macOS

| 项 | 状态 |
|---|---|
| 硬件 | 无（本工作区无任何 macOS 实机/VM） |
| 判定 | **UNVERIFIED — 不声明支持**。已知事实（B 级，未实测）：macOS 自带 OpenSSH；用户态 LaunchAgent + 用户目录 sshd_config 的路径存在；`/etc/ssh` 系统配置不改。规格 §9.3 允许对无法实测的平台标记未验证 |
| 后续 | 拿到任何 macOS 实机后按 Linux 同款脚本重跑（高位口、用户目录、loopback、PTY、负向四连） |

## 4. 嵌入式 Go SSH server 评估（结论：不采用）

- 原生 OpenSSH 在两个可测平台均**零妥协**满足全部条件 → 触发嵌入式评估的前提不成立
- rospo（golang.org/x/crypto ssh）：可作隧道参考，但其 server 侧的 PTY/Shell/子系统的成熟度与审计面无法与 OpenSSH 等价；Dropbear 用户态 PTY 限制（规格已警示）——均不换
- x/crypto ssh 仍可作为 **Controller 侧编队协议**的候选（若未来不想依赖系统 ssh 客户端），但第一期 Controller 同样用系统 OpenSSH（与 §1.2 一致）

## 5. 对 Phase 2 设计的约束输入

1. Go supervisor 以 `sshd -D` 子进程持有 sshd（崩溃检测、孤儿避免）；Linux 上 daemon 模式亦可存活（实测），但 `-D` 模型生命周期更确定
2. Windows 无窗口：Go 产品二进制分两型——`dialhome.exe`（console，Controller/交互）与 `dialhomed.exe`（`-H windowsgui`，Node 后台/自启入口）；不经过任何 VBS/wscript 包装（SOP 的 wscript 法用于 PS 时代，Go 的 windowsgui 子系统是更干净的原生等价物）
3. ssh 会话连坐清理（job object）→ 一切要活过 ssh 会话的进程由「用户级自启动/计划任务」入口拉起，绝不从 ssh 命令树直接起（SOP 第七节，实测）
4. 登录后网络未就绪 → 开机等待循环（最多 ~10 分钟探测 relay）保留进 Go supervisor
5. Linux privsep 目录 `/run/sshd`：系统装过 sshd 的机器天然存在；**全新无 sshd 的 Linux** 需要验证（未测场景，记录为 Phase 5 待办：`sshd -d` 用户态在无 `/run/sshd` 时的真实行为，必要时文档要求一次性 `install -d /run/sshd` 或评估 `-o` 规避——以实测为准，不猜测）
