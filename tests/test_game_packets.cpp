// tests/test_game_packets.cpp
// Игровые пакеты (Hello/Welcome/Input/Snapshot/GameEvent/Leave): round-trip, строгая валидация,
// устойчивость к мусору. Те же байты сверяются с реализацией на GDScript через golden_vectors.json.
#include "mini_test.h"
#include "../protocol/protocol.h"

#include <cstdlib>
#include <cstring>

using namespace telemetry;

static std::vector<std::uint8_t> Bytes(const char* s) { return std::vector<std::uint8_t>(s, s + std::strlen(s)); }

TEST_CASE("ИГРА Hello: round-trip, requiresAck = 1, имя сохраняется (в т. ч. UTF-8)") {
    const std::vector<std::uint8_t> name = Bytes("Бob"); // кириллица: непрозрачные UTF-8 байты
    auto bytes = SerializeHello(7, kGameProtocolVersion, 2, name);
    auto h = ReadHeader(bytes.data(), bytes.size());
    REQUIRE(h.has_value());
    REQUIRE(h->requiresAck);
    auto p = ParseHello(bytes.data(), bytes.size());
    REQUIRE(p.has_value());
    REQUIRE(p->sequenceNumber == 7);
    REQUIRE(p->gameProto == kGameProtocolVersion);
    REQUIRE(p->colorIdx == 2);
    REQUIRE(p->name == name);
}

TEST_CASE("ИГРА Hello: имя длиннее 16 байт обрезается при сборке, пустое имя допустимо") {
    auto longName = Bytes("0123456789ABCDEFGHIJ");
    auto bytes = SerializeHello(1, 1, 0, longName);
    auto p = ParseHello(bytes.data(), bytes.size());
    REQUIRE(p.has_value());
    REQUIRE(p->name.size() == kMaxNameBytes);
    auto empty = SerializeHello(1, 1, 0, {});
    REQUIRE(ParseHello(empty.data(), empty.size()).has_value());
}

