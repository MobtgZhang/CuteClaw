# CuteClaw — 常用构建与运行入口（需 Zig 0.17.0+）
# 用法示例:
#   make                  # 显示帮助
#   make build
#   make run              # 默认执行: zig build run -- help
#   make run ARGS=status
#   make run ARGS="evolve --file examples/proposal.json --policy auto_append_only --semver 0.3.0"

ZIG ?= zig

.PHONY: default help all build test fmt fmt-fix run install clean smoke network-test dsh benchmark drc schemas graph loop live-chat check app-install app-build app-dev web-install web-build web-dev web-dev-zig

# 传给 `zig build run -- …` 的子命令与参数（空格请整条加引号）
ARGS ?= help

BIN := zig-out/bin/cuteclaw

default: help

help:
	@echo "CuteClaw Makefile"
	@echo ""
	@echo "  make build       zig build"
	@echo "  make test        zig build test"
	@echo "  make fmt         zig build fmt（检查 src/ 格式）"
	@echo "  make fmt-fix     zig fmt src（写入格式化）"
	@echo "  make run         zig build run -- \$$(ARGS)   默认 ARGS=$(ARGS)"
	@echo "  make install     zig build install"
	@echo "  make smoke       先 build，再跑 tests/cli_smoke.sh"
	@echo "  make network-test 先 build，再跑 tests/agent_web_fetch_search.sh（需外网）"
	@echo "  make dsh         DeepSeek Harness（Cordis）插件兼容桥接测试"
	@echo "  make benchmark   设计基准：硬约束淘汰 + 优化排序"
	@echo "  make drc         KiCad/STEP 适配器与 DRC、外壳配合校验"
	@echo "  make schemas     JSON Schema 校验"
	@echo "  make graph       Graph Flow / Graph Loop：技能目录、工作形状审计、硬门与检查点"
	@echo "  make loop        Agent Loop：计划只读、二元终止条件、hook 只能收紧、审批、压缩审计、检查点、子代理写入边界"
	@echo "  make live-chat   用测试 API（默认 /data/api.json）跑一轮真实对话；不可达则跳过"
	@echo "  make check       build + test + smoke + dsh + benchmark + drc + schemas + graph + loop"
	@echo "  make clean       删除 zig-out/"
	@echo "  make app-install cd apps/web && npm install（Vue + TypeScript 前端）"
	@echo "  make app-build   cd apps/web && npm run build（产物 apps/web/dist，serve 的静态根）"
	@echo "  make app-dev     cd apps/web && npm run dev（Vite 5173，代理到 8788）"
	@echo "  make web-install cd web && npm install"
	@echo "  make web-build   cd web && npm run build"
	@echo "  make web-dev      cd web && npm run dev（Vite 5173 + Zig 8788 + Agent 8790；需已 zig build）"
	@echo "  make web-dev-zig  zig build 后再 web-dev"
	@echo ""
	@echo "  make all         build + test + fmt"

all: build test fmt

build:
	$(ZIG) build

test:
	$(ZIG) build test

fmt:
	$(ZIG) build fmt

fmt-fix:
	$(ZIG) fmt src

run: build
	$(ZIG) build run -- $(ARGS)

install:
	$(ZIG) build install

clean:
	rm -rf zig-out .zig-cache

smoke: build
	bash tests/cli_smoke.sh "$(CURDIR)/$(BIN)"

network-test: build
	bash tests/agent_web_fetch_search.sh "$(CURDIR)/$(BIN)"

check: build test
	bash tests/cli_smoke.sh "$(CURDIR)/$(BIN)"
	bash tests/dsh_bridge.sh "$(CURDIR)/$(BIN)"
	bash tests/design_benchmark.sh "$(CURDIR)/$(BIN)"
	bash tests/design_drc.sh "$(CURDIR)/$(BIN)"
	bash tests/schemas.sh "$(CURDIR)/$(BIN)"
	bash tests/graph.sh "$(CURDIR)/$(BIN)"
	bash tests/agent_loop.sh "$(CURDIR)/$(BIN)"

dsh: build
	bash tests/dsh_bridge.sh "$(CURDIR)/$(BIN)"

benchmark: build
	bash tests/design_benchmark.sh "$(CURDIR)/$(BIN)"

drc: build
	bash tests/design_drc.sh "$(CURDIR)/$(BIN)"

schemas: build
	bash tests/schemas.sh "$(CURDIR)/$(BIN)"

graph: build
	bash tests/graph.sh "$(CURDIR)/$(BIN)"

loop: build
	bash tests/agent_loop.sh "$(CURDIR)/$(BIN)"

live-chat: build
	bash tests/live_chat.sh "$(CURDIR)/$(BIN)"

app-install:
	cd apps/web && npm install

app-build: app-install
	cd apps/web && npm run build

app-dev: app-install
	cd apps/web && npm run dev

web-install:
	cd web && npm install

web-build: web-install
	cd web && npm run build

web-dev: web-install
	cd web && npm run dev

web-dev-zig: build web-dev
