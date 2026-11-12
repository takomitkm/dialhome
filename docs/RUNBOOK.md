# Magpie 反向 SSH 隧道 — GO 执行手册

> ⚠️ **新节点请照 `FAST-PATH.md` 做**（一条命令准备 + 一段粘贴上线，坑都内置修好了）。
> 本文件保留作历史细节与排障参考；§9 记录了 2026-11-11 那次节点的撤销。

目标：让**校园网 Windows**（不装 SSH Server、不开入站端口、**全程不需要管理员/UAC**）把本机
Magpie gateway 通过反向 SSH 隧道暴露到中转机 **102** 的 `127.0.0.1:13425`，使 102 上的 Magpie
能用 `Remote magpie` provider 调用那台 Windows 的 magpie（该机用**它自己的 zcode 登录**）。

---

## 0. 已拍板的两个决定
1. **zcode 来源**：校园 Windows **用自己的 zcode 登录**（不复制校机登录态）。登录命令
   `magpie plugin login zcode`（浏览器 OAuth），装插件 `magpie plugin add @magpie-community/opencode-zcode-auth`。
2. **不要 UAC / 不要管理员**：整条链路只用用户级操作。已实测（我这台机器 **未提权**，Medium 完整性）：
   | 机制 | 结果 |
   |---|---|
   | `Register-ScheduledTask`（`-RunLevel Limited`） | **成功**，principal runLevel=Limited，无 UAC |
   | `HKCU\...\Run` 注册表 | **成功**，无提权 |
   | 用户 Startup 目录 | **成功**，无提权 |
   | `icacls` / `takeown` / `attrib`（对自己的文件） | **成功**，无提权 |
   代码里的自启顺序：计划任务 →(失败)HKCU Run →(失败)Startup 快捷方式，三级都免提权。

---

## 1. 已预先验证过的事实（真机，不是推断）
| # | 事实 | 证据 |
|---|---|---|
| 1 | 受限 key（`restrict,command=checker,port-forwarding,permitlisten="127.0.0.1:13425"`）拒绝 `0.0.0.0` 绑定、越界端口、无 shell | 负向测试全过 |
| 2 | 反向隧道 `127.0.0.1:13425 -> 127.0.0.1:3425` 跑通，102 侧 curl 拿到 magpie hello | 本机假扮 Windows，走校园路径 `10.101.54.192:18322` |
| 3 | 102 运行中的 gateway 在 `provider add` 后**立刻热加载**（3→8 模型，PID 不变，未重启） | live probe，已清理 |
| 4 | 判 remote 只看对端是否 loopback → **Windows 侧不必开 LAN、102 侧 provider key 填任意串即可** | 三条 curl 实测 |
| 5 | 隧道**必须指 gateway 3425，绝不能指 web 3430** | 文档机制 + 实测 |
| 6 | Windows OpenSSH 拒绝权限过宽私钥；沙箱里还会因 `LogonSessionId_*` ACE 被拒 | 真机踩坑，install 已用两遍 `icacls` 修 |
| 7 | 内置 **PowerShell 5.1** 下连接器 selftest **18/18**；install/status/verify(exit 5)/uninstall 全过 | 非提权 shell 实测 |
| 8 | bootstrap（fetch→decode→expand→ensure-magpie→install→status→uninstall）在 5.1 下全流程通过 | 模拟执行，未占生产端口 |

---

## 2. 102 上已预置（GO 时无需再做）
`~/.magpie-connector/`：
- `payload.b64` — Windows 连接器 bundle（含节点私钥、known_hosts），sha256 已校验
- `bootstrap.txt` — 给校园 Windows 粘贴的那段块（21 行）
- `magpie-windows-amd64.exe` — 便携版 magpie 0.1.3493（82.7 MB，免安装），供那台机器按需 `scp` 拉取
- `verify-tunnel.sh` / `add-win-provider.sh` — GO 验收脚本

`~/.local/bin/magpie-tunnel-check` — 强制命令自检器（返回一行 JSON）。
`~/.ssh/authorized_keys` — 两行受限 key：`magpie-tunnel-node-13425`（生产）/ `-13426`（测试）。

> 私钥只允许对 102 的 `127.0.0.1:13425` 反向转发；无 shell/PTY/agent/X11。
> 轮换：重新生成 key → 重写那一行 → 重新打包 payload。

---

## 3. GO 执行（按序，每步先验证再继续）

