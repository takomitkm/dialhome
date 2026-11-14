# DIALHOME(1) -- one-line onboarding for Windows nodes

## NAME

**dialhome onboard** -- enroll a Windows machine to the relay and bring up its
reverse channels, from a single PowerShell line.

## SYNOPSIS

```powershell
iex((New-Object Net.WebClient).DownloadString('http://10.101.54.192:18443/i[?mode=ps|tmp][&magpie=1][&glm=1][&quiet=1]'))
```

The **URL query is the CLI**: every flag below maps 1:1 onto a query parameter.
`iex` cannot pass arguments to a downloaded script, so the relay folds the
flags into the generated installer instead.

## PARAMETERS

| URL 参数 | 等价 CLI 写法 | 作用 |
|---|---|---|
| *(无参数)* | *(默认)* | **交互式**：在目标机上依次询问下面三项 |
| `mode=ps` | `--ps` | 持久连接：开机自启（Startup + HKCU Run）、`D:\` 三脚本 + `C:\Users\<用户>\dialhome` 备份、互斥体守护 |
| `mode=tmp` | `--tmp` | 暂时连接：一切只进数据目录（`D:\zc\sshd` 或 `%USERPROFILE%\sshserver`），**无自启、无备份、无 D:\ 根脚本**；隧道前台运行，Ctrl+C / 关窗即断 |
| `magpie=1` | `--magpie` | 安装 magpie 网关（portable exe + `MagpieServe` 用户计划任务，serve 模式免 WebView2） |
| `glm=1` | `--glm` | 安装 zcode/GLM 插件并给出 OAuth 登录提示；**隐含 `magpie=1`** |
| `quiet=1` | `-q` / `--quiet` | 无交互：全部问答跳过；**单独 `-q` 未给 `mode` 时默认 `tmp`**（最小副作用） |

## DESCRIPTION

无参数（交互式）时目标机上会依次问：

```
连接类型: 持久(开机自启+多地备份)[P] / 暂时(只拉回环,断了就断)[t] [P]
安装 magpie 网关? [y/N]
安装 zcode/GLM 插件(会一并安装 magpie)? [y/N]
```

任何一项在 URL 里已显式给出的，对应问题不再询问；`quiet=1` 时全部跳过。

两种模式的共同部分：rootless sshd（仅 127.0.0.1、仅密钥）、每节点独立 key +
独立回环端口对（relay 上 13440–13600 池）、双通道守护（ssh / magpie 各一条
ssh 连接，失败 5→10→20→40→60 秒退避，第 5 次失败起每 60 秒、第 10 次起每小时）、
硬件指纹登记（UUID/MAC 经 register 上报，30 分钟对账器比对并自动合并重复槽位）。

差异：

| | `mode=ps`（持久） | `mode=tmp`（暂时） |
|---|---|---|
| D:\ 根目录三脚本 | ✅ | ❌ |
| C:\Users\<用户>\dialhome 备份 | ✅ | ❌ |
| 开机自启（Startup + HKCU Run） | ✅ | ❌ |
| 守护进程 | 隐藏后台（开机自动拉起） | **前台**（可见日志；Ctrl+C / 关窗即断） |
| 适合 | 常驻校园机 | 借用一下的机器、演示、临时排查 |

## EXAMPLES

```powershell
# 1. 交互式（什么都不带，跟着问答回车即可）
iex((New-Object Net.WebClient).DownloadString('http://10.101.54.192:18443/i'))

# 2. 暂时连接，最小 footprint（quiet 默认 tmp）
iex((New-Object Net.WebClient).DownloadString('http://10.101.54.192:18443/i?quiet=1'))

# 3. 持久连接 + magpie 网关，无交互
iex((New-Object Net.WebClient).DownloadString('http://10.101.54.192:18443/i?mode=ps&magpie=1&quiet=1'))

# 4. 持久 + magpie + zcode/GLM 插件（装完给 OAuth 登录提示）
iex((New-Object Net.WebClient).DownloadString('http://10.101.54.192:18443/i?mode=ps&magpie=1&glm=1&quiet=1'))
```

## RECONNECT / STATUS / REMOVE

```powershell
# 持久机器：双击 D:\dialhome-connect.ps1（或开机自动）；同目录三脚本均有 C: 备份
# 暂时机器：进程死即断；重跑同一行即可再连
# 查看某台：ssh deb-h61 'cat ~/.magpie-connector/machines.json'
# 撤销某台：ssh deb-h61 'bash ~/.magpie-connector/revoke-node.sh <名字>'
# 对账报告：ssh deb-h61 'tail ~/.magpie-connector/machines-report.log'
```

## FILES

| 路径 | 归属 |
|---|---|
| `D:\dialhome-{sshd,tunnel,connect}.ps1` | 持久机器的主脚本（D: 不存在则回退数据目录） |
| `C:\Users\<用户>\dialhome\` | 同名备份；开机自启指向这里（D: 被拔也能自启） |
| `D:\zc\sshd\` 或 `%USERPROFILE%\sshserver\` | 数据目录（host key、node_key、隧道日志） |
| relay `~/.magpie-connector/{machines.json,bootstrap.log,machines-report.log}` | 登记、审计、对账 |

## SECURITY

无 token 开户口（机主拍板）：全校可登记；闸门 = 每 IP 每分钟 6 次 + 端口池
80 对天然上限 + 节点 key 无权（仅自身回环端口、无 shell、无 -L）+ 全量日志。
登记私钥 / 节点私钥永不出 relay；Desktop 的 onboard.cmd / magic.ps1 是仅有的
两份线下钥匙。目标机脚本全部 PS 5.1 兼容（学校机器无 pwsh 依赖），经
PSScriptAnalyzer（0 error / 0 warning）与 Parser 校验后发布。

## SEE ALSO

README.md（总览）、docs/PORTS.md（端口与安全模型）、docs/PITFALLS.md（28 条坑）、
`client/onboard.cmd`（USB 离线版，走 SSH 不依赖 18443）。
