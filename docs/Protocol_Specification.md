# Protocol Specification

Формат пакета: `[PacketHeader][Payload]`. Все структуры упакованы
(`#pragma pack(push, 1)`), выравнивание отключено — байтовый layout
одинаков на отправителе и получателе.

## Заголовок пакета — `PacketHeader` (9 байт)

| Поле | Тип | Смещение | Описание |
|---|---|---|---|
| `packetType` | `uint8_t` | 0 | Тип пакета, см. таблицу `PacketType` ниже |
| `sequenceNumber` | `uint16_t` | 1 | Порядковый номер пакета отправителя (для лога/будущего upordering) |
| `payloadSize` | `uint16_t` | 3 | Размер данных после заголовка, в байтах |
| `checksum` | `uint32_t` | 5 | CRC32 от payload (полином 0xEDB88320), проверка целостности |

## Типы пакетов — `PacketType`

| Значение | Имя | Направление | Payload |
|---|---|---|---|
| 1 | `MOVEMENT` | клиент → сервер | `MovementPayload` |
| 2 | `SHOOT` | клиент → сервер | `ShootPayload` |
| 3 | `ATTACK_LIGHT` | клиент → сервер | `AttackPayload` |
| 4 | `ATTACK_HEAVY` | клиент → сервер | `AttackPayload` |
| 5 | `SHIELD` | клиент → сервер | нет данных |
| 6 | `RUNE_PICKUP` | клиент → сервер | зарезервировано (не реализовано в пр.1) |
| 7 | `WEAPON_PICKUP` | клиент → сервер | зарезервировано (не реализовано в пр.1) |
| 8 | `STATE_UPDATE` | сервер → клиент | `StateUpdatePayload` |
| 9 | `ACK` | сервер → клиент | нет данных |
| 10 | `AUTH_REQUEST` | клиент → сервер | `AuthPayload` |
| 11 | `AUTH_RESPONSE` | сервер → клиент | `AuthResponsePayload` |

Пакеты 3–7 определены в протоколе на будущее (см. `Architecture_Design.md`,
раздел 5); в текущей практической работе реализована обработка только
`MOVEMENT`, `SHOOT`, `ATTACK_LIGHT/HEAVY` (базовый ACK), `AUTH_REQUEST`.

## Структуры payload

```cpp
struct MovementPayload {      // 12 байт
    float x;
    float y;
    float z;
};

struct ShootPayload {         // 1 байт
    uint8_t weaponId;
};

struct AttackPayload {        // 1 байт
    uint8_t attackType;       // 0 = light, 1 = heavy
};

struct AuthPayload {          // 64 байта
    char login[32];
    char password[32];
};

struct AuthResponsePayload {  // 1 байт
    uint8_t success;          // 1 — успех, 0 — отказ
};

struct StateUpdatePayload {   // 18 байт
    uint32_t playerId;
    float x, y, z;
    uint16_t health;
};
```

## Обработка ошибок на сервере

- Пакет короче `sizeof(PacketHeader)` — отбрасывается молча (защита от мусора).
- `payloadSize` в заголовке больше фактически принятых данных — отбрасывается,
  пишется в лог.
- CRC32 от полученного payload не совпадает с полем `checksum` — пакет
  считается повреждённым и отбрасывается, пишется в лог.
- `MOVEMENT` / `SHOOT` / `ATTACK_*` от неавторизованного клиента (не прошёл
  `AUTH_REQUEST`) — отклоняется, пишется в лог.
- Координаты в `MOVEMENT`, выходящие за границы арены
  (X: [-50, 50], Y: [0, 50], Z: [-50, 50]) — обрезаются сервером
  до границы, авторитетная позиция уходит клиенту в `STATE_UPDATE`.

## Пример обмена (движение)

```
Клиент → Сервер:  [MOVEMENT, seq=1, size=12, crc] { x=1.5, y=0, z=0 }
Сервер → Клиент:  [STATE_UPDATE, seq=1, size=18, crc] { playerId=1, x=1.5, y=0, z=0, health=100 }
```

## Авторизация (доп. задание)

Список допустимых пар логин/пароль зашит в `server.cpp` (для практической
работы — в продакшене должен браться из защищённого хранилища, не из
исходного кода):

