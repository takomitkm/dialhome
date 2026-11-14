# REFACTOR_BASELINE — dialhome 旧实现全量审计（Phase 0）

> 分支：`go-refactor` · 基线 commit：`46b3468`（main）· 审计日期：2026-11-14
> 本文档是 Go 重构的事实正本：每一个要保留的行为、每一条安全约束、每一条实测证据。
> 规格正本：用户《dialhome 全面重构执行规格：Go / Cross-platform》（本页不复制其内容，只记录事实）。

---

## 1. 仓库清单（main @ 46b3468，全部为已发布形态）

| 文件 | 角色 | 状态/证据 |
|---|---|---|
| `README.md` | 总览、快速上手、安全模型、存活表 | 含 man 页链接（docs/man-dialhome.md） |
| `client/dial.py` | Controller 拨号器（Python）：MACHINES 注册表、多锚点 failover、`status`/`dial <name>`、stdin 管道跑命令 | 校机 school-guest 经 PC2 revjump；本机 tkinter/127.0.0.1 旁路 |
| `client/onboard.cmd.TEMPLATE` | USB 离线接入（**SSH 版**）：内嵌登记私钥 b64 + 硬件指纹（UUID→MAC→注册表 id 三级回退） | 生成 `Desktop\dialhome-onboard.cmd`（ASCII） |
| `relay/enroll.sh` | 登记核心：名字净化→幂等复用/分配端口对→生成 node key→写受限 AK 行→**发射安装器（stdout）** | `set -eu`；标记 `magpie-node-<name>$`；端口池 13440–13600 |
| `relay/enroll-gate.sh` | SSH 强制命令网关：`enroll <name> [fp] [mode] [mag] [glm] [quiet]` / `get sshserver` / `get openssh`；fp 决定槽位（FP-REUSE/FP-NEW），stdout 只载安装器 | 私钥 `~/.ssh/dialhome_enroll` |
| `relay/make-enroll-key.sh` | 幂等生成登记密钥对 + AK 行 `restrict,command=gate,no-port-forwarding,no-pty`；发射 magic paste（含硬件指纹逻辑） | |
| `relay/bootstrap-server.py` | **开放开户口**（机主拍板无 token）：`/i[?mode=ps|tmp&magpie=1&glm=1&quiet=1]`；URL 即 CLI；错误响应=合法 PowerShell（注释+黄字提示）；每 IP 6 次/分；按来源 IP 分配名字（bootstrap-names.json） | systemd 单元 `dialhome-bootstrap.service`（曾退役后按用户拍板复活为无 token 开放模式） |
| `relay/magpie-tunnel-check.sh` | 节点 key 强制命令：`check <port>` 探活（JSON 一行）+ `GET:win-sshd/GET:migrate` 白名单文件 + `register {json}`（uuid/macs/user，只能写自己记录，flock+machines.json） | 部署于 `~/.local/bin/magpie-tunnel-check`（**authorized_keys 指向这里**，坑 B-新） |
| `relay/reconcile-machines.sh` + `dialhome-reconcile.{service,timer}` | 30 分钟对账：经加密 SSH 进每个在线节点读实时 UUID/MAC，重算 fp 与登记 fp 比对 → MATCH/DRIFT/OFFLINE；**同 UUID 重复槽位自动合并**（保最老，revoke 其余） | machines-report.log |
| `relay/revoke-node.sh` | 撤销：AK 行删除（`magpie-node-<n>$` 与 `magpie-tunnel-node-<port>$` 双标记）+ AK 备份 + 节点目录 shred + machines.json 条目清理 | |
| `relay/stage-relay.sh` / `verify-tunnel.sh` / `add-win-provider.sh` | 固定 OpenSSH zip（sha256 `23f50f34…`）/ 隧道验证 / win 提供商 | |
| `node/sshserver.ps1` | Node 核心（PS 5.1 兼容，PSSA 0/0）：便携 sshd（GitHub→gate 回退，sha 校验）、host key、AK、sshd_config、`-InstallMode ps|tmp`（tmp=只进数据目录+前台隧道+无自启无备份）、D:\ 根三脚本+C: 备份+单启动项+HKCU Run、互斥体守护（退避 5→10→20→40→60，≥5 次→60s，≥10 次→3600s；**开机等待**最多 10 分钟探 relay）、`register` 上报（uuid/macs/user）、`sshd -V` 走 cmd 层合并 stderr | HP66 生产实测（2026-11-13） |
| `node/setup-magpie.ps1` | magpie 侧：-Acquire（exe 经 gate + MagpieServe 计划任务）/ -Plugin（zcode 插件装在分离计划任务，Bun 下载不被 SSH 会话杀死）/ -Login（OAuth 提示）/ -Status | UTF-8 BOM（PSSA 修复） |
| `node/connector.ps1` | 旧方案（保留兼容） | 含脱敏函数与假值自测（历史扫描 4 处命中均为误报） |
| `tools/pack-node.ps1` | 旧工作站打包（被 enroll 取代） | |
| `docs/` | PITFALLS(28 条)/PORTS/STATUS/PRIOR-ART/RUNBOOK/FAST-PATH/man-dialhome/调研 | |
| `.gitignore` | `nodes/ secrets/ *.b64 *.zip *.log *.err .tmp/` | |

