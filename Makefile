KNOWN_ENVS := dev prod

normalize-env = $(strip $(if $(filter prod production,$1),prod,$(if $(filter dev development,$1),dev,$1)))

AUTO_ENV := $(strip $(shell \
	found=""; \
	for env in $(KNOWN_ENVS); do \
		compose_file="docker/docker-compose.$$env.yml"; \
		if [ ! -f "$$compose_file" ]; then \
			continue; \
		fi; \
		container_id="$$(docker compose -f "$$compose_file" ps -q backend 2>/dev/null)"; \
		if [ -n "$$container_id" ]; then \
			if [ -n "$$found" ]; then \
				echo dev; \
				exit 0; \
			fi; \
			found="$$env"; \
		fi; \
	done; \
	echo "$${found:-dev}" \
))

ifdef ENV
RAW_ENV := $(ENV)
else ifdef APP_ENV
RAW_ENV := $(APP_ENV)
else ifdef NODE_ENV
RAW_ENV := $(NODE_ENV)
else
RAW_ENV := $(AUTO_ENV)
endif

ACTIVE_ENV := $(call normalize-env,$(RAW_ENV))

ifeq ($(filter $(ACTIVE_ENV),$(KNOWN_ENVS)),)
$(error Unsupported ENV '$(ACTIVE_ENV)'. Expected one of: $(KNOWN_ENVS))
endif

COMPOSE_FILE := docker/docker-compose.$(ACTIVE_ENV).yml
COMPOSE := docker compose -f $(COMPOSE_FILE)
BACKEND_EXEC := $(COMPOSE) exec backend
BACKEND_EXEC_T := $(COMPOSE) exec -T backend

export OCR_PROVIDER
export OCR_PRELOAD_MODELS
export OCR_LOG_WORD_SCORES

define require-dev
	@if [ "$(ACTIVE_ENV)" != "dev" ]; then \
		echo "Target '$@' is only allowed with ENV=dev (current: $(ACTIVE_ENV))."; \
		exit 1; \
	fi
endef

.PHONY: \
	default \
	env \
	help \
	show-env \
	start \
	stop \
	back.start \
	back.reset \
	ocr.start \
	ocr.rebuild \
	ocr.health \
	db.migrate \
	db.seed \
	db.reset \
	db.reset.push \
	db.generate \
	db.sh \
	db.psql \
	test \
	audit-role-scope \
	audit-multi-packaging \
	dev.start \
	dev.stop \
	dev.back.start \
	dev.back.reset \
	dev.ocr.start \
	dev.ocr.rebuild \
	dev.ocr.health \
	dev.db.migrate \
	dev.db.seed \
	dev.db.reset \
	dev.db.reset.push \
	dev.db.generate \
	dev.db.sh \
	dev.db.psql \
	dev.test

default: env help

env: show-env

show-env:
	@echo "ENV=$(ACTIVE_ENV)"
	@echo "COMPOSE_FILE=$(COMPOSE_FILE)"

help:
	@echo ""
	@echo "Available commands for ENV=$(ACTIVE_ENV)"
	@echo ""
	@echo "General"
	@echo "  make start"
	@echo "  make stop"
	@echo "  make back.start"
	@echo "  make ocr.start"
	@echo "  make ocr.rebuild"
	@echo "  make ocr.health"
	@echo "  make db.generate"
	@echo "  make db.sh"
	@echo "  make db.psql"
	@echo "  make test"
	@echo "  make audit-role-scope [OUT=path] [STRICT=1]"
	@echo "  make audit-multi-packaging [OUT=path] [STRICT=1]"
	@if [ "$(ACTIVE_ENV)" = "dev" ]; then \
		echo ""; \
		echo "Dev-only"; \
		echo "  make db.migrate name=<migration_name>"; \
		echo "  make db.seed"; \
		echo "  make db.reset"; \
		echo "  make db.reset.push"; \
		echo "  make back.reset"; \
	else \
		echo ""; \
		echo "Dev-only commands are disabled for ENV=$(ACTIVE_ENV)."; \
	fi

