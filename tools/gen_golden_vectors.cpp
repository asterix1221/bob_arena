// tools/gen_golden_vectors.cpp
// Генерирует godot/tests/golden_vectors.json: эталонные байты пакетов и трассы поведения из C++-реализации
// протокола ПР №2-3. Тесты GDScript (godot/tests/run_tests.gd) сверяют свою реализацию с этим файлом.
// Сборка и запуск (из корня репозитория):
//   g++ -std=c++17 protocol/protocol.cpp reliability/adaptive_timeout.cpp reliability/reliable_channel.cpp
//       reliability/dedup_window.cpp tools/gen_golden_vectors.cpp -o gen_golden   (одной командой, без переноса)
//   ./gen_golden > godot/tests/golden_vectors.json
#include "../protocol/protocol.h"
#include "../reliability/adaptive_timeout.hpp"
#include "../reliability/dedup_window.hpp"
#include "../reliability/reliable_channel.hpp"

#include <cstdio>
#include <string>
#include <vector>

using namespace telemetry;

static std::string Hex(const std::vector<std::uint8_t>& b) {
    std::string s;
    char buf[3];
    for (auto v : b) { std::snprintf(buf, sizeof buf, "%02x", v); s += buf; }
    return s;
}

static bool first = true;
static void Packet(const char* name, const std::vector<std::uint8_t>& bytes, const std::string& fields) {
    std::printf("%s    {\"name\": \"%s\", \"hex\": \"%s\", \"fields\": %s}", first ? "" : ",\n", name, Hex(bytes).c_str(), fields.c_str());
    first = false;
}

