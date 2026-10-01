// tests/test_protocol.cpp
// Тесты сериализации PING/PONG и отбраковки некорректных датаграмм
// (см. задание: "автоматические тесты сериализации... и ошибочных пакетов").
#include "mini_test.h"
#include "../protocol/protocol.h"

using namespace telemetry;

TEST_CASE("PING сериализуется/разбирается без потерь (round-trip)") {
    auto bytes = SerializePing(42, 987654321ULL);
    REQUIRE(bytes.size() == kPingPacketSize);

    auto parsed = ParsePing(bytes.data(), bytes.size());
    REQUIRE(parsed.has_value());
    REQUIRE(parsed->sequenceNumber == 42);
    REQUIRE(parsed->clientSendTimeUs == 987654321ULL);
}

TEST_CASE("PONG сериализуется/разбирается без потерь (round-trip)") {
    auto bytes = SerializePong(7, 1000, 2000, 2500);
    REQUIRE(bytes.size() == kPongPacketSize);

    auto parsed = ParsePong(bytes.data(), bytes.size());
    REQUIRE(parsed.has_value());
    REQUIRE(parsed->sequenceNumber == 7);
    REQUIRE(parsed->clientSendTimeUs == 1000ULL);
    REQUIRE(parsed->serverReceiveTimeUs == 2000ULL);
    REQUIRE(parsed->serverSendTimeUs == 2500ULL);
}

TEST_CASE("Байтовый порядок в заголовке и полях — сетевой (big-endian)") {
    auto bytes = SerializePing(0x0102, 0x0102030405060708ULL);
    // packetType
    REQUIRE(bytes[0] == static_cast<std::uint8_t>(PacketType::Ping));
    // sequenceNumber = 0x0102 -> старший байт первым
    REQUIRE(bytes[1] == 0x01);
    REQUIRE(bytes[2] == 0x02);
    // payloadSize = 8 -> 0x00, 0x08
    REQUIRE(bytes[3] == 0x00);
    REQUIRE(bytes[4] == 0x08);
    // protocolVersion = kProtocolVersion (2, ПР №3) -> 0x00, 0x02
    REQUIRE(bytes[5] == 0x00);
    REQUIRE(bytes[6] == 0x02);
    // requiresAck = 0 (PING подтверждений не требует)
    REQUIRE(bytes[7] == 0x00);
    // clientSendTimeUs = 0x0102030405060708 -> старший байт первым
    REQUIRE(bytes[8] == 0x01);
    REQUIRE(bytes[15] == 0x08);
}

TEST_CASE("Усечённый PING отклоняется (не хватает байт полезной нагрузки)") {
    auto bytes = SerializePing(17, 100);
    REQUIRE_FALSE(ParsePing(bytes.data(), bytes.size() - 1).has_value());
}

TEST_CASE("Усечённый заголовок (меньше kHeaderSize байт) отклоняется") {
    std::uint8_t tiny[3] = {1, 0, 0};
    REQUIRE_FALSE(ReadHeader(tiny, sizeof(tiny)).has_value());
    REQUIRE_FALSE(ParsePing(tiny, sizeof(tiny)).has_value());
}

TEST_CASE("Пустой/нулевой буфер отклоняется без падения") {
    REQUIRE_FALSE(ReadHeader(nullptr, 0).has_value());
    std::uint8_t buf[1] = {0};
    REQUIRE_FALSE(ReadHeader(buf, 0).has_value());
}

TEST_CASE("Несовпадение payloadSize с фактической длиной датаграммы отклоняется") {
    auto bytes = SerializePing(1, 42);
    bytes.push_back(0xFF); // "лишний" байт мусора после корректного PING
    REQUIRE_FALSE(ParsePing(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("Неизвестный packetType отклоняется") {
    auto bytes = SerializePing(1, 42);
    bytes[0] = 99; // подменяем тип пакета на несуществующий
    REQUIRE_FALSE(ReadHeader(bytes.data(), bytes.size()).has_value());
    REQUIRE_FALSE(ParsePing(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("Несовпадающая версия протокола отклоняется") {
    auto bytes = SerializePing(1, 42);
    bytes[5] = 0x00;
    bytes[6] = 0x03; // protocolVersion = 3 вместо ожидаемой 2 (kProtocolVersion)
    REQUIRE_FALSE(ReadHeader(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("ParsePing отклоняет пакет, который на самом деле PONG") {
    auto bytes = SerializePong(1, 10, 20, 30);
    REQUIRE_FALSE(ParsePing(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("ParsePong отклоняет пакет, который на самом деле PING") {
    auto bytes = SerializePing(1, 10);
    REQUIRE_FALSE(ParsePong(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("ReadU16/ReadU64 сообщают о нехватке байт, а не читают за пределы буфера") {
    std::uint8_t buf[3] = {0x01, 0x02, 0x03};
    const std::uint8_t* p = buf;
    const std::uint8_t* end = buf + sizeof(buf);

    auto u16 = ReadU16(p, end);
    REQUIRE(u16.has_value());
    REQUIRE(*u16 == 0x0102);

    // Остался 1 байт — ReadU16 снова не должен читать за границу.
    auto shortU16 = ReadU16(p, end);
    REQUIRE_FALSE(shortU16.has_value());

    const std::uint8_t* p2 = buf;
    auto u64 = ReadU64(p2, end); // 3 байта, а нужно 8 — должен вернуть nullopt
    REQUIRE_FALSE(u64.has_value());
}
