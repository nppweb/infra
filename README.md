# infra

Docker Compose инфраструктура для локального запуска и production deploy проекта NPPWEB.

## Что поднимается

- `postgres`
- `redis`
- `rabbitmq`
- `minio`
- `minio-init`
- `backend-api`
- `processing-worker`
- `scraper-service`
- `xray-proxy` (если настроен локальный proxy-конфиг)
- `frontend`

Все сервисы работают в сети `platform-net` и обращаются друг к другу по service name.

## Локальный запуск

Быстрый вариант через общий стек:

```bash
cp .env.example .env
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml up -d --build
```

Альтернатива:

```bash
make up
```

Если для государственных площадок нужен proxy-маршрут, создайте локальный файл:

```bash
cp xray-local/config.example.json xray-local/config.json
```

и заполните его приватными параметрами. Этот файл не коммитится.

Для deploy-контура логика такая же: на сервере должен существовать файл `xray-local/config.json`. Чтобы compose поднял `xray-proxy` автоматически, добавьте в deploy `.env` значение `COMPOSE_PROFILES=proxy` и задайте `HTTP_PROXY/HTTPS_PROXY=http://xray-proxy:8080`.

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

- `postgres`, `rabbitmq`, `minio`, `backend-api`, `frontend` имеют статус `healthy`
- `minio-init` завершился со статусом `Exited (0)`
- `processing-worker` и `scraper-service` находятся в `Up`

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

- `postgres`, `rabbitmq`, `minio`, `backend-api` имеют healthcheck'и
- `minio-init` создаёт bucket до старта `scraper-service`
- `backend-api` ждёт Postgres и запускает migrations/seed перед стартом
- `processing-worker` ждёт `rabbitmq` и `backend-api`
- `scraper-service` ждёт `rabbitmq`, `minio` и `minio-init`
- `scraper-service` может идти наружу через `xray-proxy`, если в `.env` заданы `HTTP_PROXY/HTTPS_PROXY`

## Production Auto-Deploy

### Выбранная архитектура

Выбран прагматичный вариант без Kubernetes и без внешней DevOps-платформы:

- единый reusable workflow живёт в `infra`
- `npp-web`, `npp-backend`, `processing-worker`, `scrape-helper` и `contracts` имеют тонкие workflows-обёртки
- каждый такой workflow при `push` в `main` или `master` вызывает reusable workflow из `infra`
- reusable workflow по SSH заходит на production VPS под пользователем `deploy`
- на сервере запускается [`scripts/deploy.sh`](/home/minkin/vkrdiff/infra/scripts/deploy.sh), который:
  - берёт глобальный lock через `flock`
  - проверяет директории и git-репозитории
  - печатает commit hash до и после обновления
  - делает `git fetch` и `git pull --ff-only`
  - запускает `docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml up -d --build`
  - ждёт health checks и HTTP checks
  - на провале автоматически откатывает изменённые репозитории назад и повторно поднимает стек
- успешный деплой сохраняет release snapshot в `/home/deploy/.deploy-state/releases/*.env`
- ручной откат выполняется через [`scripts/rollback.sh`](/home/minkin/vkrdiff/infra/scripts/rollback.sh)

Почему так:

- логика деплоя сосредоточена в одном месте
- нет `repository_dispatch` и отдельного PAT
- сервер остаётся source-of-truth для production checkout'ов
- решение нормально работает на обычном VPS с уже существующим Docker и nginx

### Как триггерится деплой из нескольких репозиториев