### 步骤 A — 校园 Windows 上跑 bootstrap（用户操作，PS 5.1 内置）
在已连上的 102 ssh 会话里取块：
```
cat ~/.magpie-connector/bootstrap.txt
```
把 21 行整段复制到**校园 Windows 本地的 PowerShell 5.1** 里运行。块依次做：
1. `ssh ... cat payload.b64` 拉包（会要一次 102 密码）
2. 解码 → 解压到 `%LOCALAPPDATA%\magpie-connector\`
3. `ensure-magpie.ps1`：确认 magpie 在跑（没装就 `scp` 拉 82MB 便携版）、`magpie autostart on`、报告 zcode 登录态
4. `install.ps1`：修私钥 ACL、写 `connector.json`、注册自启（用户级，无 UAC）
5. `Start-Process ... connector.ps1 run`（隐藏）并打印日志尾部

**若 ensure-magpie 报 zcode 未登录**：在该机执行
`& "$env:LOCALAPPDATA\magpie-connector\..\magpie\magpie-windows-amd64.exe" plugin login zcode`
（或它打印的那条命令），用这台机器自己的 zcode 账号登录。这一步不影响隧道建立，只影响模型是否可用。

判定成功：日志 `<root>\logs\connector.log` 出现 `online=true` / `version=...`。

### 步骤 B — 我在 102 确认隧道
```
ssh deb-h61 'bash ~/.magpie-connector/verify-tunnel.sh 13425'
```
必须：`127.0.0.1:13425` 监听；`{"ok":true,...}`；curl 返回 magpie hello；`0.0.0.0/[::]` **不存在**。

### 步骤 C — 102 上加 Remote provider
```
ssh deb-h61 'bash ~/.magpie-connector/add-win-provider.sh'
```
应见 `added Remote magpie (win)` + `N models from 127.0.0.1:13425`，102 gateway 出现 `win/*`。

### 步骤 D — 端到端真请求（省钱：用免费模型）
```
ssh deb-h61 'curl -s -m 60 http://127.0.0.1:3425/v1/chat/completions -H "Content-Type: application/json" \
  -d "{\"model\":\"win/<免费模型>\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"say ok\"}]}"'
```
先 `magpie models | grep '^ *win/'` 看该机实际暴露了哪些（免费/付费）。首验只用定价 0 的模型；
不要用 `magpie provider test`（每个 API 发真实请求花钱）。

---

## 4. 卸载
- Windows：`uninstall.ps1`（默认不删文件）或 `uninstall.ps1 -Purge`（连目录一起删）。
  先删自启（计划任务/HKCU Run/Startup 三处都覆盖）→ `taskkill` 连接器与 ssh 子进程 → 再删文件（含 ACL 解锁重试）。
- 102：`magpie provider rm win`；删 `~/.ssh/authorized_keys` 里 `magpie-tunnel-node-13425` 那行；
  删 `~/.local/bin/magpie-tunnel-check` 与 `~/.magpie-connector/`。

## 5. 日志
- Windows：`%LOCALAPPDATA%\magpie-connector\logs\connector.log`（1MB 轮转，自动脱敏：私钥/lanKey/sk-magpie-*/token 一律打码）
- 状态：`%LOCALAPPDATA%\magpie-connector\state\connector.json`；`connector.ps1 status` 读它

## 6. 已知限制
- 一台 Windows 对应一个 `remotePort`（现 13425）；多节点需新增 key + `permitlisten` + 端口。
- 隧道依赖 102 的 SSH 入站端口；Windows 侧全程无入站、无防火墙改动。
- 认证连续失败会触发 102 限流（`Connection reset`）；重连已按 5→10→20→30→60 退避，勿缩短。
- **尚未在真机验证的两点**（代码已写、留到 GO 验收）：①计划任务在你那台机器上的真实注册
  （本机验证过标准用户可注册，但没在目标机跑）；②长时间断线重连 / magpie 换端口的重建。
- 沙箱里出现过 `secrets\*.pub` 被 `icacls` 清成空 DACL（DSH agent 沙箱副作用，普通用户终端不复现）；
  `uninstall -Purge` 已加 `takeown + icacls /reset + attrib` 兜底。

---

## 7. 装到 D:\zc（已确认的目标布局）

```
D:\zc\magpie-connector\    连接器（connector.ps1 / secrets / logs / state / connector.json）
D:\zc\magpie\              magpie 便携 exe（magpie-windows-autostart 指向这里）
```

在校园 Windows 的 **PS 5.1** 里跑（会要一次 102 密码；约 1 分钟）：