int main() {
    std::printf("{\n  \"packets\": [\n");

    Packet("ping", SerializePing(258, 0x0102030405060708ULL), "{\"seq\": 258, \"t\": \"72623859790382856\"}");
    Packet("pong", SerializePong(3, 1000, 2000, 3000), "{\"seq\": 3, \"t_client\": \"1000\", \"t_srv_rx\": \"2000\", \"t_srv_tx\": \"3000\"}");
    Packet("movement", SerializeMovement(9, 1280, 720, true), "{\"seq\": 9, \"x\": 1280, \"y\": 720, \"ack\": true}");
    Packet("shoot", SerializeShoot(300, 271, 4, true), "{\"seq\": 300, \"angle\": 271, \"weapon\": 4, \"ack\": true}");
    Packet("ack", SerializeAck(0x0102, 0x0102), "{\"seq\": 258, \"acked\": 258}");

    const std::vector<std::uint8_t> name = {0xD0, 0x91, 'o', 'b'}; // "Бob"
    Packet("hello", SerializeHello(7, 1, 2, name), "{\"seq\": 7, \"proto\": 1, \"color\": 2, \"name_hex\": \"d0916f62\"}");

    WelcomePacket w{}; w.status = 0; w.gameProto = 1; w.playerId = 3; w.serverTick = 65535; w.tickRateHz = 120; w.seed = 0xDEADBEEF;
    Packet("welcome", SerializeWelcome(9, w), "{\"seq\": 9, \"status\": 0, \"proto\": 1, \"id\": 3, \"tick\": 65535, \"rate\": 120, \"seed\": 3735928559}");

    Packet("input", SerializeInput(10, 65534, {{-127, static_cast<std::uint8_t>(kBtnJump | kBtnJumpHeld)}, {0, 0}, {127, static_cast<std::uint8_t>(kBtnDash | kBtnLight)}}),
           "{\"seq\": 10, \"first\": 65534, \"cmds\": [[-127, 33], [0, 0], [127, 6]]}");

    SnapshotPacket s{};
    s.tick = 1234; s.ackCmdSeq = 4321;
    s.players.push_back({1, -300, 800, -1500, 2000, 100, 0x35, 0x0403});
    s.players.push_back({2, 12345, -1, 0, 0, 7, 0x01, 0});
    s.ownerState = {1, 2, 3, 4, 5};
    s.runes.push_back({9, 3, -50, 600});
    Packet("snapshot", SerializeSnapshot(77, s),
           "{\"seq\": 77, \"tick\": 1234, \"ack\": 4321, "
           "\"players\": [[1, -300, 800, -1500, 2000, 100, 53, 1027], [2, 12345, -1, 0, 0, 7, 1, 0]], "
           "\"owner\": [1, 2, 3, 4, 5], \"runes\": [[9, 3, -50, 600]]}");

    GameEventPacket e{}; e.eventId = 513; e.kind = 4; e.tick = 600; e.a = 1; e.b = 2; e.x = -10; e.y = 20; e.v = -30;
    Packet("gameevent", SerializeGameEvent(5, e), "{\"seq\": 5, \"id\": 513, \"kind\": 4, \"tick\": 600, \"a\": 1, \"b\": 2, \"x\": -10, \"y\": 20, \"v\": -30}");
    std::vector<RosterEntry> roster = {{0, 1, 3, {0xD0, 0xA5, 0xD0, 0xBE}}, {1, 2, 0, {'b', 'o', 'b'}}};
    Packet("roster", SerializeRoster(11, roster), "{\"seq\": 11, \"entries\": [[0, 1, 3, \"d0a5d0be\"], [1, 2, 0, \"626f62\"]]}");
    Packet("leave", SerializeLeave(3, 2), "{\"seq\": 3, \"reason\": 2}");

    std::printf("\n  ],\n");

    // ---- AdaptiveTimeout: после каждого сэмпла (srtt, rttvar, rto) ----
    reliability::AdaptiveTimeout at;
    const double samples[] = {100, 120, 80, 300, 50, 50, 50, 2000, 0};
    std::printf("  \"adaptive_timeout\": {\"initial_rto\": %.6f, \"steps\": [\n", at.RtoMs());
    for (std::size_t i = 0; i < sizeof samples / sizeof *samples; ++i) {
        at.OnSample(samples[i]);
        std::printf("%s    [%.1f, %.9f, %.9f, %.9f]", i ? ",\n" : "", samples[i], at.SrttMs(), at.RttVarMs(), at.RtoMs());
    }
    std::printf("\n  ]},\n");

    // ---- DedupWindow(capacity 3): последовательность seq -> результат MarkProcessed ----
    reliability::DedupWindow dw(3);
    const std::uint16_t seqs[] = {1, 2, 1, 3, 4, 1, 2, 65535, 65535, 0};
    std::printf("  \"dedup\": {\"capacity\": 3, \"steps\": [");
    for (std::size_t i = 0; i < sizeof seqs / sizeof *seqs; ++i) {
        std::printf("%s[%u, %s]", i ? ", " : "", seqs[i], dw.MarkProcessed(seqs[i]) ? "true" : "false");
    }
    std::printf("]},\n");

    // ---- ReliableChannel(maxAttempts 3), rto 100000 мкс ----
    reliability::ReliableChannel ch(3);
    ch.OnSent(10, {10}, 0);   // rawBytes[0] == seq: так в трассе видно, какой пакет повторён
    ch.OnSent(11, {11}, 50000);
    ch.OnSent(12, {12}, 60000);
    std::printf("  \"reliable\": {\"max_attempts\": 3, \"rto_us\": 100000, \"events\": [\n");
    std::printf("    [\"sent\", 10, 0], [\"sent\", 11, 50000], [\"sent\", 12, 60000],\n");
    reliability::AckInfo info;
    bool acked = ch.OnAckReceived(12, 90000, info);
    std::printf("    [\"ack\", 12, 90000, %s, %u, %llu],\n", acked ? "true" : "false", info.attempts, static_cast<unsigned long long>(info.timeToAckUs));
    const std::uint64_t polls[] = {99999, 100000, 150000, 199999, 200000, 250000, 300000, 350000};
    for (std::size_t i = 0; i < sizeof polls / sizeof *polls; ++i) {
        std::vector<std::uint16_t> failed;
        auto due = ch.CollectForRetransmission(polls[i], 100000, &failed);
        std::printf("    [\"poll\", %llu, [", static_cast<unsigned long long>(polls[i]));
        for (std::size_t k = 0; k < due.size(); ++k) std::printf("%s%u", k ? ", " : "", due[k]->rawBytes[0]);
        std::printf("], [");
        for (std::size_t k = 0; k < failed.size(); ++k) std::printf("%s%u", k ? ", " : "", failed[k]);
        std::printf("]]%s\n", i + 1 < sizeof polls / sizeof *polls ? "," : "");
    }
    std::printf("  ]}\n}\n");
    return 0;
}
