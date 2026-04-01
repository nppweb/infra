# deployment-infra

Инфраструктурный репозиторий для надежного локального запуска платформы через Docker Compose.

## Что поднимается локально

- `postgres`
- `redis`
- `rabbitmq`
- `minio`
- `minio-init` для автосоздания bucket
- `backend-api`
- `processing-worker`
- `scraper-service`
- `frontend` c nginx внутри контейнера

Все сервисы работают в одной сети `platform-net` и обращаются друг к другу по service name.

## Обязательные env-переменные

Минимально для локалки должны быть заданы:

- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `DATABASE_URL`
- `REDIS_URL`
- `RABBITMQ_URL`
- `MINIO_ROOT_USER`
- `MINIO_ROOT_PASSWORD`
- `S3_ENDPOINT`
- `S3_ACCESS_KEY`
- `S3_SECRET_KEY`
- `S3_BUCKET`
- `INGEST_API_TOKEN`
- `API_INGEST_TOKEN`
- `ADMIN_EMAIL`
- `ADMIN_PASSWORD`
- `ENABLED_SOURCES`

Рабочий шаблон уже лежит в [.env.example](/home/minkin/vkrdiff/deployment-infra/.env.example). Для локального bootstrap `INGEST_API_TOKEN` и `API_INGEST_TOKEN` должны совпадать.

## Локальный запуск

1. Создай локальный env:

```bash
cp .env.example .env
```

2. Подними весь стек одной командой:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml up -d --build
```

Альтернатива через `make`:

```bash
make up
```

## Куда открыть браузер

- Frontend: `http://localhost:8080`
- GraphQL через nginx frontend: `http://localhost:8080/graphql`
- Backend health: `http://localhost:3000/api/health`
- RabbitMQ management: `http://localhost:15672`
- MinIO console: `http://localhost:9001`

## Логин для локалки

По умолчанию:

- email: `admin@admin.ru`
- password: `admin`

`backend-api` на старте прогоняет Prisma migrations и seed, поэтому demo admin и стартовые данные создаются автоматически.

## Проверка, что все работает

Проверь состояние контейнеров:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml ps
```

Ожидаемо:

- `postgres`, `rabbitmq`, `minio`, `backend-api`, `frontend` имеют статус `healthy`
- `minio-init` завершился со статусом `Exited (0)`
- `processing-worker` и `scraper-service` находятся в `Up`

Проверь backend health:

```bash
curl http://localhost:3000/api/health
curl http://localhost:3000/api/health/ready
```

Проверь GraphQL через frontend nginx:

```bash
curl http://localhost:8080/graphql \
  -H 'content-type: application/json' \
  --data '{"query":"query { health }"}'
```

Проверь, что frontend открывается:

```bash
curl -I http://localhost:8080
```

Проверь связность backend, worker и scraper:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml logs backend-api processing-worker scraper-service
```

Ожидаемо:

- `backend-api` поднялся после миграций и отвечает на `/api/health/ready`
- `processing-worker` пишет `processing-worker started`
- `scraper-service` пишет `scraper-service starting`
- в MinIO существует bucket `artifacts` или значение из `S3_BUCKET`

## Полезные команды

Поднять стек:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml up -d --build
```

Остановить и удалить volumes:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml down -v --remove-orphans
```

Смотреть логи:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml logs -f
```

Смотреть логи одного сервиса:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml logs -f backend-api
```

Перезапустить конкретный сервис:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml restart processing-worker
```

## Сбросить данные и поднять заново

1. Останови стек и удали volumes:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml down -v --remove-orphans
```

2. Подними заново:

```bash
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml up -d --build
```

## Что отвечает за устойчивый старт

- `postgres`, `rabbitmq`, `minio`, `backend-api` имеют реальные healthcheck'и
- `minio-init` создает bucket до старта `scraper-service`
- `backend-api` ждёт Postgres и запускает migrations/seed перед стартом приложения
- `processing-worker` ждёт `rabbitmq` и `backend-api`
- `scraper-service` ждёт `rabbitmq`, `minio` и `minio-init`