start:
	$(COMPOSE) up --build

stop:
	$(COMPOSE) down

back.start:
	$(COMPOSE) up backend

ocr.start:
	$(COMPOSE) up ocr

ocr.rebuild:
	$(COMPOSE) up -d --build --force-recreate ocr

back.reset:
	$(call require-dev)
	$(COMPOSE) rm -fs backend
	$(COMPOSE) up --build --no-deps backend

ocr.health:
	$(COMPOSE) exec ocr python -c 'import urllib.request; print(urllib.request.urlopen("http://localhost:8000/health").read().decode())'

db.migrate:
	$(call require-dev)
	$(BACKEND_EXEC) npx prisma migrate dev --name $(name)

db.seed:
	$(call require-dev)
	$(BACKEND_EXEC) npm run seed

db.reset:
	$(call require-dev)
	$(BACKEND_EXEC) sh -c "npx prisma migrate reset --force && npm run seed:dev"

db.reset.push:
	$(call require-dev)
	$(BACKEND_EXEC) sh -c "npx prisma migrate reset --force && npx prisma db push && npm run seed:dev"

db.generate:
	$(BACKEND_EXEC) npx prisma generate

db.sh:
	$(BACKEND_EXEC) sh

db.psql:
	$(COMPOSE) exec postgres sh -lc 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

test:
	cd backend && npm test

AUDIT_ROLE_SCOPE_ARGS :=
AUDIT_ROLE_SCOPE_CONTAINER_OUT := /tmp/role-scope-audit.json
AUDIT_MULTI_PACKAGING_ARGS :=
AUDIT_MULTI_PACKAGING_CONTAINER_OUT := /tmp/multi-packaging-audit.json

ifneq ($(strip $(OUT)),)
AUDIT_ROLE_SCOPE_ARGS += --out $(AUDIT_ROLE_SCOPE_CONTAINER_OUT)
AUDIT_MULTI_PACKAGING_ARGS += --out $(AUDIT_MULTI_PACKAGING_CONTAINER_OUT)
endif

ifneq ($(filter 1 true TRUE yes YES,$(STRICT)),)
AUDIT_ROLE_SCOPE_ARGS += --strict
AUDIT_MULTI_PACKAGING_ARGS += --strict
endif

audit-role-scope:
	$(BACKEND_EXEC_T) sh -lc 'cd /app/backend && npx ts-node -r tsconfig-paths/register src/scripts/roleScopeAudit.ts $(AUDIT_ROLE_SCOPE_ARGS)'
ifneq ($(strip $(OUT)),)
	mkdir -p "$(dir $(OUT))"
	$(BACKEND_EXEC_T) cat $(AUDIT_ROLE_SCOPE_CONTAINER_OUT) > "$(OUT)"
	@echo "Trace copied to $(OUT)"
endif

audit-multi-packaging:
	$(BACKEND_EXEC_T) sh -lc 'cd /app/backend && npx ts-node -r tsconfig-paths/register src/scripts/multiPackagingAudit.ts $(AUDIT_MULTI_PACKAGING_ARGS)'
ifneq ($(strip $(OUT)),)
	mkdir -p "$(dir $(OUT))"
	$(BACKEND_EXEC_T) cat $(AUDIT_MULTI_PACKAGING_CONTAINER_OUT) > "$(OUT)"
	@echo "Trace copied to $(OUT)"
endif

dev.start: start
dev.stop: stop
dev.back.start: back.start
dev.back.reset: back.reset
dev.ocr.start: ocr.start
dev.ocr.rebuild: ocr.rebuild
dev.ocr.health: ocr.health
dev.db.migrate: db.migrate
dev.db.seed: db.seed
dev.db.reset: db.reset
dev.db.reset.push: db.reset.push
dev.db.generate: db.generate
dev.db.sh: db.sh
dev.db.psql: db.psql
dev.test: test
