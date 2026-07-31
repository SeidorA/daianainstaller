.PHONY: help install certs remove-certs update rollback rollback-list uninstall purge version up down restart stop ps logs compose-config bootstrap

COMPOSE_FILES := -f docker-compose.yml -f docker-compose.app.yml -f docker-compose.npm.yml
COMPOSE_CMD := $(shell if docker compose version >/dev/null 2>&1; then printf 'docker compose'; elif command -v docker-compose >/dev/null 2>&1; then printf 'docker-compose'; else printf 'docker compose'; fi)
COMPOSE := $(COMPOSE_CMD) $(COMPOSE_FILES)
WIPE_DIRS := volumes/db/data volumes/storage/stub volumes/daiana/static volumes/daiana/qdrant volumes/daiana/whatsapp volumes/daiana/flowise volumes/daiana/webui
WIPE ?= 0
SNAPSHOT ?=

.DEFAULT_GOAL := help

help:
	@echo "╔════════════════════════════════════════════════════════════╗"
	@echo "║          Daiana installer commands                         ║"
	@echo "╚════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "Lifecycle:"
	@echo "  make install                  Run install-daiana.sh"
	@echo "  make certs                    Apply TLS to existing NPM proxy hosts"
	@echo "  make remove-certs CONFIRM=1  Remove TLS and refresh HTTP public URLs"
	@echo "  make update                   Run update-daiana.sh"
	@echo "  make rollback                 Roll back to latest update snapshot"
	@echo "  make rollback SNAPSHOT=<id>   Roll back to a specific snapshot"
	@echo "  make rollback-list            List update rollback snapshots"
	@echo "  make uninstall                Run uninstall-daiana.sh"
	@echo "  make purge                    Run uninstall-daiana.sh --purge"
	@echo "  make version                  Show installer version and git describe"
	@echo ""
	@echo "Local compose helpers (developer/local only):"
	@echo "  make up                      Start Docker Compose directly"
	@echo "  make up WIPE=1               Start after cleaning runtime data, preserving update-history"
	@echo "  make down                    Stop Docker Compose directly"
	@echo "  make down WIPE=1             Stop and clean runtime data, preserving update-history"
	@echo "  make ps                      Show compose status"
	@echo "  make logs                    Follow compose logs"
	@echo "  make compose-config          Render compose config"
	@echo ""
	@echo "Service helper variables:"
	@echo "  SERVICE=<service>            Limit up/down/restart/stop/ps/logs"
	@echo ""

install:
	@bash install-daiana.sh

certs:
	@bash apply-certs.sh

remove-certs:
	@test "$(CONFIRM)" = 1 || { echo "Use: make remove-certs CONFIRM=1" >&2; exit 1; }
	@bash remove-certs.sh --confirm $(if $(CERTIFICATE_ID),--certificate-id=$(CERTIFICATE_ID),) $(if $(ALL_MANAGED),--all-managed,)

update:
	@bash update-daiana.sh

rollback:
	@if [ -n "$(SNAPSHOT)" ]; then \
		bash update-daiana.sh --rollback "$(SNAPSHOT)"; \
	else \
		bash update-daiana.sh --rollback; \
	fi

rollback-list:
	@bash update-daiana.sh --rollback --list

uninstall:
	@bash uninstall-daiana.sh

purge:
	@bash uninstall-daiana.sh --purge

version:
	@printf 'Installer version: '
	@if [ -f VERSION ]; then cat VERSION; else echo 'unknown'; fi
	@printf 'Git version: '
	@git describe --tags --always --dirty 2>/dev/null || echo 'unknown'

