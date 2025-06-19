# 🔧 Développement

dev.start:
	docker compose -f docker/docker-compose.dev.yml up --build

dev.stop:
	docker compose -f docker/docker-compose.dev.yml down
