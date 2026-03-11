.PHONY: up down logs ps up-all down-all logs-all ps-all

up:
	cp -n .env.example .env || true
	docker compose --env-file .env up -d

down:
	docker compose --env-file .env down

logs:
	docker compose --env-file .env logs -f

ps:
	docker compose --env-file .env ps

up-all:
	cp -n .env.example .env || true
	docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml up -d --build

down-all:
	cp -n .env.example .env || true
	docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml down

logs-all:
	cp -n .env.example .env || true
	docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml logs -f

ps-all:
	cp -n .env.example .env || true
	docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml ps
