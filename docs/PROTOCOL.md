# PROTOCOL — dialhome 登记与运行协议（Phase 2 冻结稿 v1）

## 1. 登记协议（Node ⇄ Relay）

前置：Controller 已在 Relay 上执行 `dialhome relay enroll <node-name>`：

```
relay 侧生成 Enrollment Credential（ec_kp + AK 行 restrict,command="<helper> enroll",no-port-forwarding,no-pty）
registry.json 记录: { node: <name>, ports: {ssh, app}, state: "pending", credential_id, expires_at(+24h) }
产出: credential 私钥(b64) + 节点安装参数( relay 地址/端口、node 名、管理公钥 )
```

Node 侧（`dialhome node install --credential cred.json`）：

```
1. 本机生成 host key + tunnel key（ed25519，私钥不出机）
2. HTTP(或经 SSH gate) POST enroll:
   SSH: ssh -i ec_priv relay "enroll <pubkey-b64> [fp]"        # helper 校验凭证
3. Relay helper 校验: 凭证有效且未过期未使用 → 取该凭证预分配槽位
   → AK 原子写入受限行（节点公钥）→ registry state=pending→active, credential used_at=now
   → 返回 JSON: { node_name, ports{ssh,app}, manager_pubkey, openssh_fetch }
4. Node 写 controller 公钥进本机 authorized_keys；生成 sshd_config；起 sshd
5. 隧道上线后 register {uuid,macs,user}（经节点 key forced command）
```

幂等保证：重复 `node install`（同机）→ 本机已有 tunnel key → 提交同公钥 → helper 检索
registry 公钥指纹 → 命中既有节点 → 返回原槽位（不新分配端口/不重复 AK 行）。
同硬件重装 → fp 命中既有记录（同 register/reconcile 归并规则）→ 复用槽位。

## 2. 运行期协议

- 隧道：每通道独立 `ssh -N -R 127.0.0.1:<remote>:127.0.0.1:<local>`（参数由 Go 构造），
  语义同基线 §3.3（keepalive 15×3、超时 10s、ExitOnForwardFailure、重试梯、boot-wait）。
- 探活：Controller `controller status` → 对每个通道做 relay 回环 TCP 连接探测 + 节点 forced
  command `check`（JSON：`{ok, listener, service}`）。
- 身份上报（register）：`{"uuid":"...","macs":"...","user":"..."}` → helper 以调用者端口反查
  节点 → 只写自己记录。reconcile 定期经 Controller/relay SSH 进节点比对实时硬件事实。

## 3. Relay authorized_keys 文件

独立文件 `~/.dialhome/authorized_keys`（**非系统文件**），由系统 `authorized_keys` 末行
`Include ~/.dialhome/authorized_keys` 引入（OpenSSH ≥7.3 支持 Include；Debian 13 / 系统 sshd 实测支持
—— Phase 1 已确认系统 sshd 在跑，Include 行为在 Phase 4 集成测试中验证；不支持 Include 的老版本
回退方案：helper 直接维护系统 AK，写入规程同 SECURITY_MODEL §3，迁移期支持两种形态）。

行格式（dialhome 管理的行，结构化解析，不做裸 grep）：
```
restrict,command="<helper> --port <P>",port-forwarding,permitlisten="127.0.0.1:<P>",permitlisten="127.0.0.1:<P2>",permitopen="127.0.0.1:1" <type> <b64> <comment=dialhome-node-<name>|dialhome-credential-<id>>
```
非 dialhome 行原样保留；解析器输出 `{kind, ports[], key_fp, comment, raw}`。

## 4. 端口分配器

- 池：`[13440, 13600)`，步进 2，`(app=偶, ssh=奇)`；与旧实现兼容（迁移节点原样保留原端口）。
- 分配：registry 内所有 active/pending 节点的端口集合 ∪ `ss -ltn` 当前监听 → 池内首个空闲对；
  全程持 `ak.lock`；分配结果先写 registry（pending）再写 AK。
- 回收：`revoke` 后端口立即从 registry 移除（AK 行删除即失效；监听释放延迟由分配探测兜底）。

## 5. Controller ⇄ Node

- 一切经 relay 回环口：`ssh -p <relay-port> -J <relay-jump>` 或（现网形态）本机
  `ProxyCommand`/`-J` 别名。`machines.json` anchors 记录 local_port（经 `-L` 预建）或直接
  `ProxyJump` 链；两者都兼容，探测顺序取第一个活锚。
- 命令执行约束（规格 §4.3）：本地 exec.Command 参数数组；远端命令串仅作为 ssh 尾参；
  脚本体走 stdin（`ssh node "bash -s" < script` 形态由 Go `cmd.StdinPipe` 实现），
  杜绝多层引号拼接；退出码/stdout/stderr 分别保留；连接失败与远端失败分报（ssh rc=255 且
  stderr 含连接类错误 → 连接失败）。

## 6. 兼容协议（迁移期并存）

旧实现协议（PS 安装器、bootstrap HTTP /i、gate enroll 文本参数）在迁移窗口内保持可服务：
- helper 同时接受旧 `register {json}` 与新协议（同一入口）
- `migrate --from-legacy` 读取基线 §6 全部旧格式，生成新 config/identity，**不重分配**端口与身份
- 双版本并行验证步骤见规格 §10
