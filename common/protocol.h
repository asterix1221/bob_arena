// protocol.h
// Спецификация UDP-протокола для сквозного проекта (файтинг в духе
// Smash Bros / Brawlhalla, будущая реализация на Godot/GDScript).
// Здесь заданы только структуры пакетов для тестового UDP-обмена
// (C++ консольные сервер/клиент). Значения enum PacketType специально
// расширены под механики из mechanics.md, чтобы протокол не пришлось
// переделывать, когда дойдём до боевой системы.

#pragma once
#include <cstdint>
#include <cstddef>

// enum намеренно вынесен ЗА пределы pack-блоков ниже: он сам по себе не
// участвует в побайтовой сетевой раскладке (в PacketHeader хранится как
// обычный uint8_t), и не должен мешать компилятору/анализатору отслеживать
// границы #pragma pack.
enum class PacketType : uint8_t {
    MOVEMENT      = 1,  // координаты игрока (обязательное по заданию)
    SHOOT         = 2,  // выстрел/дальняя атака (обязательное по заданию)
    ATTACK_LIGHT  = 3,  // ЛКМ — лёгкий удар (mechanics.md, п.4)
    ATTACK_HEAVY  = 4,  // ПКМ — тяжёлый удар (mechanics.md, п.4)
    SHIELD        = 5,  // активация щита (mechanics.md, п.7)
    RUNE_PICKUP   = 6,  // подбор руны (mechanics.md, п.5)
    WEAPON_PICKUP = 7,  // подбор упавшего оружия (mechanics.md, п.6)
    STATE_UPDATE  = 8,  // сервер -> клиент: авторитетное состояние
    ACK           = 9,  // подтверждение приёма без данных
    AUTH_REQUEST  = 10, // логин/пароль (доп. задание)
    AUTH_RESPONSE = 11  // результат авторизации (доп. задание)
};

// ---- Структуры сетевых пакетов ----
// Каждая структура упакована в СВОЁМ отдельном push/pop-блоке (а не одним
// общим на весь файл): так границы pack(push)/pack(pop) остаются короткими
// и однозначными для любого компилятора/анализатора, и исключается ситуация,
// когда между push и pop случайно оказывается лишний код.

// Общий заголовок пакета. Присутствует у ЛЮБОГО пакета протокола.
#pragma pack(push, 1)
struct PacketHeader {
    uint8_t  packetType;      // см. PacketType
    uint16_t sequenceNumber;  // порядковый номер пакета отправителя
    uint16_t payloadSize;     // размер данных ПОСЛЕ заголовка, в байтах
    uint32_t checksum;        // CRC32 от payload (доп. задание)
};
#pragma pack(pop)

#pragma pack(push, 1)
struct MovementPayload {
    float x;
    float y;
    float z;
};
#pragma pack(pop)

#pragma pack(push, 1)
struct ShootPayload {
    uint8_t weaponId;
};
#pragma pack(pop)

#pragma pack(push, 1)
struct AttackPayload {
    uint8_t attackType; // 0 = light, 1 = heavy (дублирует PacketType для наглядности лога)
};
#pragma pack(pop)

#pragma pack(push, 1)
struct AuthPayload {
    char login[32];
    char password[32];
};
#pragma pack(pop)

// Ответ сервера на AUTH_REQUEST
#pragma pack(push, 1)
struct AuthResponsePayload {
    uint8_t success; // 1 — успех, 0 — отказ
};
#pragma pack(pop)

// Авторитетное состояние игрока, которое сервер рассылает в ответ
// на MOVEMENT/ATTACK-пакеты.
#pragma pack(push, 1)
struct StateUpdatePayload {
    uint32_t playerId;
    float x;
    float y;
    float z;
    uint16_t health;
};
#pragma pack(pop)

// CRC32 (стандартный полиномиальный алгоритм, таблица считается лениво
// при первом вызове). Используется для поля checksum в PacketHeader.
uint32_t crc32(const uint8_t* data, size_t length);
