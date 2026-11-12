# 新节点上线快路径（FAST PATH）

> 这份是**唯一该照着做的**流程。`RUNBOOK.md` 只作历史记录与细节参考。
> 全流程实测过两轮（打包 → 粘贴 → 上线 → 撤销），两条链路都真跑通过。

---

## 0. 它到底做什么

```
目标 Windows（新机）                        102 中转机
  magpie gateway 127.0.0.1:3425                 magpie gateway 127.0.0.1:3425
        ▲                                              ▲
        │ 本机 TCP                                     │ provider "<node>"
   connector（PowerShell 5.1，常驻）                       │
        │ ssh -N -R 127.0.0.1:<port>:127.0.0.1:3425       │
        └──────────────► 102 sshd ──► 127.0.0.1:<port> ──┘
```

- **方向永远是「Windows 主动连 102」**；笔记本不开任何入站，Windows 不开任何入站。
- 102 上的监听只绑 `127.0.0.1`，公网/局域网都到不了。

---

## 1. 唯一的硬前置条件

**新机要能 `ssh` 连到 102 一次**，用 102 那个 `user` 账号的**密码**或**已授权的 key**。
只此一条。其余全部免管理员、免 UAC、不装服务、不动防火墙。

> 如果连这一步都过不了（密码被拒、也没有 key），先解决 102 登录，别往下走。

---

## 2. 我这边：一条命令把节点准备好

```powershell
cd S:\apps\llm\agentwork\magpie-tunnel\scripts
.\pack-node.ps1 -Node win2 -RemotePort 13435
```

它做的事（全在 102 上以普通用户执行）：生成**无口令** ed25519 密钥（在 102 上生成再取回，
避开 Windows `ssh-keygen` 的空口令坑）→ 打 payload（连接器 bundle + 本节点私钥）→
发布到 `~/.magpie-connector/nodes/<node>/payload.b64` → 幂等写入受限 `authorized_keys` 行
（`restrict,command=<checker> <port>,port-forwarding,permitlisten="127.0.0.1:<port>"`）→
打印**已自检**的粘贴块（无残留占位符 + PS 5.1 解析通过，否则脚本直接报错）。

**端口分配**：`13425`/`13426` 已被历史节点用过并撤销；新节点建议从 **13435** 起，一个节点一个端口。

---

## 3. 新机（Windows，PowerShell 5.1 内置）：敲**一行**

```powershell
ssh -p 18322 user@10.101.54.192 "cat ~/.magpie-connector/nodes/<node>/boot.ps1" > "$env:TEMP\b.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\b.ps1"
```

- `<node>` 换成实际节点名（例如 `win2`）。会**问一次 102 密码**（`user` 账号）。
- `boot.ps1` 是**自包含**的（payload 内嵌），所以不会再问第二次。
- 成功的标志：最后几行出现 `discovered magpie at port 3425 v0.x.x` + **`tunnel online (version=0.x.x)`**。
- 若你的 102 账号不叫 `user` 或端口不是 18322，先告诉我，我改参数再给你一条新的。

<details><summary>备选：不用 boot.ps1 的显式块（脚本也会打印，便于核对）</summary>

```powershell
$H='10.101.54.192'; $P=18322; $U='user'; $RP=<port>; $REL='.magpie-connector/nodes/<node>/payload.b64'
$root="$env:LOCALAPPDATA\magpie-connector"
ssh -p $P ($U+'@'+$H) ("cat ~/$REL") > "$env:TEMP\mn.b64"
$b=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("$env:TEMP\mn.b64")) -replace '[^A-Za-z0-9+/=]',''
[IO.File]::WriteAllBytes("$env:TEMP\mn.zip",[Convert]::FromBase64String($b))
if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
Expand-Archive -Force "$env:TEMP\mn.zip" $root
& "$root\install.ps1" -Root $root -SourceDir $root -SshHost $H -SshPort $P -SshUser $U -IdentityFile "$root\secrets\id_ed25519_<node>_<port>" -KnownHostsFile "$root\secrets\known_hosts" -RemotePort $RP -DefaultPort 3425 -Autostart auto
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $root + '\connector.ps1" run')
Start-Sleep -Seconds 5
Get-Content "$root\logs\connector.log" -Tail 6
```
</details>