```
player1 / pass1
player2 / pass2
```

Клиент обязан успешно пройти `AUTH_REQUEST` до отправки игровых команд —
иначе сервер их отклоняет (см. «Обработка ошибок»).

## Приложение: протокол телеметрии PING/PONG (ПР №2)

Отдельный, НЕсовместимый с описанным выше протокол — своя пара
клиент/сервер (`client/ping_client.cpp` / `server/pong_server.cpp`),
свой порт по умолчанию (`27016` вместо `27015`), модули
`protocol/protocol.{h,cpp}`, `telemetry/telemetry.{h,cpp}`,
`telemetry/transport.{h,cpp}`. Причины изолировать, а не расширить
протокол выше, подробно разобраны в комментарии к
`protocol/protocol.h`; кратко: другой состав заголовка (нет `checksum`,
есть `protocolVersion`), другая (явная, не побайтовая) сериализация, и
явное указание задания рассматривать телеметрию как "изолированную
подсистему" до её интеграции с ACK/тайм-аутами/повторной передачей в ПР №3.

### Заголовок — 7 байт, сетевой порядок байт (big-endian)

| Поле | Тип | Смещение | Описание |
|---|---|---|---|
| `packetType` | `uint8_t` | 0 | `1` = PING, `2` = PONG |
| `sequenceNumber` | `uint16_t` | 1 | Идентификатор измерения |
| `payloadSize` | `uint16_t` | 3 | Размер payload в байтах (без заголовка) |
| `protocolVersion` | `uint16_t` | 5 | Версия формата (`kProtocolVersion = 1`) |

### PING — клиент → сервер, 15 байт всего

| Поле | Тип | Описание |
|---|---|---|
| `clientSendTimeUs` | `uint64_t` | Метка отправки по монотонным часам клиента (мкс) |

### PONG — сервер → клиент, 31 байт всего

| Поле | Тип | Описание |
|---|---|---|
| `clientSendTimeUs` | `uint64_t` | Эхо исходной метки клиента из PING (для RTT) |
| `serverReceiveTimeUs` | `uint64_t` | Метка приёма на сервере (только диагностика) |
| `serverSendTimeUs` | `uint64_t` | Метка отправки ответа сервером (только диагностика) |

Часы клиента и сервера НЕ синхронизированы: `RTT` считается исключительно
как `t_receive_client − t_send_client` по часам клиента; серверные метки
используются только чтобы прикинуть время обработки на сервере при
разборе логов, не участвуют в расчёте RTT/SRTT.

### Валидация на приёме (обе стороны, `telemetry::ReadHeader`/`ParsePing`/`ParsePong`)

- Датаграмма короче 7 байт (заголовок) — отбрасывается.
- `packetType` не входит в `{1, 2}` — отбрасывается.
- `protocolVersion` ≠ `kProtocolVersion` — отбрасывается.
- `payloadSize` из заголовка не совпадает с ожидаемым размером payload
  для данного `packetType` (8 для PING, 24 для PONG) — отбрасывается.
- Фактическая длина датаграммы ≠ `заголовок + payloadSize` (лишний "хвост"
  или недостача байт) — отбрасывается.

Ни один из этих случаев не приводит к падению процесса — сервер/клиент
пишут строку в лог и переходят к следующему пакету (см.
`server/pong_server.cpp`, `client/ping_client.cpp`).

### Статусы ответа (`telemetry::ResponseStatus`)

| Статус | CSV-значение | Когда присваивается |
|---|---|---|
| `Received` | `received` | PONG пришёл в пределах тайм-аута (1000 мс по умолчанию) |
| `Timeout` | `timeout` | PONG не пришёл за время тайм-аута |
| `LateResponse` | `late_response` | PONG пришёл, но позже тайм-аута |
| `DuplicateResponse` | `duplicate_response` | Повторный PONG на уже завершённое измерение |
| `UnknownResponse` | `unknown_response` | PONG с `sequenceNumber`, которого нет среди отправленных |

Подробности формул RTT/SRTT/джиттера/Loss Rate и результаты реального
эксперимента — см. `docs/Latency_Report.md` и `docs/Experiment_Config.md`.
