# infra

Docker Compose инфраструктура для локального запуска NPPWEB.

## Что поднимается

- `postgres`
- `redis`
- `rabbitmq`
- `minio`
- `minio-init`
- `backend-api`
- `processing-worker`
- `scraper-service`
- `frontend`

Все сервисы работают в сети `platform-net` и обращаются друг к другу по service name.

## Быстрый старт

```bash
cp .env.example .env
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml up -d --build
```

Альтернатива:

```bash
make up
```

## Куда открыть браузер

- frontend: `http://localhost:8080`
- GraphQL backend: `http://localhost:3000/graphql`
- backend health: `http://localhost:3000/api/health`
- RabbitMQ management: `http://localhost:15672`
- MinIO console: `http://localhost:9001`

## Локальные учётные данные

После старта `backend-api` автоматически прогоняет миграции и seed.

- `admin@admin.ru / 12345678`
- `analyst@admin.ru / 12345678`
- `user@admin.ru / 12345678`

## Проверка состояния

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml ps
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml logs backend-api processing-worker scraper-service frontend
```

Ожидаемо:

- `postgres`, `rabbitmq`, `minio`, `backend-api`, `frontend` имеют статус `healthy`;
- `minio-init` завершился со статусом `Exited (0)`;
- `processing-worker` и `scraper-service` находятся в `Up`.

Проверки вручную:

```bash
curl http://localhost:3000/api/health
curl http://localhost:3000/api/health/ready
curl -I http://localhost:8080
```

## Полезные команды

Поднять весь стек:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml up -d --build
```

Пересобрать только frontend:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml up -d --build frontend
```

Остановить стек и удалить volumes:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml down -v --remove-orphans
```

Смотреть логи:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml logs -f
```

## Что обеспечивает устойчивый старт

- `postgres`, `rabbitmq`, `minio`, `backend-api` имеют healthcheck'и;
- `minio-init` создаёт bucket до старта `scraper-service`;
- `backend-api` ждёт Postgres и запускает migrations/seed перед стартом;
- `processing-worker` ждёт `rabbitmq` и `backend-api`;
- `scraper-service` ждёт `rabbitmq`, `minio` и `minio-init`.
