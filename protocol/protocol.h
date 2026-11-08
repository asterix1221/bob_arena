// protocol/protocol.h
//
// Контракт протокола телеметрии (ПР №2): изолированная подсистема,
// НЕ переиспользующая PacketHeader/enum PacketType из common/protocol.h.
//
// Почему отдельный протокол, а не расширение common/protocol.h:
//  1) Задание прямо называет телеметрию "изолированной подсистемой",
//     которую предстоит интегрировать с ACK/тайм-аутами/повторной
//     передачей только в ПР №3 — до этого её удобнее развивать и
//     тестировать независимо от игрового протокола ПР №1.
//  2) Формат заголовка отличается по составу полей: здесь вместо
//     checksum (CRC32) требуется protocolVersion, а сам заголовок
//     на 2 байта короче (7 байт вместо 9). Заголовки БИТОВО несовместимы,
//     поэтому размещать оба формата под одним PacketType было бы ошибкой
//     (PacketType::MOVEMENT == 1 в ПР №1 совпал бы с PacketType::PING == 1
//     из примера в задании, что привело бы к неоднозначному разбору).
//  3) common/protocol.h сериализует структуры побайтовым memcpy (что для
//     сети зависит от платформы/выравнивания и запрещено явно в задании
//     ПР №2) — здесь вместо этого используются явные WriteU16/WriteU64/
//     ReadU16/ReadU64 в сетевом порядке байт (big-endian).
//
// ПР №3 расширяет ЭТОТ ЖЕ модуль (тот же контракт, версия 2): добавлены тип
// ACK, поле заголовка requiresAck и команды MOVEMENT/SHOOT — надёжная доставка
// строится поверх модулей protocol и telemetry, а не рядом с ними.
// Историческая справка ниже относится к ПР №2 (тогда заголовок был 7 байт).
//
// Итог: телеметрия слушает СВОИ порт/сокет (см. transport.h, отдельные
// исполняемые файлы ping_client_app / pong_server_app), не пересекаясь
// по проводам с MOVEMENT/SHOOT/AUTH_* из ПР №1.

#pragma once

#include <cstdint>
#include <cstddef>
#include <vector>
#include <optional>

