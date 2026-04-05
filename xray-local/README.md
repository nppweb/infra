# xray-local

Локальная папка для приватного конфига `xray-proxy`.

Что здесь лежит:

- `config.example.json` — шаблон без рабочих секретов;
- `config.json` — ваш реальный локальный конфиг, не коммитится.

Для локального запуска:

```bash
cp xray-local/config.example.json xray-local/config.json
```

После этого заполните `address`, `id`, `publicKey` и `shortId` своими значениями.