```powershell
$H='10.101.54.192'; $P=18322; $U='user'; $RP=13435; $REL='.magpie-connector/nodes/win2/payload.b64'
$root="$env:LOCALAPPDATA\magpie-connector"
$tmp="$env:TEMP\mn.b64"
ssh -p $P ($U+'@'+$H) ("cat ~/$REL") > $tmp
$b=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($tmp)) -replace '[^A-Za-z0-9+/=]',''
[IO.File]::WriteAllBytes("$env:TEMP\mn.zip",[Convert]::FromBase64String($b))
if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
Expand-Archive -Force "$env:TEMP\mn.zip" $root
& "$root\install.ps1" -Root $root -SourceDir $root -SshHost $H -SshPort $P -SshUser $U -IdentityFile "$root\secrets\id_ed25519_win2_13435" -KnownHostsFile "$root\secrets\known_hosts" -RemotePort $RP -DefaultPort 3425 -Autostart auto
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $root + '\connector.ps1" run')
Start-Sleep -Seconds 5
Get-Content "$root\logs\connector.log" -Tail 6
```

成功的标志：最后几行出现 `discovered magpie at port 3425 v0.x.x` + **`tunnel online (version=0.x.x)`**。

---

## 4. 我这边：验隧道、挂 provider

```bash
ssh deb-h61 'bash ~/.magpie-connector/verify-tunnel.sh 13435'
# 期望：127.0.0.1:13435 监听 + {"ok":true,...} + curl 出 magpie hello + 无 0.0.0.0 绑定

ssh deb-h61 'export PATH=$HOME/.local/bin:$PATH
  magpie provider add remote-magpie magpie-102-to-win2 url=http://127.0.0.1:13435 id=win2
  magpie provider refresh win2'
# 期望：✓ added / ✓ N models from 127.0.0.1:13435，且 102 gateway 出现 win2/...
```

**不要用 `magpie provider test`**（每个 API 发一条真实请求，花钱）。`refresh` 只拉列表，免费。

真请求验收（可选，先只挑定价 0 的模型）：
```bash
curl -s -m 60 http://127.0.0.1:3425/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"win2/<免费模型>","max_tokens":8,"messages":[{"role":"user","content":"say ok"}]}'
```

---

## 5. 坑位对照表（全部已内置修复，供排障时对号）

| # | 症状 | 根因 | 现在的做法 |
|---|---|---|---|
| 1 | `Permission denied (publickey,password)` | 私钥被 `-N '""'` 加了字面口令 `""`；或私钥继承 ACL 过宽 | 密钥**在 102 上生成**（无口令）再下发；`install.ps1` 用 `icacls /reset` + `/inheritance:r /grant:r` 两遍收紧 |
| 2 | `Install-... Cannot overwrite the item X with itself` | `-SourceDir == -Root`（payload 直接解到 Root） | install 对同路径复制做跳过（bundle / key / known_hosts 三处） |
| 3 | `Config: INVALID - ssh.port out of range` | PS 5.1 `ConvertFrom-Json` 把整数解析成 `Int64`，校验却写 `-is [int]` | 校验接受 `int`/`long` |
| 4 | 登录后连接器**不启动** | 计划任务 action 写成了**目录**而不是 `...\connector.ps1` | action 指向 `connector.ps1` 全路径 |
| 5 | 任务注册成功但一点就报错 | 同理（#4），启动目录快捷方式也有同样笔误 | 两处都改对 |
| 6 | `sshd` 起不来：`Unsupported option UsePAM` | Windows 版 sshd 不认 `UsePAM` | 配置里去掉 |
| 7 | sshd 有进程但端口不监听 | 只跑了 `run` 没先生成 `sshd_config`（`Ensure-Setup` 只在 install 里调） | `run` 分支先 `Ensure-Setup` |
| 8 | supervisor 反复报 `LiteralPath is null` | 循环里 `Get-NetTCPConnection` 拿不到结果；沙箱/权限差异 | 日志改 `[IO.File]::AppendAllText`，端口探测改 `TcpClient` |
| 9 | 第二个 supervisor 立刻退出 | 命名互斥体同名冲突（上一轮孤儿进程占着） | 清理孤儿 + 互斥体；`status` 能看出 |
| 10 | `Failed to add the host to the list of known hosts` | 收紧 `secrets` 后 `known_hosts` 不可写 | install 末尾单独给 `known_hosts` 授当前用户 F |
| 11 | 脚本取不下来（`ssh user@102` 要密码又被拒） | 目标机没有 102 的可用凭据 | 用连接器 key 的**白名单 GET 模式**（`GET:win-sshd`）或让用户输一次密码；仍不行就先修 102 登录 |
| 12 | 隧道建立失败 `remote port forwarding failed` | 端口不在 `permitlisten` 里，或该端口已被占（上一节点没撤） | `permitlisten` 一节点一端口；上线前 `ss -ltn` 确认空闲 |
| 13 | 隧道通了但 102 拿不到模型 | provider 地址填成 **web 端口 3430** | 隧道**必须指 gateway 3425**；3430 永远不通 |
| 14 | `0.0.0.0:<port>` 被监听（危险） | 客户端写了 `-R 0.0.0.0:...` | `permitlisten` 只放行 `127.0.0.1:<port>`，实测会被拒 |
| 15 | 拿 key 想登 102 的 shell | — | key 带 `restrict` + 强制命令，**拿不到 shell**；实测 `id` 只返回 checker JSON |
| 16 | 机器关机/注销后链路全断 | 连接器与 sshd 守护都是**用户级**，只在登录会话里活着 | 这是设计取舍（不要 UAC）。需要开机即用就得装服务（一次性管理员） |
| 17 | `ssh -N` 后立刻退出 | 忘了 `ExitOnForwardFailure=yes` 之外还缺 `-N` 语义/端口冲突 | 连接器固定用 `-N` + `ExitOnForwardFailure=yes` + `ServerAlive*` |
| 18 | 探针把 PTY 噪声当失败 | `restrict` 会回 `PTY allocation request failed` 到 stderr | 只解析 **stdout 那行 JSON**，stderr 只进日志 |
| 19 | 认证连续失败后被 `Connection reset` | 102 有限流 | 重连按 5→10→20→30→60 退避，不要缩短 |
| 20 | 在测试里把生产端口占了 | 用 `run` 做验证时绑了真实端口 | 测试用**非生产端口**；上线前确认端口空闲 |
| 21 | `running scripts is disabled on this system` | Windows 默认 `ExecutionPolicy=Restricted`：**粘贴进控制台的文本不受限，但任何 `& x.ps1` 调用脚本文件会被拦** | 两条铁律：①永远用 `powershell -NoProfile -ExecutionPolicy Bypass -File x.ps1`（免管理员、进程级）；②**粘贴块里绝不出现 `& "…\x.ps1"`**，要用「启动器」把脚本写进 temp 再由 Bypass 子进程跑 |
| 22 | 打包漏了「保证 magpie 在位」 | `boot.ps1` 只装连接器不查 magpie → 日志 `no Magpie gateway found`，隧道永不建立 | `boot.ps1` / 粘贴块里**先跑 `ensure-magpie.ps1`**（缺 magpie 就 scp 83MB 便携版并启动），再跑 install |
| 23 | `another instance is already running` | 上一次 `run` 的实例还活着，占着 `Local\MagpieTunnelConnector.<port>` | 先按命令行匹配 `connector.ps1 * run` 杀干净，再启动 |