- push в `infra/master` запускает [`infra/.github/workflows/deploy.yml`](/home/minkin/vkrdiff/infra/.github/workflows/deploy.yml) напрямую и делает full-stack deploy
- push в `npp-web/main` запускает [`npp-web/.github/workflows/production-deploy.yml`](/home/minkin/vkrdiff/npp-web/.github/workflows/production-deploy.yml), который вызывает reusable workflow из `infra` и пересобирает только `frontend`
- push в `npp-backend/main` запускает [`npp-backend/.github/workflows/production-deploy.yml`](/home/minkin/vkrdiff/npp-backend/.github/workflows/production-deploy.yml), который пересобирает `backend-api`
- push в `processing-worker/master` пересобирает только `processing-worker`
- push в `scrape-helper/master` пересобирает только `scraper-service`
- push в `contracts/master` обновляет `contracts` и пересобирает `processing-worker` и `scraper-service`

Таким образом:

- приложение деплоится из нескольких отдельных репозиториев
- compose всё равно исполняется только на сервере из `infra`
- `infra` repo на сервере тоже обновляется перед deploy по своей основной ветке `master`, чтобы compose и скрипты не расходились с production checkout

### Minimal Downtime

Полного zero-downtime с одиночным VPS и обычным `docker compose` тут нет: контейнер сервиса всё равно пересоздаётся. Но downtime сводится к минимуму:

- образ собирается перед финальной заменой контейнера
- при изменении `npp-web` пересобирается только `frontend`
- при изменении `npp-backend` пересобирается только `backend-api`
- full-stack rebuild выполняется только для `infra`
- после перезапуска скрипт ждёт health checks и HTTP checks

### Rollback Strategy

Есть два уровня rollback:

- автоматический rollback в `deploy.sh`, если `git pull`, `docker compose up`, container health или HTTP health провалились
- ручной rollback на предыдущий успешный release через `rollback.sh`

Release snapshots лежат в:

```text
/home/deploy/.deploy-state/releases/
```

Каждый snapshot хранит commit SHA всех production repo на момент успешного deploy.

## Какие файлы добавлены или изменены

### Infra

- [`infra/.github/workflows/deploy.yml`](/home/minkin/vkrdiff/infra/.github/workflows/deploy.yml)
- [`infra/scripts/deploy.sh`](/home/minkin/vkrdiff/infra/scripts/deploy.sh)
- [`infra/scripts/rollback.sh`](/home/minkin/vkrdiff/infra/scripts/rollback.sh)
- [`infra/README.md`](/home/minkin/vkrdiff/infra/README.md)

### App Repos

- [`npp-web/.github/workflows/production-deploy.yml`](/home/minkin/vkrdiff/npp-web/.github/workflows/production-deploy.yml)
- [`npp-backend/.github/workflows/production-deploy.yml`](/home/minkin/vkrdiff/npp-backend/.github/workflows/production-deploy.yml)
- [`processing-worker/.github/workflows/production-deploy.yml`](/home/minkin/vkrdiff/processing-worker/.github/workflows/production-deploy.yml)
- [`scrape-helper/.github/workflows/production-deploy.yml`](/home/minkin/vkrdiff/scrape-helper/.github/workflows/production-deploy.yml)
- [`contracts/.github/workflows/production-deploy.yml`](/home/minkin/vkrdiff/contracts/.github/workflows/production-deploy.yml)

## GitHub Secrets

Рекомендуемый вариант: завести secrets на уровне GitHub Organization `nppweb` и открыть их для нужных репозиториев. Тогда `secrets: inherit` будет работать без дублирования.

Обязательные secrets:

- `SSH_HOST` - hostname или IP production VPS
- `SSH_USER` - `deploy`
- `SSH_PRIVATE_KEY` - приватный deploy key для GitHub Actions

Рекомендуемые secrets:

- `SSH_PORT` - если не `22`
- `DEPLOY_PATH` - если production checkout живёт не в `/home/deploy`
- `SSH_KNOWN_HOSTS` - заранее сохранённый `known_hosts`; если не задан, workflow сам сделает `ssh-keyscan`

Если org secrets использовать нельзя, заведите те же secrets в каждом repo:

- `infra`
- `npp-web`
- `npp-backend`
- `processing-worker`
- `scrape-helper`
- `contracts`