up:
	@if [ -n "$(SERVICE)" ]; then \
		if [ "$(WIPE)" = "1" ]; then \
			echo "⚠️  WIPE=1 is ignored when SERVICE is set"; \
		fi; \
		echo "Starting service $(SERVICE)..."; \
		$(COMPOSE) up -d "$(SERVICE)"; \
		echo "✓ Service $(SERVICE) started"; \
	else \
		if [ "$(WIPE)" = "1" ]; then \
			if $(COMPOSE) ps 2>/dev/null | grep -q "Up"; then \
				echo "Docker Compose is running. Stopping first..."; \
				$(COMPOSE) down; \
			fi; \
			echo "Cleaning runtime data while preserving volumes/daiana/update-history..."; \
			rm -rf $(WIPE_DIRS); \
		fi; \
		echo "Starting Docker Compose directly..."; \
		$(COMPOSE) up -d; \
		echo "✓ Docker Compose started"; \
	fi

down:
	@if [ -n "$(SERVICE)" ]; then \
		if [ "$(WIPE)" = "1" ]; then \
			echo "⚠️  WIPE=1 is ignored when SERVICE is set"; \
		fi; \
		echo "Stopping service $(SERVICE)..."; \
		$(COMPOSE) stop "$(SERVICE)"; \
		$(COMPOSE) rm -f "$(SERVICE)"; \
	else \
		echo "Stopping Docker Compose directly..."; \
		$(COMPOSE) down; \
		if [ "$(WIPE)" = "1" ]; then \
			echo "Cleaning runtime data while preserving volumes/daiana/update-history..."; \
			rm -rf $(WIPE_DIRS); \
		fi; \
	fi
	@echo "✓ Docker Compose stopped"

restart:
	@if [ -n "$(SERVICE)" ]; then \
		echo "Restarting service $(SERVICE)..."; \
		$(COMPOSE) restart "$(SERVICE)"; \
	else \
		echo "Restarting Docker Compose directly..."; \
		$(COMPOSE) restart; \
	fi
	@echo "✓ Docker Compose restarted"

stop:
	@if [ -n "$(SERVICE)" ]; then \
		echo "Stopping service $(SERVICE)..."; \
		$(COMPOSE) stop "$(SERVICE)"; \
	else \
		echo "Stopping Docker Compose directly..."; \
		$(COMPOSE) stop; \
	fi
	@echo "✓ Docker Compose stopped"

ps:
	@if [ -n "$(SERVICE)" ]; then \
		$(COMPOSE) ps "$(SERVICE)"; \
	else \
		$(COMPOSE) ps; \
	fi

logs:
	@if [ -n "$(SERVICE)" ]; then \
		$(COMPOSE) logs -f "$(SERVICE)"; \
	else \
		$(COMPOSE) logs -f; \
	fi

compose-config:
	@$(COMPOSE) config

bootstrap:
	@echo "⚠️  make bootstrap is kept for local compatibility. Prefer: make certs"
	@if [ ! -f .env ]; then \
		echo "❌ .env not found"; \
		exit 1; \
	fi
	@echo "Loading variables from .env..."
	@set -a; . .env; set +a; \
	if [ -z "$$NPM_ADMIN_EMAIL" ] || [ -z "$$NPM_ADMIN_PASS" ]; then \
		echo "❌ Missing required variables in .env:"; \
		[ -z "$$NPM_ADMIN_EMAIL" ] && echo "  - NPM_ADMIN_EMAIL"; \
		[ -z "$$NPM_ADMIN_PASS" ] && echo "  - NPM_ADMIN_PASS"; \
		exit 1; \
	fi; \
	echo "✓ Variables loaded:"; \
	echo "  - NPM_ADMIN_EMAIL: $$NPM_ADMIN_EMAIL"; \
	echo "  - NPM_ADMIN_PASS: (configured)"; \
	[ -n "$$BASE_DOMAIN" ] && echo "  - BASE_DOMAIN: $$BASE_DOMAIN"; \
	echo ""; \
	echo "Running npm_ssl_bootstrap..."; \
		bash utils/npm_ssl_bootstrap.sh; \
	echo "✓ Bootstrap complete"
