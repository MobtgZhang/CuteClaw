# Changelog

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号与 `src/version.zig` / `build.zig.zon` 一致。

## [0.1.1] - 2026-03-28

### Changed

- 语义版本与 Web Agent 控制台对齐为 0.1.1；宿主支持删除项目与会话跨项目移动；侧栏三栏布局与消息气泡角标操作等（详见 `web/` 变更）。

## [0.2.0] - 2026-03-24

### Added

- CLI：`config validate`；`working show|set`；`fact add`；`serve`（仅 `127.0.0.1`，`GET /health`、`/store`、`/status`，`POST /evolve`）
- 对默认 `store` 路径使用 `store.json.lock` 咨询锁（与 CLI 写路径一致）
- 文档：`docs/cli-exit-codes.md`、`docs/embedding.md`、`docs/roadmap.md`；`testdata/minimal_store_v1.json`；`tests/cli_smoke.sh`；`zig build fmt`
- CI：`.github/workflows/cuteclaw.yml`（Zig 测试 + fmt + 冒烟 + `web` 构建）
- Web：`PUT /api/config` 写入前调用 `cuteclaw config validate`（临时文件 + `CUTECLAW_CONFIG`）

### Changed

- `status` 在无法加载 store 时以退出码 2 失败；`import` JSON 解析失败时退出码 2 并提示 `docs/format.md`
- 帮助文本补充退出码说明