## 2. 接入路径（三条，全部实测）

| 路径 | 入口 | 身份载体 | 证据 |
|---|---|---|---|
| HTTP 一行（默认交互式） | `iex((New-Object Net.WebClient).DownloadString('http://10.101.54.192:18443/i[?...]'))` | 无（开放开户，per-IP 名字起步） | HP66 生产接入 2026-11-13 |
| SSH gate | `ssh -i ek user@relay "enroll <name> <fp> <mode> <mag> <glm> <quiet>"` | 登记私钥 | fp-test/fp-test2 全矩阵 |
| USB onboard.cmd | 双击（内嵌登记私钥+指纹） | 登记私钥 | 桌面交付物 |

**URL 即 CLI**：`mode=ps|tmp`、`magpie=1`、`glm=1`（隐含 magpie）、`quiet=1`（无 mode 默认 tmp）；无参=交互式三问答。实测矩阵 5 组全对（参数行 `$UrlMode/$UrlMagpie/$UrlGlm/$SetupSrc` 嵌入正确）。

## 3. 必须保留的行为与实测数字

### 3.1 端口与身份
- 端口池 **13440–13600 = 80 对**（magpie=偶, ssh=奇）；分配扫描 AK permitlisten + `ss -ltn` 监听，双通道成对
- 幂等：同名/同 fp 复用 key+ports（FP-REUSE 实测：`machine-alpha`/`machine-beta` 同 fp → 同 key 同端口）
- 硬件指纹 `fp = SHA256("u|"+UUID 或 "m|"+MACs)[0:16]`（UUID 优先，none/全零→MAC 集合，双缺→HKCU 随机 id）；UUID 来自 `Win32_ComputerSystemProduct`
- register：节点 key 强制命令 `register {"uuid","macs","user"}` → machines.json（**裸名键**，flock）
- 对账：30 分钟 timer，SSH 进节点读实时 UUID/MAC → MATCH/DRIFT/OFFLINE + **同 UUID 自动合并**
- 撤销：AK 行 + 备份 + shred + machines.json 清理（实测全链）

### 3.2 受限 AK 行（逐字模板）
```
restrict,command="<checker> <ssh_port>",port-forwarding,permitlisten="127.0.0.1:<ssh>",permitlisten="127.0.0.1:<magpie>",permitopen="127.0.0.1:1" ssh-ed25519 AAAA... magpie-node-<name>
```
实测负向（此前会话）：无 shell、无文件读、无 -L 进 LAN（permitopen=1 拒）、不能占他端口（permitlisten 精确匹配）、`-R` 必须写 `127.0.0.1:`（坑 B1）。

