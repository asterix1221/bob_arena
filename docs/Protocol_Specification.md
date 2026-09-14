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
