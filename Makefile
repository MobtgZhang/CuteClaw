# CuteClaw — 常用构建与运行入口（需 Zig 0.15.2+）
# 用法示例:
#   make                  # 显示帮助
#   make build
#   make run              # 默认执行: zig build run -- help
#   make run ARGS=status
#   make run ARGS="evolve --file examples/proposal.json --policy auto_append_only --semver 0.3.0"

ZIG ?= zig

.PHONY: default help all build test fmt fmt-fix run install clean smoke network-test web-install web-build web-dev web-dev-zig

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
	@echo "  make clean       删除 zig-out/"
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

web-install:
	cd web && npm install

web-build: web-install
	cd web && npm run build

web-dev: web-install
	cd web && npm run dev

web-dev-zig: build web-dev
