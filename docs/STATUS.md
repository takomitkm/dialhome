# STATUS — 实测记录（截至 2026-11-11）

这份文件的作用：**区分"证过的"和"没证的"**，避免以后把猜测当结论。

---

## 已实测通过（有证据）

### 1. 反向 SSH 全权限 shell（节点 A，2026-11-11 12:58 上线）
- relay `ss -ltn`：`127.0.0.1:13437` 监听
- relay 日志：`Accepted publickey for user from 10.111.2.33 ... SHA256:ds44VLJS…`（节点 key）
- 从 relay 登入结果：
  ```
  desktop-67s90n6\user
  DESKTOP-67S90N6
  Microsoft Windows [版本 10.0.19042.1288]
  ```
- 节点侧：`19022` 在听（sshd pid 1372）、隧道进程 6356、启动文件夹有
  `sshd-USER.lnk` + `sshtunnel-USER.lnk`
- **同一套流程在本机做过完整预演**（Windows 11 + PS 5.1）：便携 sshd → 隧道 → 从 relay
  `whoami`/`hostname`/`$PSVersionTable` 全通，测完已清理。

### 2. 节点 key 对 relay 零权限（四条负向测试，全过）

| 尝试 | 结果 |
|---|---|
| `ssh <nodekey> 'id; cat /etc/shadow'` | 只回一行 checker JSON，**没执行** |
| `ssh <nodekey> 'GET:win-sshd'`（旧白名单） | 白名单已删除，同样只回 JSON |
| `-L 19998:192.168.1.102:3430`（拿 relay 当跳板） | 连接被拒（`permitopen="127.0.0.1:1"`） |
| `-R 127.0.0.1:13499:...`（占别人的端口） | `remote port forwarding failed`，rc=255，relay 无监听 |
| `-R 127.0.0.1:<自己的端口>:...` | **成功**（对照组，证明只放行自己的端口） |

### 3. magpie 网关（节点 A）
- 找到安装：`C:\Users\USER\AppData\Local\magpie\magpie-windows-amd64.exe`（82.7 MB，0.1.3493），
  但**从未被启动过**（无进程、3425/3430 都关）。
- 用 `serve --web=127.0.0.1:3430` 起（不需要 WebView2）：`3425`/`3430` 都在听，
  `/api/hello` 返回 `{"name":"magpie","version":"0.1.3493"}`。
- 会话回收问题：`Start-Process` 起的会随 ssh 会话死；改用用户级计划任务 `MagpieServe`
  （AtLogOn + RunLevel Limited）后，**新会话里仍在**（pid 10120）。
- 启动项：`MagpieServe`（magpie）、`MagpiePluginAdd`（插件安装用，一次性）。

### 4. WebView2 的真实情况（节点 A）
- 注册表 `HKLM\...\EdgeUpdate\Clients\{F3017226-…}\pv = 122.0.2365.80`
- 但 `C:\Program Files (x86)\Microsoft\EdgeWebView\Application` **不存在**
- ⇒ 安装包"说已装过"是因为**残键**；magpie 的窗口/菜单栏版会因此起不来，
  而 `magpie serve`（只跑网关）不需要它。

---

## 未完成 / 待办

| 项 | 状态 | 下一步 |
|---|---|---|
| **zcode 插件** | `magpie plugin list` = 无；`plugin add` 卡在 `Downloading Bun 1.4.2` | 在快网机器下好 Bun 再塞到 `%LOCALAPPDATA%\magpie`；或用计划任务 + `cmd` 重定向长跑 |
| **zcode 登录** | 需要本人账号 | 节点上 `magpie plugin login zcode`（浏览器授权，无法代做） |
| **节点 A 当前在线** | ❌ 2026-11-12 09:5x 查：relay 无 13437 监听 | 用户级自启只在登录会话活；让那台机器登录（或重启后登录）即自动恢复 |
| **新节点自动登记** | 未做 | 在 relay 上加 `enroll.sh`：任一新机跑同一行 → 现场生成独立 key + 分配独立端口 |
| **WebView2** | 未装 | 要 UI 才需要；一次管理员装 Evergreen Runtime |

---

## 现场取证：一条命令把节点状态送回 relay

当节点"看起来没上线"、而你又能在那台机器上敲命令时，用它（避免来回问）：

```powershell
$r=if(Test-Path 'D:\'){'D:\zc\sshd'}else{"$env:USERPROFILE\sshserver"}
("ROOT=$r`n" + ((Get-ChildItem $r -EA 0 | %{$_.Name+' '+$_.Length}) -join "`n") +
 "`n---tunnel.err---`n" + (Get-Content "$r\tunnel.err" -Tail 15 -EA 0) +
 "`n---sshd.log---`n" + (Get-Content "$r\sshd.log" -Tail 15 -EA 0) +
 "`n---19022---`n" + [bool](Get-NetTCPConnection -State Listen -EA 0 | ?{$_.LocalPort -eq 19022})) |
  Out-String -Width 200 | ssh -p 18322 user@10.101.54.192 "cat > ~/win-diag.txt"
```

之后在 relay 上读 `~/win-diag.txt` 即可。

---

## 本轮用到的机器（可复用的事实）

| 角色 | 事实 |
|---|---|
| relay | Debian 13，`10.101.54.192:18322`（校园）/ `192.168.1.102:22`（家宽），账号 `user`；本机 ssh 别名 `deb-h61`；root 可免密（工作站 key） |
| 节点 A | `DESKTOP-67S90N6`，Windows 10 20H2 家庭中文版，账号 `user`（`C:\Users\USER`），PS 5.1.19041 |
| 工作站 | `S:\apps\llm\agentwork`，PS 5.1 + pwsh 7 |
| relay 上留的可复用工具 | `~/.magpie-connector/`：`OpenSSH-Win64.zip`、`sshserver.ps1`、`nodes/<node>/`（key+payload）、`magpie-tunnel-check.sh`、`verify-tunnel.sh`、`add-win-provider.sh`、`revoke-node.sh`、`magpie-windows-amd64.exe` |