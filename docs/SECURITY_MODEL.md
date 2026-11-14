# SECURITY_MODEL — dialhome Go 重构安全模型（Phase 2 冻结稿 v1）

> 不变式来源：REFACTOR_BASELINE §4 + 规格 §2。任何实现 PR 触碰本文件所列不变式时，
> 必须重跑 §6 的负向测试矩阵并附证据。

## 1. 三类身份

### A. Node Tunnel Key（每节点一把）
- **ed25519 私钥在 Node 本机生成、只落 Node 数据目录 `keys/tunnel.key`（0600/仅本用户）**——
  这是相对旧实现（relay 生成后 b64 嵌安装器）的安全升级：私钥不过网。
- 公钥经 Enrollment Credential 提交 Relay，绑定该节点的端口槽位。
- Relay 侧 AK 行（逐字模板，127.0.0.1 不可替换为 localhost 或 0.0.0.0）：
```
restrict,command="<helper-path> --port <SSH_PORT>",port-forwarding,permitlisten="127.0.0.1:<SSH_PORT>",permitlisten="127.0.0.1:<APP_PORT>",permitopen="127.0.0.1:1" ssh-ed25519 <pub> dialhome-node-<name>
```
能力上限：仅 `-R 127.0.0.1:<两个指定回环口>`；无 shell、无文件读、无 -L（permitopen=1）、
不能占他人端口（permitlisten 精确匹配）。`-R` 参数由 Go 代码构造，**地址字面量硬编码**，不接受配置注入。

### B. Controller Management Key
- 私钥只在 Controller（`~/.config/dialhome/keys/manager.key`）；公钥写入**每个 Node** 的
  authorized_keys（Node 侧 sshd），可取该 Node 当前用户的 shell。
- 绝不复制到 Node、绝不进入安装包、绝不进入任何 HTTP 响应体。
- Controller 与 Relay 同机时（当前部署）管理私钥可存 Relay——该机即 Controller。

### C. Enrollment Credential（登记凭证，短期）
- 形态：ed25519 专用密钥对，Relay 侧 AK 行 `restrict,command="<helper> enroll",no-port-forwarding,no-pty,no-user-rc`
  + registry 内 `{credential_id, node_name, expires_at, used_at}` 记录。
- 能力：仅 `enroll` 原语——提交 node 公钥，绑定到**凭证预分配的节点槽位**（不接受客户端指定他节点）。
- 生命周期：生成→节点本地安装消费→登记完成即标记 used（一次性）；过期作废；`relay credentials revoke`。
- 与 A/B 完全分离：凭证不能建隧道、不能登任何机器。

## 2. Node 侧安全

- 本机 sshd：仅 `127.0.0.1:<高位>`、`PasswordAuthentication no`、`PermitEmptyPasswords no`、
  `AllowUsers <当前用户>`、HostKey/AK/log/pid 全在数据目录；**不改系统 ssh 配置**。
- Controller 管理公钥写入 Node 数据目录 authorized_keys（shell 能力给 Controller——规格 §2.1 B 允许）。
- 私钥权限：Unix 0700 目录 / 0600 文件；Windows `icacls /inheritance:r /grant:<user>:F`（去继承）。
- 私钥**从不**进临时目录长期遗留、从不进日志（logging 包统一脱敏：`tunnel.key`/`BEGIN`/`sk-`/`Bearer` 等）。

## 3. Relay 侧安全（AK 更新规程）

写 authorized_keys 的唯一入口 = relay helper / relay 子命令，规程：
1. flock（`~/.dialhome/ak.lock`）串行化全部写者。
2. 读原文件 → 解析为结构化行（保留非 dialhome 行原样）→ 修改目标节点行 → **原子写**（tmp + rename 同目录）→ 保留 `.bak-<ts>`。
3. 单节点撤销绝不触碰其他行；解析失败（意外格式）→ 中止并保留原文件，不整文件清空。
4. 并发登记：端口分配与 AK 写在同一把锁内完成（分配器见 PROTOCOL §4）。
5. 每次写后立即重读校验（行数/目标行存在性），失败回滚备份。

## 4. 威胁模型（明确接受与拒绝）

| 威胁 | 防线 | 状态 |
|---|---|---|
| 校园网扫描发现开口户 | 开放开户是机主拍板的模式；闸门=每IP限速+池上限+无权身份；**可选** token/凭证模式为代码内置（未启用） | 接受（机主决定） |
| 凭证泄露 | 短期+一次性+只绑预分配槽位；泄露者无法登 relay、无法登 node | 防住 |
| Node key 泄露（node 被缴获） | 影响=该节点自己的隧道身份；`relay revoke <name>` 一条命令撤销 | 可控 |
| Controller key 泄露 | 全部节点 shell 沦陷——**最高级秘密**，仅存 Controller；轮换流程 `relay rotate-manager`（Phase 4 实现） | 操作纪律 |
| Relay 被缴获 | 攻击者拿到：各节点公钥（无有用性）、registry、凭证记录；**拿不到任何私钥** | 可控 |
| 中间人（HTTP 开户口） | installer 无私钥（重构后节点本地生成）；注册过程只传公钥与配置——MITM 最多注入自己的公钥到自己名下（registry 绑定槽位），无法冒充他人 | 防住 |

## 5. 日志脱敏（强制）

logging 包对以下模式统一替换 `[REDACTED]`：`-----BEGIN`、`sk-[A-Za-z0-9_-]{8,}`、
`Bearer `、`AAAAC3NzaC1lZDI1NTE5`（公钥体）、32+ hex 连续串。测试覆盖见 §6。

## 6. 负向测试矩阵（全部真实 SSH 验证，Phase 4 验收门）

| # | 断言 | 方法 |
|---|---|---|
| N1 | tunnel key 无法登 relay shell | `ssh -i tunnel.key relay 'id'` → DENY（forced command 输出无 shell） |
| N2 | tunnel key 无法读 relay 文件 | 同上命令树内无文件能力 |
| N3 | tunnel key 无法 -L 进 relay LAN | `ssh -L ...` → permitopen=127.0.0.1:1 拒 |
| N4 | tunnel key 无法执行任意命令 | 同 N1 |
| N5 | tunnel key 不能占他节点端口 | `-R 127.0.0.1:<他人端口>` → 拒 |
| N6 | 不能绑 0.0.0.0 | `-R 0.0.0.0:...` → 拒 |
| N7 | 只能绑自己的两个口 | permitlisten 白名单外端口 → 拒 |
| N8 | manager key 不能用于隧道 | manager 公钥不在 relay AK（仅 Node AK） |
| N9 | 过期/已用凭证不能再登记 | helper 拒绝 |
| N10 | 撤销节点后旧 key 失效 | revoke 后重连 → Permission denied |

继承自旧实现的已实测证据：B1（127.0.0.1 精确匹配）、permitopen=1 拒 -L、
错 key/密码通道拒绝（REFACTOR_BASELINE §3.2、SSH_BACKEND_MATRIX §1）。
