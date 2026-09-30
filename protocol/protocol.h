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

} // namespace telemetry
