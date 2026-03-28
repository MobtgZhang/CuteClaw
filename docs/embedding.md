# 将 CuteClaw 嵌入宿主进程（Zig）

## 角色

CuteClaw 提供**确定性**记忆、进化门禁、指标与 JSON 持久化；**不**包含 LLM、网络与沙箱。宿主（另一 Zig 程序、Python、Rust 等）负责调用模型与工具，在适当时机写入本库。

## 生命周期

1. **`ClawRuntime.init(parent_allocator)`**  
   - 使用独立 `gpa` 作为 `parent` 时，Arena 与 `MetricsRegistry` 均从该分配器获取内存。

2. **加载快照前**  
   - 调用 **`resetContent`**（或由 **`persist.loadFromPath` / `applyLoadedDocument`** 间接清空再灌入）。

3. **写入情景 / 事实 / 技能**  
   - `rememberEpisode`、`addFact`、`addSkillCopy`；进化合并用 **`applyProposal`**（会写审计）。

4. **任务与调用信号**  
   - `recordTaskSignal`（或 CLI 等价路径）；技能统计用 **`metrics.recordSkillInvocation`**（与 CLI `invoke` 一致）。

5. **工作区**  
   - **`setWorking`** 替换整块 `WorkingSet`（四字段均由 Arena 持有副本）。

6. **持久化**  
   - **`persist.saveToPath`** / **`saveToFile`**：原子写入 `store.json`。

## 与 GenericAgent 概念对照（简表）

| GenericAgent（见仓库 `docs/generic-agent-architecture.md`） | CuteClaw |
|-------------------------------------------------------------|----------|
| 工作记忆 / checkpoint | `WorkingSet` + 情景 `episodic` |
| 长期记忆 / 全局摘要 | 可由宿主映射到 `facts` 或外部存储；库内为结构化 `facts` |
| 可复用规程 / 工具说明 | `skills[]` 版本链 + `evolve` 合并 |
| 观测与审计 | `metrics`（rollup + `audit` 环） |

## 并发

多进程同时写同一 `store.json` 仍可能冲突。CLI 与 **`cuteclaw serve`** 在支持的平台上对 `store.json.lock` 使用**咨询锁**协调；其他宿主应自行串行化或只读打开。