```powershell
ssh -p 18322 user@10.101.54.192 "cat ~/.magpie-connector/migrate-to-D.ps1" | Out-File -FilePath "$env:TEMP\migrate-to-D.ps1" -Encoding ascii
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\migrate-to-D.ps1"
```
脚本做的（全程用户级、无 UAC）：
1. 停掉并注销旧位置（`%LOCALAPPDATA%\magpie-connector`）的连接器与自启；
2. 从 102 重新拉**最新 payload** 解到 `D:\zc\magpie-connector`（顺带修掉旧版 `install.ps1` 的
   计划任务 action 少 `\connector.ps1` 的 bug）；3. 重新 install（改写绝对路径、收紧私钥 ACL、重注册自启）；
4. 从新位置隐藏启动；5. 迁移 magpie 本体到 `D:\zc\magpie`（失败自动回滚旧 exe）；6. 删除旧目录。

可选开关：`-NoMagpie`（不动 magpie 本体）、`-KeepOld`（留旧目录）、`-NoAutostart`、`-NoStart`、`-DryRun`。
跑完在 102 侧复核：

```
bash ~/.magpie-connector/verify-tunnel.sh 13425    # 仍应报 ok:true
```

---

## 8. 免管理员 SSH 通道（102 → 目标 Windows）

目标机跑**用户级 sshd**（不装服务、不碰防火墙、不要管理员），再经现有受限 key 反向转发到 102：

```
目标机 127.0.0.1:22222 (sshd, 公钥认证, 只回环)
   ↑ 反向转发（-R 127.0.0.1:13427:127.0.0.1:22222）
102 127.0.0.1:13427
```

部署（目标机 PS 5.1，两行）：

```powershell
New-Item -ItemType Directory -Force 'D:\zc' | Out-Null; ssh -p 18322 user@10.101.54.192 "cat ~/.magpie-connector/win-sshd.ps1" > 'D:\zc\win-sshd.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\zc\win-sshd.ps1' install
```

- 文件：`D:\zc\sshd\`（host key、`sshd_config`、`authorized_keys`、logs），脚本 `D:\zc\win-sshd.ps1`
- 登录密钥：102 上 `~/.ssh/win-ssh`（私钥从不离开 102）；目标机 `authorized_keys` 里只有它的公钥
- 使用：102 上 `ssh -p 13427 <Windows用户名>@127.0.0.1`；
  笔记本直连 `ssh -o ProxyCommand="ssh -p 18322 user@10.101.54.192 -W 127.0.0.1:13427" -p 13427 <用户名>@127.0.0.1`
- 管理：`win-sshd.ps1 status | uninstall`；日志 `D:\zc\sshd\logs\win-sshd.log`
- 前提：`C:\Windows\System32\OpenSSH\sshd.exe` 存在（Windows 的 OpenSSH Server 组件）。缺了就装该可选功能（一次性管理员），否则此通道不可用。
- 安全边界：sshd 只听 `127.0.0.1:22222`，唯一入口是 102 的回环转发；公钥认证、禁密码、禁 root。

---

## 9. 【已撤销】2026-11-11 校园节点作废

那台校园 Windows 开不了机，整条链路已**永久拆除**（本文档 §1–§8 仅作历史与新节点参考）：

- 102 `~/.ssh/authorized_keys`：删掉 `magpie-tunnel-node-13425` / `-13426` 两行
  （备份 `authorized_keys.bak-revoke-20261111-002950`；剩余 2 条是本来就有的 `takomi@tkmnopc`、`tunnel-rdp-13390`）
- 102 magpie：`provider rm win`，`providers.json` 现为 `[]`，gateway 无 `win/*`
- 删除含私钥/节点专用的文件：`~/.magpie-connector/{payload.b64,bootstrap.txt,migrate-to-D.ps1,win-sshd.ps1}`、`~/.ssh/win-ssh{,.pub}`
- 本机：删除 `magpie-tunnel/secrets/id_ed25519_*`、`payload/secrets/id_ed25519_*`、`payload.zip` 及测试残留目录
- **验证**：用旧 key 连 102 → `Permission denied (publickey,password)`；102 无 `1342x` 监听；本机无相关监听/自启

保留的可复用工具（无密钥）：`~/.magpie-connector/{magpie-tunnel-check.sh,verify-tunnel.sh,add-win-provider.sh,magpie-windows-amd64.exe}`。

### 换新主机时
重新生成**新的** key 对、分配**新的** remotePort，重打 payload；**不要**复用旧 key/旧 payload。
安全模型回顾：所有连接都是「Windows 主动出站 → 102」，笔记本侧不开任何入站；
受限 key 只能做指定回环端口的反向转发，拿不到 102 的 shell。
