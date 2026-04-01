.PHONY: up down logs ps restart up-infra down-infra logs-infra ps-infra

COMPOSE_LOCAL=docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml
COMPOSE_INFRA=docker compose --env-file .env -f docker-compose.yml

up:
	cp -n .env.example .env || true
	$(COMPOSE_LOCAL) up -d --build

down:
	cp -n .env.example .env || true
	$(COMPOSE_LOCAL) down -v --remove-orphans

logs:
	cp -n .env.example .env || true
	$(COMPOSE_LOCAL) logs -f

ps:
	cp -n .env.example .env || true
	$(COMPOSE_LOCAL) ps

restart:
	cp -n .env.example .env || true
	$(COMPOSE_LOCAL) restart $(SERVICE)

up-infra:
	cp -n .env.example .env || true
	$(COMPOSE_INFRA) up -d

down-infra:
	cp -n .env.example .env || true
	$(COMPOSE_INFRA) down -v --remove-orphans

logs-infra:
	cp -n .env.example .env || true
	$(COMPOSE_INFRA) logs -f

ps-infra:
	cp -n .env.example .env || true
	$(COMPOSE_INFRA) ps
