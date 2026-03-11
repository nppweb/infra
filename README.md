# deployment-infra

![CI](https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions&logoColor=white)
![CD](https://img.shields.io/badge/CD-GitHub_Deploy-2ea44f?logo=github&logoColor=white)
![IaC](https://img.shields.io/badge/IaC-Docker_Compose-1d63ed?logo=docker&logoColor=white)

Инфраструктурный репозиторий для локального запуска и деплоя через GitHub.

## Что делает этот репозиторий

- поднимает инфраструктуру платформы (PostgreSQL, Redis, RabbitMQ, MinIO);
- содержит compose-описание чернового запуска всех приложений;
- фиксирует единые network/DNS-имена для межсервисного взаимодействия.

## Черновая реализация

- `docker-compose.yml` - инфраструктурные сервисы;
- `docker-compose.apps.yml` - запуск `backend-api`, `scraper-service`, `processing-worker`, `frontend-app`;
- `Makefile` с командами `up`, `down`, `up-all`, `down-all`;
- CI workflow с валидацией compose-конфигураций.

## Локальный запуск

Только инфраструктура:

```bash
cp .env.example .env
make up
```

Инфраструктура + приложения:

```bash
cp .env.example .env
make up-all
```

Остановка полного стека:

```bash
make down-all
```

## Сеть и адреса

- сеть: `platform-net`
- `postgres:5432`
- `redis:6379`
- `rabbitmq:5672` (`15672` management)
- `minio:9000` (`9001` console)
- `backend-api:3000`
- `frontend-app:80` (внешний порт `8080`)