namespace telemetry {

// Версия формата пакетов. Меняется при несовместимом изменении контракта
// (см. ReadHeader: пакет с другой версией отбрасывается).
//   1 — ПР №2: заголовок 7 байт, только PING/PONG.
//   2 — ПР №3: в заголовок добавлено поле requiresAck (заголовок 8 байт),
//       добавлены типы MOVEMENT / SHOOT / ACK.
constexpr std::uint16_t kProtocolVersion = 2;

enum class PacketType : std::uint8_t {
    Ping     = 1,
    Pong     = 2,
    Movement = 3, // ПР №3: позиция игрока, ненадёжная (requiresAck = 0)
    Shoot    = 4, // ПР №3: выстрел, надёжная команда (requiresAck = 1)
    Ack      = 5, // ПР №3: подтверждение доставки надёжного пакета
    // ---- Игровые типы (этап доработки игры на Godot; заголовок и версия формата НЕ менялись) ----
    Hello     = 6,  // клиент -> сервер, надёжный: имя, цвет, версия игрового протокола
    Welcome   = 7,  // сервер -> клиент, надёжный: результат входа, id игрока, параметры матча
    Input     = 8,  // клиент -> сервер, ненадёжный: последние N команд ввода (избыточно)
    Snapshot  = 9,  // сервер -> клиент, ненадёжный: полное состояние мира
    GameEvent = 10, // сервер -> клиент, надёжный: попадание, подбор руны, смерть, начало/конец раунда
    Leave     = 11, // любая сторона, надёжный: выход из игры
    Roster    = 12, // хост -> клиенты, надёжный: список игроков лобби (id, цвет, имя)
};

// Общий заголовок пакета (8 байт "на проводе"):
//   packetType      uint8_t   — PacketType::*
//   sequenceNumber  uint16_t  — номер пакета в потоке отправителя
//   payloadSize     uint16_t  — размер payload в байтах (без заголовка)
//   protocolVersion uint16_t  — версия формата пакета
//   requiresAck     uint8_t   — 1: получатель обязан подтвердить пакет ACK-ом,
//                               0: подтверждение не требуется (ПР №3)
// Новое поле добавлено В КОНЕЦ заголовка, поэтому смещения первых четырёх
// полей не изменились по сравнению с ПР №2.
// Это структура для УДОБСТВА ВЫЗЫВАЮЩЕГО КОДА, а не layout "на проводе":
// на проводе поля пишутся/читаются явными Write*/Read* ниже, без
// reinterpret_cast и без #pragma pack.
struct Header {
    PacketType packetType;
    std::uint16_t sequenceNumber;
    std::uint16_t payloadSize;
    std::uint16_t protocolVersion;
    bool requiresAck = false;
};

constexpr std::size_t kHeaderSize = 1 + 2 + 2 + 2 + 1; // 8 байт

// PING: клиент -> сервер. payload = clientSendTimeUs (8 байт).
struct PingPacket {
    std::uint16_t sequenceNumber;
    std::uint64_t clientSendTimeUs;
};
constexpr std::size_t kPingPayloadSize = 8;
constexpr std::size_t kPingPacketSize = kHeaderSize + kPingPayloadSize; // 16 байт

// PONG: сервер -> клиент. payload = исходная метка клиента +
// серверные метки приёма/отправки (диагностика; часы не синхронизированы,
// поэтому RTT считается ИСКЛЮЧИТЕЛЬНО по clientSendTimeUs, см. telemetry.h).
struct PongPacket {
    std::uint16_t sequenceNumber;
    std::uint64_t clientSendTimeUs;
    std::uint64_t serverReceiveTimeUs;
    std::uint64_t serverSendTimeUs;
};
constexpr std::size_t kPongPayloadSize = 8 + 8 + 8;
constexpr std::size_t kPongPacketSize = kHeaderSize + kPongPayloadSize; // 32 байта

// MOVEMENT: клиент -> сервер. payload = позиция игрока (x, y) в пикселях.
// В проекте это НЕнадёжная команда (requiresAck = 0): позиция шлётся часто, и
// потерянный пакет тут же перекрывается следующим, более свежим — повторная
// отправка устаревшей позиции только вредила бы (см. docs/Reliability_Protocol.md).
struct MovementPacket {
    std::uint16_t sequenceNumber;
    bool requiresAck;
    std::uint16_t x;
    std::uint16_t y;
};
constexpr std::size_t kMovementPayloadSize = 2 + 2;
constexpr std::size_t kMovementPacketSize = kHeaderSize + kMovementPayloadSize; // 12 байт

// SHOOT: клиент -> сервер. payload = угол прицеливания (градусы) + id оружия.
// Критичное событие — по умолчанию надёжная команда (requiresAck = 1).
struct ShootPacket {
    std::uint16_t sequenceNumber;
    bool requiresAck;
    std::uint16_t aimAngleDeg;
    std::uint8_t weaponId;
};
constexpr std::size_t kShootPayloadSize = 2 + 1;
constexpr std::size_t kShootPacketSize = kHeaderSize + kShootPayloadSize; // 11 байт

// ACK: подтверждение доставки надёжного пакета. Payload — только номер
// подтверждаемого пакета (struct AckPayload из задания). Сам ACK НЕ требует
// подтверждения: requiresAck у него всегда 0, а ParseAck отбрасывает ACK с
// requiresAck = 1 (иначе получилась бы бесконечная цепочка "ACK на ACK").
struct AckPayload {
    std::uint16_t acknowledgedSequence;
};
struct AckPacket {
    std::uint16_t sequenceNumber; // собственный номер ACK (сервер ставит тот же, что у подтверждаемого)
    AckPayload payload;
};
constexpr std::size_t kAckPayloadSize = 2;
constexpr std::size_t kAckPacketSize = kHeaderSize + kAckPayloadSize; // 10 байт

// ---- Явная (не побайтовая) сериализация примитивов, сетевой порядок ----

void WriteU8(std::vector<std::uint8_t>& out, std::uint8_t v);
void WriteU16(std::vector<std::uint8_t>& out, std::uint16_t v);
void WriteU64(std::vector<std::uint8_t>& out, std::uint64_t v);

// Каждая Read*-функция продвигает p и возвращает std::nullopt, если во
// входном буфере не осталось нужного числа байт (проверка границ ДО чтения).
std::optional<std::uint8_t>  ReadU8 (const std::uint8_t*& p, const std::uint8_t* end);
std::optional<std::uint16_t> ReadU16(const std::uint8_t*& p, const std::uint8_t* end);
std::optional<std::uint64_t> ReadU64(const std::uint8_t*& p, const std::uint8_t* end);

void WriteU32(std::vector<std::uint8_t>& out, std::uint32_t v);
void WriteI16(std::vector<std::uint8_t>& out, std::int16_t v);
std::optional<std::uint32_t> ReadU32(const std::uint8_t*& p, const std::uint8_t* end);
std::optional<std::int16_t>  ReadI16(const std::uint8_t*& p, const std::uint8_t* end);

// ---- Сборка/разбор пакетов ----

std::vector<std::uint8_t> SerializePing(std::uint16_t sequenceNumber, std::uint64_t clientSendTimeUs);
std::vector<std::uint8_t> SerializePong(std::uint16_t sequenceNumber,
                                         std::uint64_t clientSendTimeUs,
                                         std::uint64_t serverReceiveTimeUs,
                                         std::uint64_t serverSendTimeUs);

std::vector<std::uint8_t> SerializeMovement(std::uint16_t sequenceNumber, std::uint16_t x, std::uint16_t y,
                                             bool requiresAck = false);
std::vector<std::uint8_t> SerializeShoot(std::uint16_t sequenceNumber, std::uint16_t aimAngleDeg,
                                          std::uint8_t weaponId, bool requiresAck = true);
std::vector<std::uint8_t> SerializeAck(std::uint16_t sequenceNumber, std::uint16_t acknowledgedSequence);

// Разбор возвращает std::nullopt на ЛЮБОЙ некорректной датаграмме:
// нехватка байт, несовпадение packetType, неверная protocolVersion,
// payloadSize не совпадает с фактической длиной датаграммы. Вызывающий
// код (server/client) обязан отбросить такой пакет без падения процесса
// и отразить это в логе — сам парсер не логирует и не бросает исключения.
std::optional<PingPacket> ParsePing(const std::uint8_t* data, std::size_t size);
std::optional<PongPacket> ParsePong(const std::uint8_t* data, std::size_t size);
std::optional<MovementPacket> ParseMovement(const std::uint8_t* data, std::size_t size);
std::optional<ShootPacket> ParseShoot(const std::uint8_t* data, std::size_t size);
// ParseAck дополнительно требует requiresAck == 0.
std::optional<AckPacket> ParseAck(const std::uint8_t* data, std::size_t size);

// Читает только заголовок (используется, чтобы понять packetType ДО того,
// как выбирать, каким ParseXxx разбирать остаток датаграммы). Возвращает
// nullopt, если данных меньше kHeaderSize или встречен неизвестный тип
// пакета/версия или requiresAck вне {0, 1} — датаграмма отбрасывается целиком.
std::optional<Header> ReadHeader(const std::uint8_t* data, std::size_t size);

// =====================================================================================
// Игровые пакеты. Все числа — big-endian. Заголовок тот же (8 байт, версия 2), поэтому
// ping_client_app / pong_server_app / ПР №3 остаются совместимыми. Строгие правила разбора:
//   * Hello, Welcome, GameEvent, Leave — только requiresAck = 1 (надёжные);
//   * Input, Snapshot — только requiresAck = 0 (ненадёжные, потерю перекрывает следующий пакет);
//   * payloadSize == фактическому хвосту датаграммы; счётчики не больше лимитов; лишних байт нет.
// =====================================================================================

constexpr std::uint8_t kGameProtocolVersion = 1;
constexpr std::size_t kMaxNameBytes = 16;
constexpr std::size_t kMaxInputCmds = 16;
constexpr std::size_t kMaxSnapshotPlayers = 8;
constexpr std::size_t kMaxSnapshotRunes = 8;
constexpr std::size_t kMaxOwnerStateBytes = 96;

// Биты кнопок в InputCmd::buttons.
constexpr std::uint8_t kBtnJump = 1, kBtnDash = 2, kBtnLight = 4, kBtnHeavy = 8, kBtnDown = 16, kBtnJumpHeld = 32;

// Welcome::status
constexpr std::uint8_t kWelcomeOk = 0, kWelcomeFull = 1, kWelcomeBadVersion = 2;

// HELLO: gameProto u8 | colorIdx u8 | nameLen u8 | name[nameLen] (UTF-8, непрозрачные байты)
struct HelloPacket {
    std::uint16_t sequenceNumber;
    std::uint8_t gameProto;
    std::uint8_t colorIdx;
    std::vector<std::uint8_t> name;
};

// WELCOME: status u8 | gameProto u8 | playerId u8 | serverTick u16 | tickRateHz u8 | seed u32
struct WelcomePacket {
    std::uint16_t sequenceNumber;
    std::uint8_t status;
    std::uint8_t gameProto;
    std::uint8_t playerId;
    std::uint16_t serverTick;
    std::uint8_t tickRateHz;
    std::uint32_t seed;
};

// INPUT: firstCmdSeq u16 | count u8 (1..16) | count x { axis i8 ; buttons u8 }
// Команда i имеет номер firstCmdSeq + i (mod 65536). Позиций в команде нет — только ввод.
struct InputCmd {
    std::int8_t axis;
    std::uint8_t buttons;
};
struct InputPacket {
    std::uint16_t sequenceNumber;
    std::uint16_t firstCmdSeq;
    std::vector<InputCmd> cmds;
};

// SNAPSHOT: tick u16 | ackCmdSeq u16 | nPlayers u8 | players | ownerLen u8 | ownerState | nRunes u8 | runes
//   PlayerEntry: id u8 | x i16 | y i16 | vx i16 | vy i16 | hp u8 | flags u8 | buffs u16   (13 байт)
//   RuneEntry:   id u8 | type u8 | x i16 | y i16                                           (6 байт)
// ownerState — непрозрачный блок полного состояния игрока-получателя (формат задаёт симуляция).
struct PlayerEntry {
    std::uint8_t id;
    std::int16_t x, y, vx, vy;
    std::uint8_t hp;
    std::uint8_t flags;
    std::uint16_t buffs;
};
struct RuneEntry {
    std::uint8_t id, type;
    std::int16_t x, y;
};
struct SnapshotPacket {
    std::uint16_t sequenceNumber;
    std::uint16_t tick;
    std::uint16_t ackCmdSeq;
    std::vector<PlayerEntry> players;
    std::vector<std::uint8_t> ownerState;
    std::vector<RuneEntry> runes;
};

// GAMEEVENT: eventId u16 | kind u8 | tick u16 | a u8 | b u8 | x i16 | y i16 | v i16   (13 байт)
// Клиент обязан игнорировать повторы по eventId (reliable-канал не упорядочивает и может повторять).
struct GameEventPacket {
    std::uint16_t sequenceNumber;
    std::uint16_t eventId;
    std::uint8_t kind;
    std::uint16_t tick;
    std::uint8_t a, b;
    std::int16_t x, y, v;
};
constexpr std::size_t kGameEventPayloadSize = 13;

// LEAVE: reason u8
struct LeavePacket {
    std::uint16_t sequenceNumber;
    std::uint8_t reason;
};

std::vector<std::uint8_t> SerializeHello(std::uint16_t seq, std::uint8_t gameProto, std::uint8_t colorIdx,
                                          const std::vector<std::uint8_t>& name);
std::vector<std::uint8_t> SerializeWelcome(std::uint16_t seq, const WelcomePacket& w);
std::vector<std::uint8_t> SerializeInput(std::uint16_t seq, std::uint16_t firstCmdSeq,
                                          const std::vector<InputCmd>& cmds);
std::vector<std::uint8_t> SerializeSnapshot(std::uint16_t seq, const SnapshotPacket& s);
std::vector<std::uint8_t> SerializeGameEvent(std::uint16_t seq, const GameEventPacket& e);
std::vector<std::uint8_t> SerializeLeave(std::uint16_t seq, std::uint8_t reason);

std::optional<HelloPacket> ParseHello(const std::uint8_t* data, std::size_t size);
std::optional<WelcomePacket> ParseWelcome(const std::uint8_t* data, std::size_t size);
std::optional<InputPacket> ParseInput(const std::uint8_t* data, std::size_t size);
std::optional<SnapshotPacket> ParseSnapshot(const std::uint8_t* data, std::size_t size);
std::optional<GameEventPacket> ParseGameEvent(const std::uint8_t* data, std::size_t size);
std::optional<LeavePacket> ParseLeave(const std::uint8_t* data, std::size_t size);

// ROSTER: count u8 (<= 8) | count x { id u8, color u8, flags u8 (бит0 хост, бит1 готов), nameLen u8, name[nameLen<=16] }
constexpr std::size_t kMaxRoster = 8;
struct RosterEntry {
    std::uint8_t id, color, flags;
    std::vector<std::uint8_t> name;
};
struct RosterPacket {
    std::uint16_t sequenceNumber;
    std::vector<RosterEntry> entries;
};
std::vector<std::uint8_t> SerializeRoster(std::uint16_t seq, const std::vector<RosterEntry>& entries);
std::optional<RosterPacket> ParseRoster(const std::uint8_t* data, std::size_t size);

} // namespace telemetry
