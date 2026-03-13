# 🔧 Développement

dev.start:
	docker compose -f docker/docker-compose.dev.yml up --build

dev.stop:
	docker compose -f docker/docker-compose.dev.yml down

dev.back.start:
	docker compose -f docker/docker-compose.dev.yml up backend

dev.back.reset:
	docker compose -f docker/docker-compose.dev.yml rm -fs backend && \
	docker compose -f docker/docker-compose.dev.yml up --build --no-deps backend

# Migration Prisma avec nom dynamique
dev.db.migrate:
	docker compose -f docker/docker-compose.dev.yml exec backend npx prisma migrate dev --name $(name)

dev.db.seed:
	docker compose -f docker/docker-compose.dev.yml exec backend npm run seed

dev.db.reset:
	docker compose -f docker/docker-compose.dev.yml exec backend sh -c "npx prisma migrate reset --force && npm run seed:dev"

dev.db.reset.push:
	docker compose -f docker/docker-compose.dev.yml exec backend sh -c "npx prisma migrate reset --force && npx prisma db push && npm run seed:dev"

dev.db.generate:
	docker compose -f docker/docker-compose.dev.yml exec backend npx prisma generate

dev.db.sh:
	docker compose -f docker/docker-compose.dev.yml exec backend sh

dev.test: 
	cd backend && npm test

AUDIT_ROLE_SCOPE_ARGS :=
AUDIT_ROLE_SCOPE_CONTAINER_OUT := /tmp/role-scope-audit.json

ifneq ($(strip $(OUT)),)
AUDIT_ROLE_SCOPE_ARGS += --out $(AUDIT_ROLE_SCOPE_CONTAINER_OUT)
endif

ifneq ($(filter 1 true TRUE yes YES,$(STRICT)),)
AUDIT_ROLE_SCOPE_ARGS += --strict
endif

audit-role-scope:
	docker compose -f docker/docker-compose.dev.yml exec -T backend sh -lc 'cd /app/backend && npx ts-node -r tsconfig-paths/register src/scripts/roleScopeAudit.ts $(AUDIT_ROLE_SCOPE_ARGS)'
ifneq ($(strip $(OUT)),)
	mkdir -p "$(dir $(OUT))"
	docker compose -f docker/docker-compose.dev.yml exec -T backend cat $(AUDIT_ROLE_SCOPE_CONTAINER_OUT) > "$(OUT)"
	@echo "Trace copied to $(OUT)"
endif
