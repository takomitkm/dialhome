# CONFIG_SCHEMA — dialhome 配置模式（Phase 2 冻结稿 v1）

全部 JSON、UTF-8、无 BOM；`config_version` 整数递增，`internal/config` 负责迁移。

## 1. Node — `<data>/config.json`

```json
{
  "config_version": 1,
  "node": {
    "name": "hp66",
    "relay": { "address": "10.101.54.192", "port": 18322, "user": "user" },
    "sshd": {
      "listen": "127.0.0.1:19022",
      "openssh_dir": "%LOCALAPPDATA%/dialhome/openssh",
      "host_key": "keys/host_ed25519",
      "authorized_keys": "keys/authorized_keys",
      "log": "logs/sshd.log",
      "pid_file": "state/sshd.pid"
    },
    "channels": [
      { "name": "ssh", "local": "127.0.0.1:19022", "remote": "127.0.0.1:13441", "enabled": true },
      { "name": "application", "local": "127.0.0.1:3425", "remote": "127.0.0.1:13440", "enabled": false }
    ],
    "mode": "persistent",
    "register": { "enabled": true, "interval_minutes": 30 }
  },
  "supervisor": {
    "boot_wait_max_seconds": 600,
    "retry": { "base_seconds": 5, "max_seconds": 60, "fails_to_hourly": 10, "hourly_seconds": 3600 },
    "keepalive": { "interval_seconds": 15, "count_max": 3 },
    "connect_timeout_seconds": 10
  }
}
```

不变式（config 加载器强制，违者拒载）：
- `channels[].local/remote` 必须以 `127.0.0.1:` 开头（规格 §2.3/§3.5）
- `channels` 至少含 `ssh`；`name` 唯一
- `mode ∈ {persistent, temporary}`
- `retry.fails_to_hourly ≥ 1`、`max_seconds ≤ hourly_seconds`

## 2. Node — `<data>/identity.json`（register/reconcile 产物，节点可写）

```json
{
  "uuid": "4C4C4544-0042-...",
  "macs": ["AA-BB-CC-DD-EE-FF"],
  "hostname": "HP66",
  "user": "Administrator",
  "fingerprint": "a1b2c3d4e5f60718",
  "updated_at": "2026-11-14T09:00:00Z"
}
```

## 3. Controller — `<cfg>/machines.json`（沿用旧概念，结构化升级）

```json
{
  "config_version": 1,
  "machines": {
    "school": {
      "display": "校机 Win11-HV1",
      "shell": "cmd",
      "note": "无 UAC；D 盘 1.8TB",
      "anchors": [
        { "alias": "school-guest",      "kind": "ssh_alias",  "local_port": null },
        { "alias": "school-guest-pc2",  "kind": "ssh_alias",  "local_port": 13401 },
        { "kind": "dialhome",           "node": "school",     "via_relay": "10.101.54.192:18322", "local_port": null }
      ]
    }
  },
  "defaults": { "connect_timeout_seconds": 10 }
}
```

`kind=ssh_alias` → 直接用 `~/.ssh/config` 别名（不迁移用户 SSH 配置）；
`kind=dialhome` → dialhome 自己的经 relay 路径。failover 按 anchors 顺序。

## 4. Relay — `<relay>/registry.json`

```json
{
  "config_version": 1,
  "port_pool": { "base": 13440, "top": 13600 },
  "helper_path": "/home/user/.dialhome/bin/dialhome",
  "nodes": {
    "hp66": {
      "state": "active",
      "ports": { "ssh": 13441, "app": 13440 },
      "tunnel_pubkey_fp": "SHA256:xxxx",
      "credential_id": "cred-7f3a",
      "hardware": { "uuid": "...", "macs": ["..."], "user": "Administrator", "hostname": "HP66" },
      "registered_at": "2026-11-13T12:00:00Z",
      "last_check": "2026-11-14T09:30:00Z"
    }
  },
  "credentials": {
    "cred-7f3a": { "node": "hp66", "pubkey_fp": "SHA256:yyyy", "expires_at": "2026-11-13T15:00:00Z", "used_at": null }
  }
}
```

`authorized_keys` 不在 registry 内（真实文件，规程见 SECURITY_MODEL §3）。

## 5. Credential 文件（Node 侧消费格式，Controller/Relay 产出）

```json
{
  "credential_version": 1,
  "relay": { "address": "10.101.54.192", "port": 18322, "user": "user" },
  "node_name": "hp66",
  "private_key_openssh_b64": "...",
  "manager_pubkey": "ssh-ed25519 AAAA... controller",
  "expires_at": "2026-11-13T15:00:00Z"
}
```

## 6. 迁移映射（`migrate --from-legacy` 输入→输出）

| 旧 | 新 |
|---|---|
| relay `machines.json`（fp/uuid/macs/user/…） | relay `registry.json[nodes].hardware` |
| relay `bootstrap-names.json` | 仅作 IP→fp 桥接提示，不迁移 |
| relay authorized_keys 双标记行 | 解析后并入 `registry.json` + 重写为 `~/.dialhome/authorized_keys`（原文件备份不动） |
| node `D:\zc\sshd\{host key, node_key, sshd_config}` | `keys/`（host key 原样保留——**变更会触发 relay known_hosts 告警**，迁移器显式处理）、node_key → `keys/tunnel.key` |
| node Startup lnk + HKCU Run | 卸载旧入口 → 注册 `dialhomed node run` 新入口 |
| node tunnel-*.err | 不迁移（日志非身份） |
| controller dial.py MACHINES | `machines.json`（ssh_alias anchors 原样引用） |