---

## 6. 撤销 / 清理

102 侧（脚本已放在 102 上：`~/.magpie-connector/revoke-node.sh`）：
```bash
ssh deb-h61 'bash ~/.magpie-connector/revoke-node.sh <node> <port>'
# 删掉该节点的 authorized_keys 行（带时间戳备份）+ shred 掉 nodes/<node>/payload.b64
```

Windows 侧：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\magpie-connector\uninstall.ps1" -Purge
```

**撤销后必须确认**：
- `authorized_keys` 里 `magpie-tunnel-node-<port>` 计数为 0
- `ss -ltn | grep <port>` 无监听（若有，说明有孤儿 ssh，杀本机 ssh 子进程后 1–2 秒自动释放）
- 旧 key 实测 `Permission denied`

---

## 7. 安全模型（一句话版）

| 问题 | 答案 |
|---|---|
| 别人能连到我的笔记本吗？ | **不能**。所有连接是 Windows→102，笔记本无入站 |
| 拿到节点私钥能登 102 吗？ | **不能拿到 shell**。`restrict` + 强制命令 + 只允许指定回环端口反向转发 |
| 拿到节点私钥能干什么？ | 最坏只能占住 `<port>` 冒充模型源喂给 102。换机时务必**撤销旧 key** |
| 102 上的 payload 危险吗？ | 含节点私钥。撤销节点时一并 `shred` 删除 |
| 102 上还留了什么 | 无密钥的可复用工具：`magpie-tunnel-check.sh`、`verify-tunnel.sh`、`add-win-provider.sh`、`magpie-windows-amd64.exe` |

---

## 8. 我这边一条命令速查

| 目的 | 命令 |
|---|---|
| 准备新节点 | `.\pack-node.ps1 -Node <n> -RemotePort <p>` |
| 验隧道 | `ssh deb-h61 'bash ~/.magpie-connector/verify-tunnel.sh <p>'` |
| 挂 provider | 见 §4 |
| 撤销节点 | `revoke-node.sh <n> <p>`（102 上）+ 本机 `uninstall.ps1 -Purge` |
| 看连接器状态 | 目标机 `connector.ps1 status`；日志在 `<root>\logs\connector.log` |