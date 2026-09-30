// tests/test_reliable_protocol.cpp
// Тесты расширения протокола в ПР №3: ACK, поле requiresAck, MOVEMENT/SHOOT,
// валидация до чтения полей.
#include "mini_test.h"
#include "../protocol/protocol.h"

using namespace telemetry;

TEST_CASE("SHOOT round-trip: requiresAck = 1, поля сохраняются") {
    auto bytes = SerializeShoot(300, 271, 4, /*requiresAck=*/true);
    REQUIRE(bytes.size() == kShootPacketSize);
    auto parsed = ParseShoot(bytes.data(), bytes.size());
    REQUIRE(parsed.has_value());
    REQUIRE(parsed->sequenceNumber == 300);
    REQUIRE(parsed->requiresAck);
    REQUIRE(parsed->aimAngleDeg == 271);
    REQUIRE(parsed->weaponId == 4);
}

TEST_CASE("MOVEMENT round-trip: по умолчанию ненадёжный (requiresAck = 0)") {
    auto bytes = SerializeMovement(9, 1280, 720);
    REQUIRE(bytes.size() == kMovementPacketSize);
    auto parsed = ParseMovement(bytes.data(), bytes.size());
    REQUIRE(parsed.has_value());
    REQUIRE(parsed->sequenceNumber == 9);
    REQUIRE_FALSE(parsed->requiresAck);
    REQUIRE(parsed->x == 1280);
    REQUIRE(parsed->y == 720);
}

TEST_CASE("ACK round-trip: payload содержит только подтверждаемый номер") {
    auto bytes = SerializeAck(0x0102, 0x0102);
    REQUIRE(bytes.size() == kAckPacketSize);
    REQUIRE(bytes.size() == kHeaderSize + sizeof(AckPayload::acknowledgedSequence));

    auto parsed = ParseAck(bytes.data(), bytes.size());
    REQUIRE(parsed.has_value());
    REQUIRE(parsed->sequenceNumber == 0x0102);
    REQUIRE(parsed->payload.acknowledgedSequence == 0x0102);
}

TEST_CASE("Раскладка заголовка SHOOT в сетевом порядке байт") {
    auto bytes = SerializeShoot(0x0A0B, 0x0C0D, 0xEE, true);
    REQUIRE(bytes[0] == static_cast<std::uint8_t>(PacketType::Shoot));
    REQUIRE(bytes[1] == 0x0A);
    REQUIRE(bytes[2] == 0x0B);
    REQUIRE(bytes[3] == 0x00); // payloadSize = 3
    REQUIRE(bytes[4] == 0x03);
    REQUIRE(bytes[5] == 0x00); // protocolVersion = 2
    REQUIRE(bytes[6] == 0x02);
    REQUIRE(bytes[7] == 0x01); // requiresAck = 1
    REQUIRE(bytes[8] == 0x0C); // aimAngleDeg
    REQUIRE(bytes[9] == 0x0D);
    REQUIRE(bytes[10] == 0xEE); // weaponId
}

TEST_CASE("ACK сам не требует подтверждения: requiresAck = 0, а ACK с requiresAck = 1 отбрасывается") {
    auto bytes = SerializeAck(5, 5);
    REQUIRE(bytes[7] == 0x00);
    auto header = ReadHeader(bytes.data(), bytes.size());
    REQUIRE(header.has_value());
    REQUIRE_FALSE(header->requiresAck);

    bytes[7] = 0x01; // подделанный "ACK, требующий ACK"
    REQUIRE_FALSE(ParseAck(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("PING/PONG с requiresAck = 1 отбрасываются (подтверждений не требуют)") {
    auto ping = SerializePing(1, 100);
    ping[7] = 0x01;
    REQUIRE_FALSE(ParsePing(ping.data(), ping.size()).has_value());

    auto pong = SerializePong(1, 1, 2, 3);
    pong[7] = 0x01;
    REQUIRE_FALSE(ParsePong(pong.data(), pong.size()).has_value());
}

TEST_CASE("requiresAck вне {0, 1} отклоняется уже на уровне заголовка") {
    auto bytes = SerializeShoot(1, 0, 0, true);
    bytes[7] = 0x02;
    REQUIRE_FALSE(ReadHeader(bytes.data(), bytes.size()).has_value());
    REQUIRE_FALSE(ParseShoot(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("Неизвестные packetType (0 и 6) отклоняются") {
    auto bytes = SerializeAck(1, 1);
    bytes[0] = 0;
    REQUIRE_FALSE(ReadHeader(bytes.data(), bytes.size()).has_value());
    bytes[0] = 6;
    REQUIRE_FALSE(ReadHeader(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("Усечённые и удлинённые ACK/SHOOT/MOVEMENT отклоняются") {
    auto ack = SerializeAck(1, 1);
    REQUIRE_FALSE(ParseAck(ack.data(), ack.size() - 1).has_value());
    ack.push_back(0xFF);
    REQUIRE_FALSE(ParseAck(ack.data(), ack.size()).has_value());

    auto shoot = SerializeShoot(1, 10, 1);
    REQUIRE_FALSE(ParseShoot(shoot.data(), shoot.size() - 1).has_value());
    shoot.push_back(0x00);
    REQUIRE_FALSE(ParseShoot(shoot.data(), shoot.size()).has_value());

    auto move = SerializeMovement(1, 2, 3);
    REQUIRE_FALSE(ParseMovement(move.data(), move.size() - 1).has_value());
}

TEST_CASE("Заголовок короче kHeaderSize (7 байт из 8) отклоняется") {
    auto bytes = SerializeAck(1, 1);
    REQUIRE_FALSE(ReadHeader(bytes.data(), kHeaderSize - 1).has_value());
}

TEST_CASE("Несовпадающая версия протокола в ACK отклоняется") {
    auto bytes = SerializeAck(1, 1);
    bytes[6] = 0x01; // версия 1 (формат ПР №2) вместо 2
    REQUIRE_FALSE(ParseAck(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("Неверный payloadSize в SHOOT отклоняется (даже если длина датаграммы совпадает)") {
    auto bytes = SerializeShoot(1, 10, 1);
    bytes[4] = 0x02; // заявлено 2 байта вместо 3
    REQUIRE_FALSE(ParseShoot(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("Парсеры не принимают пакеты чужого типа") {
    auto ack = SerializeAck(1, 1);
    auto shoot = SerializeShoot(1, 10, 1);
    auto move = SerializeMovement(1, 2, 3);
    REQUIRE_FALSE(ParseShoot(ack.data(), ack.size()).has_value());
    REQUIRE_FALSE(ParseAck(shoot.data(), shoot.size()).has_value());
    REQUIRE_FALSE(ParseMovement(shoot.data(), shoot.size()).has_value());
    REQUIRE_FALSE(ParseShoot(move.data(), move.size()).has_value());
}
