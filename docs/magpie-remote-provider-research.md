# magpie Remote provider 调研：让 102 的 magpie 把「另一台电脑的 magpie」当 provider

> 调研时间：2026-11-10 13:41–13:50（Asia/Taipei）
> 对象：102（Debian 13，magpie **0.1.3206**，gateway `:3425` / web `:3430`）+ 一台 Windows magpie
> 依据：官方文档 `https://usemagpie.ai/docs/remote`、`/docs/integrate` 全文；上游 `docs/reference.md`（main）；两个版本的 `--help` / `presets` 实测；102 上的一次性沙箱彩排
> 脱敏：所有 `sk-*` / `lanKey` 一律 `[REDACTED]`
> **纪律声明**：本次没有修改 102 的 `~/.config/magpie/*`、没有重启 102 的 magpie、没有向 102 的真实实例添加 provider。彩排用的是 `HOME=/tmp/mp-sandbox/home XDG_CONFIG_HOME=/tmp/mp-sandbox/xdg` 的一次性实例，**已删除**（见 §7.F）。

---

## 0. 一页结论表

| # | 问题 | 结论 | 证据 |
|---|---|---|---|
| 1 | UI 里那一项叫什么 | **Providers → ＋ Add provider → 最后一个分组 `Another computer's magpie`（另一台电脑的 magpie）→ 项名 `Remote magpie`**。预设 id = **`remote-magpie`** | 102 上 `magpie presets` 输出尾部：`another computer's magpie` / `Remote magpie   remote-magpie   magpie provider add remote-magpie <key>` |
| 2 | 要填什么字段 | 只有两个：**地址**（Address）+ **网关密钥**（Gateway key）。CLI 另有 `id=`（命名前缀）。**key 不能留空**（位置参数必填） | docs/remote §2；reference.md L522–527 |
| 3 | 填 `http://127.0.0.1:13425` 会被接受吗 | **会**。magpie 对 provider 地址**没有 loopback 拒绝**；裸 `127.0.0.1:13425` 也行（自动补 `http://`），带 `/v1` 也行，magpie 会自己派生各 API 路径 | **实测**（沙箱彩排，见 §3）：对 `127.0.0.1:13403` 执行 `provider add remote-magpie …` → `✓ added Remote magpie (probe)` / `✓ 4 models from 127.0.0.1:13403` |
| 4 | 落盘到哪个文件 | **`~/.config/magpie/providers.json`**（顶层是 `{"providers":[…]}` 对象，不是裸数组）。102 上 `XDG_CONFIG_HOME` **未设**，所以就是 `~/.config/magpie/providers.json`。文件**在第一次添加非插件 provider 时才被创建** —— 这就是 102 现在没有它的原因 | §3 实测 + §7.D；102 `ls` 无 `providers.json`，但有 `plugin-providers.json`（ZCode 是 **plugin provider**，走另一条存储） |
| 5 | 远端要不要 key / 要不要在 Windows 开 lan | **都不需要**。隧道把请求送到 Windows 的 `127.0.0.1:3425`，magpie 判定 **peer 是 loopback → 永远放行**（`Loopback remains permissive: any token works, including a stale or disabled gateway key`）。因此 **Windows 侧 lan 开或关都行、不必建 gateway key**；102 侧那个 key 字段**填任意字符串都能通** | 文档 reference.md L852–860 原文；**实测**：`curl -s http://127.0.0.1:13403/v1/models` 无 auth → `http_code=200`；带随便的 `Bearer magpie-probe` → 200；带伪造 `sk-magpie-key-bogus…` → **仍然 200** |
| 6 | 隧道该指向远端哪个端口 | **3425（gateway 端口）**。**绝对不能指 3430（页面端口）**：页面端口上的 gateway 路由「永远按别的机器处理」，`ssh -R` 又不带转发头，于是 magpie 认不出它、**永远不把它当本机 agent 应答** | reference.md L2413–2420 原文：「A forward to that port that adds no forwarding header (frp's `tcp`, `ssh -R`, socat …) reaches it from loopback, so magpie can't tell it from an agent on this computer **and never answers it as one**」 |
| 7 | CLI 能代替 UI 吗 | **能，而且更精确**。没有 `magpie remote` / `magpie lan` 子命令（0.1.3206 与 0.1.3493 都没有），但有 `magpie provider add remote-magpie …` 这条完整路径，预设名两版**都存在** | 两侧 `presets` 实测；`magpie --help` 无 remote/lan 子命令 |
| 8 | 加成功后模型怎么命名 | `<你给的 id>/<远端 provider>/<model>`，例如 `win/zcode/GLM-5.3-Flash`、`win/zen-free-all/mimo-v2.6-flash-free`。**双前缀**，第一个是你命名空间 | 沙箱实测：`probe/auto/mimo-v2.6-flash-free`、`probe/zcode/GLM-5.3-Flash` … |
| 9 | 验证「经 provider 拿到远端模型列表」用什么 | **`magpie provider refresh <id>`**（免费，只拉列表，输出会逐条列模型）或 `magpie models`。**不要用 `magpie provider test <id>`** 做首验——它按文档会「每个 API 发一个极小真实请求」，是花钱的 | reference.md L348–351 原文 |
| 10 | 验收该 curl 哪个端口 | **gateway `127.0.0.1:3425`**，不是 web `3430`。3425 从 loopback 不需要 key；3430 的 `/api/*` 是**页面自己的命名空间**，要页面登录 cookie | reference.md L2420–2430；实测 102 `3425/v1/models` 无 auth → 200 |

### ⚠️ 对任务前提的一处实测修正

任务描述说「gateway 通过反向 SSH 隧道出现在 102 的 `127.0.0.1:13425`」。**实测 13425 当前没有任何监听**（`ss -ltn | grep 13425` → `NO LISTENER on 13425`）。

102 现在**已经有一条可用链路**，但端口不是 13425：

```
$ ss -ltnp | grep -E ':(3425|3430|13403|13401)'
LISTEN 0 128  0.0.0.0:13403  users:(("ssh",pid=2765486,fd=5))
LISTEN 0 128  127.0.0.1:13401 + [::1]:13401        # root sshd，反向隧道入口
LISTEN 0 4096  *:3430        users:(("magpie",pid=2754638,fd=5))
LISTEN 0 4096  *:3425        users:(("magpie",pid=2754638,fd=10))

$ ps -eo pid,user,args | grep '[s]sh '
ssh -N -L 0.0.0.0:13402:127.0.0.1:3430 -L 0.0.0.0:13403:127.0.0.1:3425 \
    -p 13401 -i ~/.ssh/shell_key_xj … YiZhidi@127.0.0.1
```

即：102 上有个常驻 `ssh -L`，经 `13401` 这个反向隧道入口，把**远端那台机器的** `3425`（gateway）和 `3430`（web）映射到 102 的 **`13403` / `13402`**（注意监听在 `0.0.0.0`，LAN 可见）。

```
$ curl -s http://127.0.0.1:13403/api/hello
{"name":"magpie","version":"0.1.3462"}
$ curl -s http://127.0.0.1:13403/v1/models   # 4 个模型
auto/mimo-v2.6-flash-free        zen-free-all   0 / 0
zcode/GLM-5.3-Flash              zcode          计费
zen-free-all/mimo-v2.6-flash-free       zen-free-all   0 / 0
zen-free-alt/deepseek-v4.1-flash-free   zen-free-all   0 / 0
```

**所以：** provider 地址到底写 `13403` 还是 `13425`，取决于你要接的是「现在这条 13403 链路」还是「按 `magpie-tunnel/node102/` 那套脚本新起的 per-node 反向隧道（`permitlisten="127.0.0.1:13425"`，loopback-only）」。**地址格式与全部语义两者完全相同**，下面的步骤把 `<PORT>` 当变量即可。本文的实测证据用的是已在线的 `13403`。

---

## 1. UI 路径与字段（102 的 web，`http://127.0.0.1:3430`）

依据 docs/remote §2 原文：

> **The app:** on the Providers tab press ＋ Add provider, pick **Remote magpie** under **Another computer's magpie** (the last heading), then give its **address and the key**.

对应到 102（0.1.3206，UI 语言 `lang: "system"`）：

1. 浏览器开 `http://127.0.0.1:3430`。
2. 左侧 **Providers** 页 → 右上 **＋ Add provider**。
3. 弹层里**滚到最后一个分组**，分组标题是 **`Another computer's magpie`**（中文界面下为「另一台电脑的 magpie」）。注意前面还有一个分组叫 `On this machine`（本机），**别选错**。
4. 分组里选 **`Remote magpie`** 这一项。
5. 填两个字段：
   - **Address**：`http://127.0.0.1:13425`（或 `127.0.0.1:13425`；带 `/v1` 也接受）
   - **Key**：远端 gateway key。**在 loopback 隧道拓扑下随便填一个 8+ 字符的字符串即可**（§4 有原理与实测）。要"正规"就从 Windows 那边 `magpie gateway-key add "magpie102"` 拷一个 `sk-magpie-key-…` 过来，二者都通。
   - 若 UI 提供了名称/ID 字段，填一个能认出的短 id（如 `school`、`win`）——它决定模型前缀。

**101/102 侧注意**：`presets` 输出把这两行放在最末、独立分组下，正是 Add 弹层最后一个 heading 的数据来源，所以 102 的 UI **一定**有这个入口（不是版本缺功能）。

---

## 2. CLI 能代替 UI

**能。** 两侧 `--help` 里都**没有** `magpie remote` / `magpie lan` 子命令（`magpie settings` 才是 lan 开关的正规 CLI），但 `provider add` 支持完整预设：

```
# 102（0.1.3206）与 Windows（0.1.3493）都实测存在：
$ magpie presets | grep -iE 'remote|another'
  another computer's magpie
  Remote magpie                 remote-magpie   magpie provider add remote-magpie <key>
```

版本差异（实测）：

| | 102 Linux | 本机 Windows |
|---|---|---|
| 版本 | `magpie 0.1.3206` | `magpie 0.1.3493` |
| `remote-magpie` 预设 | 有 | 有（**且已 `✓ added`**，见 §3） |
| `provider add` 语法 | 同 | 同 |
| 注意 | 命令行会先打一行 `plugin: host starts with no proxy NODE_EXTRA_CA_CERTS=…`（无害） | — |

**已存在的生产先例**：本机 Windows 的 `providers.json` 里**已经有一个 remote-magpie provider**，名字 `school`，指向 `http://192.168.1.102:13403/v1`。这证明该功能在两版上都是日常可用状态，不是试验特性。

---

## 3. 落盘位置与 schema（实测）

### 3.1 加到哪儿

`~/.config/magpie/providers.json`（`$XDG_CONFIG_HOME` 存在时是 `$XDG_CONFIG_HOME/magpie/providers.json`）。docs/reference.md L3984 原文：

> - `providers.json` — your providers, keys included (0600); `pluginLeft` in it keeps a removed plugin's model picks until it is added again

102 实测环境：`XDG_CONFIG_HOME=[<unset>]`，`HOME=/home/user` → **`/home/user/.config/magpie/providers.json`**。

### 3.2 为什么 102 现在没有 `providers.json`

102 的 `~/.config/magpie/` 里有 `affinity.json`、`caller-keys.json`、`plugin-providers.json`、`plugin-auth.json` …，**唯独没有 `providers.json`**。原因（有旁证）：102 唯一的模型来源 `ZCode` 是 **plugin provider**，它的注册信息在 `plugin-providers.json`，登录态在 `plugin-auth.json`，**不进 `providers.json`**。

```
$ magpie providers          # 102 真实实例
  ZCode  zcode  api.z.ai  ● signed in as …  3 of 3 models · fetched 58m ago

$ curl -s http://127.0.0.1:3425/v1/models | jq '.data|length'
3                                     # 只有 zcode/GLM-5.3-Flash, -5.2, -5-Turbo
```

→ **第一个非插件 provider（就是你要加的 remote magpie）会创建这个文件。** 换句话说：**加之前 102 上没有 `providers.json` 是正常的**，不是装坏了。

### 3.3 加成功前后的差异（脱敏，来自沙箱实跑）

**加之前**：`/tmp/mp-sandbox/xdg/magpie/` 下只有 `caller-keys.json.lock`、`plugins.yml(.lock)`、`stash.json` —— **无 `providers.json`**。

**加之后**（`magpie provider add remote-magpie dummy-not-a-real-key url=http://127.0.0.1:13403 id=probe`）：

```
✓ added Remote magpie (probe)
✓ 4 models from 127.0.0.1:13403
  4 models in the catalog · magpie models

$ cat $XDG_CONFIG_HOME/magpie/providers.json          # key 已脱敏
{
  "providers": [
    {
      "id": "probe",
      "name": "Remote magpie",
      "icon": "magpie",
      "preset": "remote-magpie",
      "key": "[REDACTED]",
      "chat":      "http://127.0.0.1:13403/v1",
      "responses": "http://127.0.0.1:13403/v1",
      "anthropic": "http://127.0.0.1:13403",
      "decide":    "http://127.0.0.1:13403/v1"
    }
  ]
}
```

要点：

- 顶层是 **`{"providers":[…]}`**（对象），不是数组。
- 你只给一个 `url=`，magpie 自动派生 4 个端点：`chat` / `responses` / `decide` 加 `/v1`，`anthropic` **不加**。
- **刚 add 完 `providers.json` 里没有 `models` 字段**（模型列表是运行时抓的；`provider refresh` 之后也没有写回）。所以别指望从 `providers.json` 核对模型数 —— 用 `magpie provider refresh` / `magpie models` 核对。
- 对照本机 Windows 里那个已存在的 `school`（字段更多，因为做过可见性挑选）：

```json
{ "id":"school", "name":"Remote magpie", "icon":"magpie", "preset":"remote-magpie",
  "key":"sk-magp[REDACTED]",
  "chat":"http://192.168.1.102:13403/v1", "responses":"http://192.168.1.102:13403/v1",
  "anthropic":"http://192.168.1.102:13403", "decide":"http://192.168.1.102:13403/v1",
  "models":["zen-free-all/mimo-v2.6-flash-free","zen-free-all/deepseek-v4.1-flash-free"],
  "pickedFrom":[…], "delisted":[…] }
```

---

## 4. 鉴权语义（本题最容易搞反的地方）

### 4.1 官方原文（reference.md L852–860）

> While LAN sharing is enabled, or `MAGPIE_ADDR` puts the gateway on the network …, **remote requests require an enabled gateway key** sent as Bearer, `x-api-key`, `x-goog-api-key` or `?key=`; one without gets 401. **A request is remote when its peer isn't loopback**, which includes Docker's port publishing … and a WSL distro under NAT. **Loopback remains permissive: any token works, including a stale or disabled gateway key.** Only a valid, enabled key is attributed to its named identity. **Neither shared nor on the network, a remote request is refused (403).**

对应中文要点：

1. **「remote」的唯一判据是 peer 地址是不是 loopback**，不是"从哪台机器来"。
2. peer 是 loopback → **任何 token 都放行**（包括过期/被禁用的 key），**没有 key 也放行**。
3. peer 不是 loopback（LAN、Docker 桥、WSL NAT）→ **必须**有效 gateway key；没共享则直接 403。

### 4.2 套到本场景

```
102 的 magpie ──▶ 127.0.0.1:13425  (102 自己 loopback)
                  │ ssh -R 隧道（bare TCP，不加转发头）
                  ▼
               Windows 127.0.0.1:3425  ← Windows 看到的 peer 就是 127.0.0.1
```

→ Windows 侧看到 peer = `127.0.0.1` → **permissive 分支**。

**结论：**

| Windows 侧设置 | 要不要 | 说明 |
|---|---|---|
| Settings → Network and sharing → **Share on local network（lan）** | **不需要开** | 开或关都能被 loopback 访问。开着的唯一副作用是 LAN 上别人也能连、从而需要 key——与隧道无关 |
| Gateway → **Gateway keys** | **不需要** | loopback 不校验 key |
| 102 侧 provider 的 `key` 字段 | **必填，但填任意字符串即可** | CLI 位置参数必填；沙箱里用 `dummy-not-a-real-key` 直接通 |

**实测证据**（102 → `127.0.0.1:13403`，同一拓扑、同一语义）：

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:13403/v1/models
200                                        # 完全不带 Authorization
$ curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer magpie-probe'      http://127.0.0.1:13403/v1/models
200                                        # 任意 caller key
$ curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer sk-magpie-key-bogus0000000000' http://127.0.0.1:13403/v1/models
200                                        # 伪造的 gateway key 也 200 —— loopback permissive
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:13403/v1/magpie/limit
200
```

三条都 200，与上面第 2 条原文完全吻合。**如果哪天这三条变成 401**，说明隧道不再以 loopback 身份落地（例如改成了从 LAN 地址进），那时才需要 key。

### 4.3 两个必须避开的坑

1. **隧道不要指向 3430（页面端口）**。reference.md L2413–2420：
   > A forward to that port that adds no forwarding header (frp's `tcp`, `ssh -R`, socat …) reaches it from loopback, so magpie can't tell it from an agent on this computer **and never answers it as one**.
   页面端口上的 gateway 路由是「一律按另一台机器处理」的，而 `ssh -R` 不添加任何转发头 → 它既不被当本机、又拿不到 shared 身份 → **永远不通**。
2. **102 自己的 `lan:true` + `lanKey` 与本题无关**。那是「别人连 102」的入站策略；现在讨论的是「102 出去连别人」。

---

## 5. 102 上添加 remote provider 的精确步骤

> 前置：隧道已在 102 上就绪。先按 §6.1 验收隧道，再执行下面的步骤。

### 5.1 UI 版（推荐给你本人操作）

1. 确认隧道：`ssh deb-h61 'curl -s http://127.0.0.1:<PORT>/api/hello'` → `{"name":"magpie","version":"…"}`。
2. 打开 `http://127.0.0.1:3430` → **Providers** → **＋ Add provider**。
3. 滚到最后一个分组 **`Another computer's magpie`** → 点 **`Remote magpie`**。
4. **Address** 填 `http://127.0.0.1:<PORT>`（`<PORT>` = 13403 或 13425）。
5. **Key** 填任意 8+ 字符（如 `magpie-102-to-win`）；若想规范，用远端 `magpie gateway-key add "magpie102"` 生成一个真 key 也行（loopback 下不校验）。
6. 名称/ID 填 `win`（或 `school`）。保存。
7. 预期立刻出现一行 `✓ N models`，Providers 列表出现 `Remote magpie  win  127.0.0.1:<PORT>  ● …  N of N models`。
8. 顺手把刷新改成更短的：`magpie provider refresh-every win 10m`（默认就是 10m，Remote magpie 专用默认值）。

### 5.2 CLI 版（等价，可脚本化）

```bash
ssh deb-h61 '
  export PATH=$HOME/.local/bin:$PATH
  # ① 加（id 决定模型前缀；key 随便填，见 §4.2）
  magpie provider add remote-magpie magpie-102-to-win url=http://127.0.0.1:13425 id=win
  # ② 列表确认
  magpie providers
  # ③ 重抓远端模型列表（免费）
  magpie provider refresh win
  # ④ 看模型（应该出现 win/... 前缀）
  magpie models | grep -E "^\s+win/"
'
```

预期输出形状：

```
✓ added Remote magpie (win)
✓ N models from 127.0.0.1:13425
  N models in the catalog · magpie models
  Remote magpie  win  127.0.0.1:13425  ● magp…-win  N of N models · fetched just now
✓ N models from 127.0.0.1:13425
  Remote magpie  win
  chat       http://127.0.0.1:13425/v1
  responses  http://127.0.0.1:13425/v1
  anthropic  http://127.0.0.1:13425
  key        magp…-win
  refresh    every 10m  the gateway fetches its list by itself
  models     N exposed of N from 127.0.0.1:13425 · fetched just now
             win/zcode/GLM-5.3-Flash  GLM-5.3-Flash · ZCode
             …
```

撤销：`magpie provider rm win`。改地址：UI 里编辑；TUI 里 `w`。

---

## 6. E2E 验收命令清单（可直接复制）

`<PORT>` = 隧道端口（当前实测可用 `13403`；计划中的 per-node 隧道为 `13425`）。`<ID>` = 你给的 provider id（下文用 `win`）。

### 6.1 隧道通（第 0 层）

```bash
# a) 102 上确有 loopback 监听（计划端口 13425，应该是 loopback-only）
ssh deb-h61 'ss -ltn | grep -E ":<PORT>$"'
#   预期: LISTEN 0 128 127.0.0.1:<PORT> 0.0.0.0:*

# b) 用团队已有的 checker（它同时校验「loopback 绑定」+「确实是 magpie」）
ssh deb-h61 '/home/user/.local/bin/magpie-tunnel-check <PORT>'
#   预期: {"ok":true,"listen":"127.0.0.1:<PORT>","magpie":true,"version":"0.1.3xxx"}
#   失败形状: {"ok":false,"reason":"no-listener"|"wrong-bind"|"not-magpie", …}

# c) 裸 curl
ssh deb-h61 'curl -s -m 5 http://127.0.0.1:<PORT>/api/hello'
#   预期: {"name":"magpie","version":"0.1.3493"}   ← 远端 Windows 自己的版本
```

### 6.2 远端模型列表（第 1 层，免费）

```bash
ssh deb-h61 'curl -s -m 8 -o /dev/null -w "http_code=%{http_code} size=%{size_download}\n" http://127.0.0.1:<PORT>/v1/models'
#   预期: http_code=200 size=数千字节
#   若 http_code=401 → 隧道落地点不再是 loopback（见 §4.3）

ssh deb-h61 'curl -s -m 8 http://127.0.0.1:<PORT>/v1/models | python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d[\"data\"]),[m[\"id\"] for m in d[\"data\"]][:6])"'
#   预期: 4 ['auto/mimo-v2.6-flash-free','zcode/GLM-5.3-Flash', …]
```

### 6.3 经 provider 拿到远端模型列表（第 2 层，**验收核心**，免费）

```bash
ssh deb-h61 'export PATH=$HOME/.local/bin:$PATH; magpie provider refresh win' | tail -20
#   预期: ✓ N models from 127.0.0.1:<PORT>  + 逐条列出 win/<provider>/<model>

ssh deb-h61 'export PATH=$HOME/.local/bin:$PATH; magpie models | grep -E "^\s+win/"'
#   预期: win/zcode/GLM-5.3-Flash  GLM-5.3-Flash · ZCode  low/high/max
#         win/zen-free-all/mimo-v2.6-flash-free  …
```

### 6.4 102 自己的 gateway 里已上架（第 3 层，免费）

```bash
ssh deb-h61 'curl -s -m 8 http://127.0.0.1:3425/v1/models | python3 -c "import json,sys;d=json.load(sys.stdin);ids=[m[\"id\"] for m in d[\"data\"]];print(len(ids));print([i for i in ids if i.startswith(\"win/\")])"'
#   预期: 总数从 3 → 3+N；列表含 win/... 的 id
```

> ⚠️ 这里有个**待实测**点：102 的 gateway 是否立即感知 `providers.json` 变更。若不立即生效，重启 102 的 magpie（或 `magpie sync`）后再看（见 §8）。

### 6.5 真实请求（第 4 层，**只给命令，本次未执行**）

选**远端定价为 0** 的免费模型，成本为 0：

```bash
ssh deb-h61 'curl -s -m 60 http://127.0.0.1:3425/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"win/zen-free-all/mimo-v2.6-flash-free\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"say ok\"}]}"'
#   预期: {"id":"chatcmpl-…","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"ok"}}], "usage":{…}}
```

- 免费候选（实测 pricing prompt/completion 均为 `0`）：`zen-free-all/mimo-v2.6-flash-free`、`auto/mimo-v2.6-flash-free`、`zen-free-all/deepseek-v4.1-flash-free`。
- **不要**在首验用 `zcode/GLM-5.3-Flash`（实测 `prompt=0.00000011952 / completion=0.00000041831`，是计费的），也别用 `magpie provider test win`（文档：每 API 发一个极小真实请求）。
- 若只想确认链路通又完全不想发模型请求，停在 6.4 就够了 —— 6.3/6.4 已经证明「102 通过 provider 拿到了远端模型」。

### 6.6 一句话总验收

```bash
ssh deb-h61 '/home/user/.local/bin/magpie-tunnel-check <PORT> && \
  export PATH=$HOME/.local/bin:$PATH && magpie provider refresh win >/dev/null && \
  magpie models | grep -qE "^\s+win/" && echo "E2E OK: 102 通过 remote provider 看到远端模型"'
```

---

## 7. 不确定 / 待实测（这些是推断，不是结论）

1. **`13425` 隧道本身不存在**（已实测无监听）。整个 §6 的前提是它先被建起来。当前唯一在线的等价端点是 `13403`（→ 远端 magpie **0.1.3462**，4 个模型），它不是 loopback-only（绑 `0.0.0.0`）。**建议先用 `13403` 把 provider 打通验证功能，再切到 `13425`** —— 两者语义相同，切过去只需改地址。
2. **运行中的 102 gateway 是否立即 reload `providers.json`** —— 未验证（不允许真加 provider）。如果不生效，回退办法是重启 102 的 magpie，或 `magpie sync`。`provider refresh` 会主动重抓，可能已足够。
3. **`key` 字段填任意字符串的长期风险** —— 今天通，是因为对端 loopback permissive。若**将来**把隧道改成从 LAN 地址进，同一个 provider 会突然 401，届时必须换成真 gateway key 并在 Windows 开共享。建议现在就用真 key，成本为零、免掉这个坑。
4. **UI 文案在各语言下的确切措辞** —— 英文文档确认是 `Remote magpie` / `Another computer's magpie`；102 `lang: "system"`，中文界面下中文名我没有截图验证（presets 的 CLI 输出是英文）。**报 UI 路径时按英文找不会错**。
5. **`magpie provider test <id>` 的确切成本** —— 文档写"one tiny request per API"；未实测，因此验收清单里回避它，改用 `provider refresh`。
6. **0.1.3206（102）与 0.1.3493/0.1.3462（Windows）的远端协议差异** —— 文档提到「A remote magpie 10m unless set」和「an older remote without decision-model discovery still serves its existing APIs」。本场景远端版本**更高**，所以 102 侧不会缺能力；反过来（102 当被共享端、更老）才需要担心。
7. **为什么 102 没有 `providers.json`** —— §3.2 的解释（plugin provider 不入 `providers.json`）是基于「102 只有 ZCode 且 ZCode 在 plugin-providers.json」的**推断 + 强旁证**，没有读 102 二进制源码逐行确认。
8. **多节点端口分配** —— `magpie-tunnel/node102/stage-102.sh` 支持「每个节点一份 .pub + .port」，13425 是其中之一的约定值；具体哪台机器用哪个端口由 lead 决定，本文不假设。

---

## 附：本次用到的证据命令（可复跑，均只读）

```bash
# 102：magpie 版本与预设
ssh deb-h61 'export PATH=$HOME/.local/bin:$PATH; magpie --version; magpie presets | tail -5'
# 102：现有 provider 与 gateway 基线
ssh deb-h61 'export PATH=$HOME/.local/bin:$PATH; magpie providers; curl -s http://127.0.0.1:3425/v1/models | head -c 200'
# 102：配置目录
ssh deb-h61 'ls -la ~/.config/magpie/; echo $XDG_CONFIG_HOME'
# 102：拓扑
ssh deb-h61 'ss -ltnp | grep -E ":(3425|3430|134[0-9][0-9])"; ps -eo pid,user,args | grep "[s]sh "'
# 102：隧道端点鉴权语义（三条都应 200）
ssh deb-h61 'for k in "" "magpie-probe" "sk-magpie-key-bogus0000000000"; do
  curl -s -o /dev/null -w "$k -> %{http_code}\n" -H "Authorization: Bearer $k" http://127.0.0.1:13403/v1/models; done'
# 本地 Windows：版本 / provider 落盘
'C:\Users\Public\app\鹊\magpie-windows-amd64.exe' --version
# 本地 Windows：providers.json 里的 remote-magpie 条目
pwsh -File S:\apps\llm\agentwork\.tmp\mp-providers-dump.ps1
```

附带的脚本（工作区 `.tmp/`，只读）：
- `.tmp/mp-probe-102.sh`、`.tmp/mp-probe-13403.sh`、`.tmp/mp-acceptance-probe.sh` —— 102 上跑的探针
- `.tmp/mp-providers-dump.ps1` —— 脱敏 dump `providers.json` 里的 remote 条目
- `.tmp/mp-sandbox-rehearsal.sh` —— **一次性沙箱彩排**（独立 `HOME`/`XDG_CONFIG_HOME` + `MAGPIE_ADDR=127.0.0.1:13429`，不碰真实实例，跑完自删 `/tmp/mp-sandbox`）
