# 数据格式（Schema v1）

## 快照文件 `store.json`

由 `persist.saveToPath` / `saveToFile` 写入，**原子替换**（先写 `*.tmp` 再 `rename`）。单文件原始 JSON 大小上限为 **`persist.max_file_bytes`（当前 32MiB）**；超大或畸形文档会解析失败（`import` 失败时见 CLI 提示与本文档）。

与默认 store 同目录会创建 **`store.json.lock`**（咨询锁）：CLI 在读写 store 前后会尝试获取锁；不支持 `flock` 的平台将静默跳过，行为与早期版本一致。

根对象类型对应 `persist.StoreDocumentV1`：

| 字段 | 类型 | 说明 |
|------|------|------|
| `schema_version` | `u32` | 当前固定为 **1** |
| `library_version` | 字符串 | 与 `version.zig` / CLI `version` 一致 |
| `saved_unix` | `i64` | 保存时 Unix 秒时间戳 |
| `episodic` | 数组 | 情景记录 |
| `skills` | 数组 | 技能版本列表（顺序即加载顺序） |
| `facts` | 数组 | 语义事实 |
| `rollups` | 数组 | 技能调用滚动统计 |
| `audit` | 数组 | 进化审计（尾部长度受 `metrics.audit_cap` 约束，加载时会临时放大 cap 以还原） |
| `tasks_recorded` | `u64` | `recordTask` 累计次数 |
| `tasks_succeeded` | `u64` | 其中成功次数 |
| `working` | 对象 | 工作区四字段 |

### `episodic[]`

- `task_id`, `ended_unix`, `summary`, `outcome`（`success` \| `failed` \| `aborted` \| `needs_human`）

### `skills[]`

- `name`, `version`, `preconditions`, `prohibitions`, `body`

### `facts[]`

- `key`, `value`, `confidence`（`f32`）

### `rollups[]`

- `skill_name`, `invocations`, `successes`, `failures`, `last_patch_unix`

### `audit[]`

- `unix_ts`, `skill_name`, `policy`, `result`（`accepted` \| `rejected` \| `deferred`）, `detail`

### `working`

- `goal`, `constraints`, `confirmed_facts`, `next_step`

未知字段在解析时**可忽略**（`ignore_unknown_fields`），便于未来 bump schema。

## API 配置文件 `config.json`

与 `store.json` 同目录（默认 `.cuteclaw/config.json`），供宿主或后续扩展读取 LLM / HTTP API 参数。**不要将 API 密钥明文写入此文件**；应使用 `api_key_file` 指向仅本地可读的文件，或依赖 `api_key_env` 指向的环境变量。

对应类型 `config.ApiConfigJson` / `config.ApiConfigOwned`，`schema_version` 当前为 **1**。

| 字段 | 类型 | 说明 |
|------|------|------|
| `schema_version` | `u32` | 必须为 **1** |
| `provider` | 字符串 | 如 `openai_compat`、`anthropic_compat`、`custom`（由宿主解释） |
| `api_base` | 字符串 | 兼容 OpenAI 时多为 `https://host/v1` |
| `api_key_file` | 字符串 | 密钥文件路径；空则只看环境变量 |
| `api_key_env` | 字符串 | 环境变量名，默认 `OPENAI_API_KEY` |
| `model` | 字符串 | 模型 id |
| `connect_timeout_sec` | `u32` | 连接超时（秒） |
| `read_timeout_sec` | `u32` | 读超时（秒） |
| `extra_headers` | 数组 | `{ "name", "value" }`，慎用敏感值 |

CLI：`config init` 写入默认模板；`config show` 打印配置并检测密钥是否可解析（**不打印密钥内容**）。路径由 `--config` 或 `CUTECLAW_CONFIG` 指定。

参考 `examples/config.json`。

## 提议文件（`evolve` / `validate`）

JSON 对象，字段对应 `evolution.Proposal`：

| 字段 | 必填 | 说明 |
|------|------|------|
| `skill_name` | 是 | ≥2 字符 |
| `patch_summary` | 是 | ≥4 字符 |
| `new_body` | 是 | ≥8 字符，≤ 512KiB |
| `version_hint` | 否 | 仅提示，真正版本由 CLI `--semver` 传入 |
| `preconditions` | 否 | 写入技能 |
| `prohibitions` | 否 | 写入技能 |

参考 `examples/proposal.json`。

## 宽松 Semver

`auto_append_only` 策略下，`--semver` 须为 **1～3 段**、每段**纯数字**（如 `1`、`0.2`、`1.0.0`）。不得带 `v` 前缀。
