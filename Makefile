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
        docker compose -f docker/docker-compose.dev.yml exec backend sh -c "npx prisma migrate reset --force && npx prisma db push && npm run seed:dev"

dev.db.generate:
	docker compose -f docker/docker-compose.dev.yml exec backend npx prisma generate