## Команды для deploy SSH key

Сгенерировать отдельный ключ для GitHub Actions:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/nppweb-gha-deploy -C "github-actions@nppweb-production"
```

Положить приватный ключ в GitHub Secret `SSH_PRIVATE_KEY`:

```bash
cat ~/.ssh/nppweb-gha-deploy
```

Публичный ключ:

```bash
cat ~/.ssh/nppweb-gha-deploy.pub
```

## Как добавить публичный ключ на сервер

Под root или пользователем с sudo:

```bash
sudo install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
sudo touch /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys
```

Добавить ключ:

```bash
cat ~/.ssh/nppweb-gha-deploy.pub | ssh deploy@YOUR_SERVER "cat >> ~/.ssh/authorized_keys"
```

Проверить вход:

```bash
ssh -i ~/.ssh/nppweb-gha-deploy deploy@YOUR_SERVER
```

## Пример `known_hosts`

Снять host key и сохранить в secret `SSH_KNOWN_HOSTS`:

```bash
ssh-keyscan -H nppweb.minkin.tech
```

Если SSH идёт на нестандартный порт:

```bash
ssh-keyscan -p 2222 -H nppweb.minkin.tech
```

Пример значения для secret:

```text
nppweb.minkin.tech ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...
```

## Первичная настройка сервера

### 1. Убедиться, что у `deploy` есть доступ к Docker

```bash
sudo usermod -aG docker deploy
```

После этого нужно перелогиниться под `deploy`.

### 2. Поставить базовые зависимости

На VPS нужны:

- `git`
- `docker`
- `docker compose` plugin
- `curl`
- `flock` из `util-linux`

### 3. Подготовить рабочую директорию

```bash
sudo mkdir -p /home/deploy
sudo chown deploy:deploy /home/deploy
```

### 4. Склонировать репозитории

Под пользователем `deploy`:

```bash
cd /home/deploy
git clone git@github.com:nppweb/infra.git
git clone git@github.com:nppweb/npp-web.git
git clone git@github.com:nppweb/npp-backend.git
git clone git@github.com:nppweb/processing-worker.git
git clone git@github.com:nppweb/scrape-helper.git
git clone git@github.com:nppweb/contracts.git
```

Если какие-то repo реально не используются в production, их можно не клонировать и убрать соответствующий workflow.

### 5. Сделать deploy scripts исполняемыми

```bash
chmod +x /home/deploy/infra/scripts/deploy.sh
chmod +x /home/deploy/infra/scripts/rollback.sh
```

### 6. Подготовить production `.env`

```bash
cd /home/deploy/infra
cp .env.example .env
```

Минимально проверьте и поправьте:

```dotenv
CORS_ALLOWED_ORIGINS=http://localhost:8080,http://nppweb.minkin.tech
NUXT_PUBLIC_GRAPHQL_ENDPOINT=/graphql
BACKEND_PORT=3000
FRONTEND_PORT=8080
```

Остальные production secrets должны лежать только в `/home/deploy/infra/.env`, а не в git.

### 7. Если нужен proxy для scraper

```bash
cp /home/deploy/infra/xray-local/config.example.json /home/deploy/infra/xray-local/config.json
```

Заполните приватные параметры и при необходимости добавьте в `.env`:

```dotenv
COMPOSE_PROFILES=proxy
HTTP_PROXY=http://xray-proxy:8080
HTTPS_PROXY=http://xray-proxy:8080
```

### 8. Выполнить первый ручной deploy

```bash
cd /home/deploy/infra
./scripts/deploy.sh --repo infra
```

Это проверит, что сервер готов ещё до первого GitHub Actions запуска.

## Пошаговый запуск

1. Добавьте workflows из этого README в соответствующие repo.
2. Добавьте GitHub secrets.
3. Подготовьте сервер по шагам выше.
4. Выполните первый ручной deploy на сервере: `./scripts/deploy.sh --repo infra`.
5. Сделайте тестовый push в `main` одного из repo.
6. Убедитесь, что workflow дошёл до SSH-этапа и завершился успешно.

## Как проверить, что автодеплой работает

### Через GitHub Actions

- в `npp-web` запушьте тестовый commit в `main`
- откройте workflow `Production Deploy`
- убедитесь, что reusable workflow в `infra` отработал успешно

### На сервере

Проверить commit в целевом repo:

```bash
git -C /home/deploy/npp-web rev-parse HEAD
```

Проверить статус контейнеров:

```bash
cd /home/deploy/infra
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml ps
```

Проверить backend:

```bash
curl -f http://127.0.0.1:3000/api/health/ready
```

Проверить frontend:

```bash
curl -I http://127.0.0.1:8080
```

Проверить, что release snapshot сохранился:

```bash
ls -1 /home/deploy/.deploy-state/releases
cat /home/deploy/.deploy-state/last-success.env
```

## Как откатиться

### Быстрый откат на предыдущий successful release

```bash
cd /home/deploy/infra
./scripts/rollback.sh
```

### Посмотреть доступные release snapshots

```bash
cd /home/deploy/infra
./scripts/rollback.sh --list
```

### Откатиться на конкретный snapshot

```bash
cd /home/deploy/infra
./scripts/rollback.sh --release-file /home/deploy/.deploy-state/releases/20260408T120501Z.env
```

После отката скрипт:

- переводит все production repo на сохранённые commit SHA
- выполняет `docker compose up -d --build --remove-orphans`
- ждёт health checks
- обновляет `/home/deploy/.deploy-state/last-success.env`

## Типичные проблемы и как диагностировать

### SSH не подключается

Проверьте:

- правильность `SSH_HOST`, `SSH_PORT`, `SSH_USER`
- что `SSH_PRIVATE_KEY` соответствует ключу в `authorized_keys`
- что `SSH_KNOWN_HOSTS` не устарел

Диагностика:

```bash
ssh -i ~/.ssh/nppweb-gha-deploy -p 22 deploy@YOUR_SERVER
```

### Workflow падает на reusable workflow access

Проверьте настройки GitHub Actions в организации и в repo:

- reusable workflows из `nppweb/infra` должны быть разрешены
- caller repo должен видеть repo `infra`

### `deploy.sh` ругается на dirty worktree

На production checkout не должно быть ручных правок. Проверить:

```bash
git -C /home/deploy/npp-web status --short
```

Если на сервере есть ручные изменения, уберите их и повторите deploy.

### Падает `docker compose config -q`

Обычно это:

- синтаксическая ошибка в compose
- отсутствует нужный repo рядом с `infra`
- отсутствует `.env`

Проверка:

```bash
cd /home/deploy/infra
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml config
```

### Контейнер поднялся, но health check не проходит

Смотреть статус и логи:

```bash
cd /home/deploy/infra
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml ps
docker compose --env-file .env -f docker-compose.yml -f docker-compose.apps.yml logs --tail=100 backend-api frontend processing-worker scraper-service
```

### Проблема с frontend или CORS после deploy

Проверьте production `.env`:

```dotenv
CORS_ALLOWED_ORIGINS=http://localhost:8080,http://nppweb.minkin.tech
NUXT_PUBLIC_GRAPHQL_ENDPOINT=/graphql
```

Также проверьте nginx-маршрутизацию до:

- `http://127.0.0.1:8080` для frontend
- `http://127.0.0.1:3000/graphql` и `http://127.0.0.1:3000/api/health/ready` для backend

### Два деплоя стартовали одновременно

Это штатно. `deploy.sh` использует глобальный lock:

```text
/home/deploy/.deploy-state/deploy.lock
```

Второй deploy завершится fail-fast с понятной ошибкой вместо гонки между `git pull` и `docker compose`.