TEST_CASE("ИГРА Hello: nameLen больше фактического хвоста отклоняется") {
    auto bytes = SerializeHello(1, 1, 0, Bytes("abc"));
    bytes[kHeaderSize + 2] = 9; // nameLen
    REQUIRE_FALSE(ParseHello(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("ИГРА Welcome: round-trip всех полей") {
    WelcomePacket w{};
    w.status = kWelcomeOk; w.gameProto = kGameProtocolVersion; w.playerId = 3;
    w.serverTick = 65535; w.tickRateHz = 120; w.seed = 0xDEADBEEF;
    auto bytes = SerializeWelcome(9, w);
    auto p = ParseWelcome(bytes.data(), bytes.size());
    REQUIRE(p.has_value());
    REQUIRE(p->playerId == 3);
    REQUIRE(p->serverTick == 65535);
    REQUIRE(p->tickRateHz == 120);
    REQUIRE(p->seed == 0xDEADBEEFu);
}

TEST_CASE("ИГРА Input: команды нумеруются от firstCmdSeq, оси со знаком, requiresAck = 0") {
    std::vector<InputCmd> cmds = {{-127, kBtnJump | kBtnJumpHeld}, {0, 0}, {127, kBtnDash | kBtnLight}};
    auto bytes = SerializeInput(10, 65534, cmds); // firstCmdSeq у границы переполнения
    auto h = ReadHeader(bytes.data(), bytes.size());
    REQUIRE(h.has_value());
    REQUIRE_FALSE(h->requiresAck);
    auto p = ParseInput(bytes.data(), bytes.size());
    REQUIRE(p.has_value());
    REQUIRE(p->firstCmdSeq == 65534);
    REQUIRE(p->cmds.size() == 3);
    REQUIRE(p->cmds[0].axis == -127);
    REQUIRE(p->cmds[2].buttons == (kBtnDash | kBtnLight));
}

TEST_CASE("ИГРА Input: 0 и более 16 команд отклоняются, 16 допустимо") {
    std::vector<InputCmd> sixteen(16, InputCmd{1, 1});
    auto ok = SerializeInput(1, 0, sixteen);
    REQUIRE(ParseInput(ok.data(), ok.size()).has_value());
    auto zero = SerializeInput(1, 0, {});
    REQUIRE_FALSE(ParseInput(zero.data(), zero.size()).has_value());
    auto bytes = SerializeInput(1, 0, sixteen);
    bytes[kHeaderSize + 2] = 17; // count
    REQUIRE_FALSE(ParseInput(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("ИГРА Snapshot: round-trip игроков, ownerState и рун (отрицательные координаты)") {
    SnapshotPacket s{};
    s.tick = 1234; s.ackCmdSeq = 4321;
    s.players.push_back({1, -300, 800, -1500, 2000, 100, 0x35, 0x0403});
    s.players.push_back({2, 12345, -1, 0, 0, 7, 0x01, 0});
    s.ownerState = {1, 2, 3, 4, 5};
    s.runes.push_back({9, 3, -50, 600});
    auto bytes = SerializeSnapshot(77, s);
    REQUIRE(bytes.size() == kHeaderSize + 2 + 2 + 1 + 13 * 2 + 1 + 5 + 1 + 6);
    auto p = ParseSnapshot(bytes.data(), bytes.size());
    REQUIRE(p.has_value());
    REQUIRE(p->tick == 1234);
    REQUIRE(p->ackCmdSeq == 4321);
    REQUIRE(p->players.size() == 2);
    REQUIRE(p->players[0].x == -300);
    REQUIRE(p->players[0].vx == -1500);
    REQUIRE(p->players[0].buffs == 0x0403);
    REQUIRE(p->players[1].x == 12345);
    REQUIRE(p->ownerState.size() == 5);
    REQUIRE(p->runes.size() == 1);
    REQUIRE(p->runes[0].x == -50);
}

TEST_CASE("ИГРА Snapshot: максимальный размер помещается в безопасный MTU") {
    SnapshotPacket s{};
    s.players.assign(kMaxSnapshotPlayers, PlayerEntry{});
    s.ownerState.assign(kMaxOwnerStateBytes, 0xAA);
    s.runes.assign(kMaxSnapshotRunes, RuneEntry{});
    auto bytes = SerializeSnapshot(1, s);
    REQUIRE(bytes.size() < 500);
    REQUIRE(ParseSnapshot(bytes.data(), bytes.size()).has_value());
}

TEST_CASE("ИГРА GameEvent: round-trip, requiresAck = 1, фиксированные 13 байт payload") {
    GameEventPacket e{};
    e.eventId = 513; e.kind = 4; e.tick = 600; e.a = 1; e.b = 2; e.x = -10; e.y = 20; e.v = -30;
    auto bytes = SerializeGameEvent(5, e);
    REQUIRE(bytes.size() == kHeaderSize + kGameEventPayloadSize);
    auto p = ParseGameEvent(bytes.data(), bytes.size());
    REQUIRE(p.has_value());
    REQUIRE(p->eventId == 513);
    REQUIRE(p->v == -30);
}

TEST_CASE("ИГРА Leave: round-trip") {
    auto bytes = SerializeLeave(3, 2);
    auto p = ParseLeave(bytes.data(), bytes.size());
    REQUIRE(p.has_value());
    REQUIRE(p->reason == 2);
}

TEST_CASE("ИГРА строго: неверный requiresAck отклоняется для каждого игрового типа") {
    auto hello = SerializeHello(1, 1, 0, Bytes("a"));        hello[7] = 0;
    auto in = SerializeInput(1, 0, {{1, 1}});                in[7] = 1;
    SnapshotPacket s{}; auto snap = SerializeSnapshot(1, s); snap[7] = 1;
    auto ev = SerializeGameEvent(1, GameEventPacket{});      ev[7] = 0;
    auto leave = SerializeLeave(1, 0);                       leave[7] = 0;
    REQUIRE_FALSE(ParseHello(hello.data(), hello.size()).has_value());
    REQUIRE_FALSE(ParseInput(in.data(), in.size()).has_value());
    REQUIRE_FALSE(ParseSnapshot(snap.data(), snap.size()).has_value());
    REQUIRE_FALSE(ParseGameEvent(ev.data(), ev.size()).has_value());
    REQUIRE_FALSE(ParseLeave(leave.data(), leave.size()).has_value());
}

TEST_CASE("ИГРА строго: тип не от своего парсера отклоняется") {
    auto leave = SerializeLeave(1, 0);
    REQUIRE_FALSE(ParseHello(leave.data(), leave.size()).has_value());
    REQUIRE_FALSE(ParseGameEvent(leave.data(), leave.size()).has_value());
}

TEST_CASE("ИГРА устойчивость: любой усечённый или удлинённый пакет отклоняется, без падений") {
    SnapshotPacket s{};
    s.players.push_back({1, 1, 2, 3, 4, 5, 6, 7});
    s.ownerState = {9, 9};
    s.runes.push_back({1, 1, 1, 1});
    std::vector<std::vector<std::uint8_t>> all = {
        SerializeHello(1, 1, 0, Bytes("name")),
        SerializeWelcome(1, WelcomePacket{}),
        SerializeInput(1, 5, {{1, 2}, {3, 4}}),
        SerializeSnapshot(1, s),
        SerializeGameEvent(1, GameEventPacket{}),
        SerializeLeave(1, 1),
    };
    for (auto& pkt : all) {
        for (std::size_t cut = 0; cut < pkt.size(); ++cut) {
            REQUIRE_FALSE(ParseHello(pkt.data(), cut).has_value());
            REQUIRE_FALSE(ParseWelcome(pkt.data(), cut).has_value());
            REQUIRE_FALSE(ParseInput(pkt.data(), cut).has_value());
            REQUIRE_FALSE(ParseSnapshot(pkt.data(), cut).has_value());
            REQUIRE_FALSE(ParseGameEvent(pkt.data(), cut).has_value());
            REQUIRE_FALSE(ParseLeave(pkt.data(), cut).has_value());
        }
        auto longer = pkt; longer.push_back(0);
        REQUIRE_FALSE(ParseHello(longer.data(), longer.size()).has_value());
        REQUIRE_FALSE(ParseWelcome(longer.data(), longer.size()).has_value());
        REQUIRE_FALSE(ParseInput(longer.data(), longer.size()).has_value());
        REQUIRE_FALSE(ParseSnapshot(longer.data(), longer.size()).has_value());
        REQUIRE_FALSE(ParseGameEvent(longer.data(), longer.size()).has_value());
        REQUIRE_FALSE(ParseLeave(longer.data(), longer.size()).has_value());
    }
}

TEST_CASE("ИГРА устойчивость: 20000 случайных датаграмм не роняют парсеры") {
    std::srand(12345);
    for (int i = 0; i < 20000; ++i) {
        std::vector<std::uint8_t> junk(static_cast<std::size_t>(std::rand() % 64));
        for (auto& b : junk) b = static_cast<std::uint8_t>(std::rand());
        if (junk.size() >= 8 && (i % 2) == 0) { // правдоподобный заголовок: версия 2, тип 6..11
            junk[0] = static_cast<std::uint8_t>(6 + std::rand() % 6);
            junk[5] = 0; junk[6] = 2;
            junk[3] = 0; junk[4] = static_cast<std::uint8_t>(junk.size() - 8);
        }
        (void)ParseHello(junk.data(), junk.size());
        (void)ParseWelcome(junk.data(), junk.size());
        (void)ParseInput(junk.data(), junk.size());
        (void)ParseSnapshot(junk.data(), junk.size());
        (void)ParseGameEvent(junk.data(), junk.size());
        (void)ParseLeave(junk.data(), junk.size());
    }
    REQUIRE(true);
}
