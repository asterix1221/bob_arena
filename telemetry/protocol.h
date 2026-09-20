// telemetry/protocol.h
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
// Итог: телеметрия слушает СВОИ порт/сокет (см. transport.h, отдельные
// исполняемые файлы ping_client_app / pong_server_app), не пересекаясь
// по проводам с MOVEMENT/SHOOT/AUTH_* из ПР №1.

#pragma once

#include <cstdint>
#include <cstddef>
#include <vector>
#include <optional>

namespace telemetry {

// Версия формата пакетов телеметрии. Меняется при несовместимом
// изменении контракта (см. ReadHeader: пакет с другой версией отбрасывается).
constexpr std::uint16_t kProtocolVersion = 1;

enum class PacketType : std::uint8_t {
    Ping = 1,
    Pong = 2,
};

// Общий заголовок телеметрийного пакета (7 байт "на проводе"):
//   packetType      uint8_t   — PacketType::Ping / PacketType::Pong
//   sequenceNumber  uint16_t  — идентификатор измерения
//   payloadSize     uint16_t  — размер payload в байтах (без заголовка)
//   protocolVersion uint16_t  — версия формата пакета
// Это структура для УДОБСТВА ВЫЗЫВАЮЩЕГО КОДА, а не layout "на проводе":
// на проводе поля пишутся/читаются явными Write*/Read* ниже, без
// reinterpret_cast и без #pragma pack.
struct Header {
    PacketType packetType;
    std::uint16_t sequenceNumber;
    std::uint16_t payloadSize;
    std::uint16_t protocolVersion;
};

constexpr std::size_t kHeaderSize = 1 + 2 + 2 + 2; // 7 байт

// PING: клиент -> сервер. payload = clientSendTimeUs (8 байт).
struct PingPacket {
    std::uint16_t sequenceNumber;
    std::uint64_t clientSendTimeUs;
};
constexpr std::size_t kPingPayloadSize = 8;
constexpr std::size_t kPingPacketSize = kHeaderSize + kPingPayloadSize; // 15 байт

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
constexpr std::size_t kPongPacketSize = kHeaderSize + kPongPayloadSize; // 31 байт

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

// Разбор возвращает std::nullopt на ЛЮБОЙ некорректной датаграмме:
// нехватка байт, несовпадение packetType, неверная protocolVersion,
// payloadSize не совпадает с фактической длиной датаграммы. Вызывающий
// код (server/client) обязан отбросить такой пакет без падения процесса
// и отразить это в логе — сам парсер не логирует и не бросает исключения.
std::optional<PingPacket> ParsePing(const std::uint8_t* data, std::size_t size);
std::optional<PongPacket> ParsePong(const std::uint8_t* data, std::size_t size);

// Читает только заголовок (используется, чтобы понять packetType ДО того,
// как выбирать, каким ParseXxx разбирать остаток датаграммы). Возвращает
// nullopt, если данных меньше kHeaderSize или встречен неизвестный тип
// пакета/версия — в этом случае датаграмма отбрасывается целиком.
std::optional<Header> ReadHeader(const std::uint8_t* data, std::size_t size);

} // namespace telemetry