### 3.3 隧道守护
- 每通道独立 ssh 连接（一条失败不杀另一条）
- 重试梯：5→10→20→40→60s；**≥5 次失败→60s；≥10 次→3600s**；成功清零；`ServerAliveInterval=15 CountMax=3`；`ConnectTimeout=10`；`ExitOnForwardFailure=yes`
- **开机等待**：重启后先探 relay 最多 20×30s（约 10 分钟）再进梯（另一会话增强，已采纳）
- 互斥体 `Local\dialhome-tunnel` 单实例（connect.ps1 竞态实测修复）
- 状态文件 `tunnel-<name>.err`（connected/exited/retry 行）

### 3.4 临时 vs 持久（-InstallMode）
| | ps（持久） | tmp（暂时） |
|---|---|---|
| D:\ 根三脚本 + C:\Users\<u>\dialhome 备份 | ✅ | ❌（一切只进数据目录） |
| 自启动（Startup lnk + HKCU Run，指向 C: 备份） | ✅ | ❌（实测：备份目录/lnk 均不存在） |
| 守护 | 后台（connect.ps1 拉起，单启动项） | **前台**（Ctrl+C/关窗即断） |
| sshd 启动 | connect.ps1 | 直接 Start-Process（端口占用则跳过） |

### 3.5 magpie/zcode
- `--magpie` → `-Acquire`（exe 经 gate 拉取 + `MagpieServe` 用户计划任务，serve 模式免 WebView2）
- `--glm` → `-Acquire -Plugin -Login`（插件装在**分离计划任务**，Bun 下载不被 SSH 会话杀死——实测教训）；隐含 magpie
- setup-magpie.ps1 内嵌进安装器（b64，带 BOM）

### 3.6 无窗口运行（来自 `S:\work\WCIS\wiki\40_工程实践\SOP\校机无UAC远程操作与零窗口SOP.md`，全部 A 级实测）
- **Windows Terminal 是默认终端**：`powershell -WindowStyle Hidden` 对 WT 伪控制台**无效**（窗先建后隐藏）→ 每分钟闪窗事故的根因
- **真无窗两法**：① 计划任务动作套 `wscript.exe` VBS `WshShell.Run(cmd,0,False)`（子进程出生即无窗）；② 脚本内 `Start-Process -WindowStyle Hidden`（STARTF_USESHOWWINDOW+SW_HIDE）
- **WMI `Win32_Process Create` = 常驻可见控制台**（7.5h 实测病灶）
- **ssh 命令树起的东西活不过 ssh 会话**（sshd job object 连坐子孙）；识别特征："0 字节日志+进程仍在列表"或"日志停在 STOP 后"；要活过会话→自名计划任务（`Interactive` principal，免提权实测）
- 观察器必须在用户会话（session 2）跑，`EnumWindows` 只见本 session window station
- 校机链路形态：节点 sshd 127.0.0.1:19022 → `ssh -R 13401` → relay(PC2):18022（tunnel@ 用户）→ Controller ProxyCommand revjump `-W 127.0.0.1:13401`
- 二代隧道脚本模式：退避 20/20/40/80/160/300s、HealthyAfterSec=120 恢复清零、日志 1MB/200 行截断（UTF-16LE BOM）、pidfile 互斥、缺共用库当场 FATAL（防零间隔重拨风暴）
- 部署纪律：`.ps1` 含中文必须 UTF-8 BOM+CRLF；多文件走 scp（`scp x school-guest:D:/path/` 远端带盘符可行）；EncodedCommand 撞 cmd 8191 上限；落盘后双向 sha256

## 4. 安全约束（重构不得弱化）

1. Node 免管理员/UAC；不改防火墙/路由器/系统 SSH
2. 节点 sshd 仅回环、高位端口、仅密钥、仅当前用户
3. 三身份分离：Node Tunnel Key / Controller Management Key / Enrollment Credential（现实现中登记私钥≈enrollment credential；**重构点：node 私钥改为本地生成、只上传公钥**）
4. 受限 AK 行逐字模板 + `permitopen=127.0.0.1:1`
5. Relay 零常驻自定义服务（OpenSSH + forced command + 一次性 CLI）
6. AK 更新：原子写、备份、防并发、保留无关条目
7. Controller 是唯一管理私钥持有者（现实现：relay `~/.ssh/win-ssh` ≈ Controller key，重构后归 Controller 角色）
8. 日志/安装器不泄露密钥；`sk-*`/token 不入仓库（全历史扫描 20 提交零真密钥，4 类误报已核实）

## 5. 已知坑位（PITFALLS.md 28 条的迁移映射，节选关键）

| 坑 | Go 重构对策 |
|---|---|
| B1 `-R 127.0.0.1:` 精确匹配 permitlisten | 端口管理器强约束生成参数；集成测试断言 |
| B6/B7 标记行末匹配 | AK 解析器按完整行解析（新格式），不再裸 grep |
| D8 PS 重定向重编码 | Go 原生文件 I/O 根除 |
| 原生 stderr→NativeCommandError | Go 根除（cmd 层合并已废） |
| job object 连坐 | supervisor 由持久机制（自启/服务）拉起，不经 ssh 树 |
| `New-Item` 拒绝盘符根 | Go 路径库天然无此问题；测试覆盖 |
| Python/APC=936 | Go 根除 |
| 端口释放延迟 | 分配器重试 + 监听探测 |

## 6. 迁移面（`migrate --from-legacy` 必须能读）

| 旧格式 | 位置 | 内容 |
|---|---|---|
| `machines.json` | relay `~/.magpie-connector/` | `{name: {fp, enrolled_at, uuid, macs, user, first_ip, last_seen, reported_at, fp_live, checked_at}}` |
| `bootstrap-names.json` | 同上 | `{ip: name}`（IP 名 → fp 身份桥接） |
| authorized_keys | relay `~/.ssh/` | 受限行（双标记 `magpie-node-<n>$` / `magpie-tunnel-node-<port>$`）+ gate 行 + 注释 |
| 节点数据目录 | node `D:\zc\sshd` 或 `%USERPROFILE%\sshserver` | host key、node_key、sshd_config、AK（102 登录公钥）、known_hosts、tunnel-*.err |
| 自启动 | Startup lnk（`dialhome-connect.lnk` + 旧版两个）+ HKCU Run `dialhome-connect` | 指向 C: 备份 |
| C: 备份 | `%USERPROFILE%\dialhome\` | dialhome-{sshd,tunnel,connect}.ps1 |
| Controller 侧 | `client/dial.py` MACHINES + `~/.ssh/config` 别名（school-guest 等） | 多锚点 |

## 7. 实测环境与既有证据指针

- 本机（Windows 10 20H2，takomi，192.168.1.107）→ relay 直连
- relay 102（Debian 13，user，192.168.1.102 / 10.101.54.192:18322 路由转发；root 免密）
- 校机 HP66（Administrator，2026-11-13 生产接入，D:\ 路径真实验证）+ 校机 Win11-HV1/YiZhidi（WCIS 体系，SOP 正本）
- 生产读数：安装器 ~20KB→42KB（含 setup）；HP66 双通道上线；register 落库；对账 timer active
- 测试残留：全部已撤销/清理（AK 仅 win2 + HP66 + gate 三行）

## 8. Phase 1 输入

- Windows：便携 Win32-OpenSSH 10.0.0.0p2 rootless 已生产验证（HP66）——补自动化脚本与记录
- Linux：102 上做真实的用户态 sshd 实验（高位端口、用户目录 HostKey/AK/log、无 PAM 修改、privsep 目录问题的真实解法）
- macOS：无硬件 → **标记 UNVERIFIED**（规格允许）
