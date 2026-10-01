// tests/test_reliable_channel.cpp
// Тесты менеджера надёжной доставки (ПР №3): ReliableChannel, DedupWindow и
// сквозная симуляция "клиент <-> потерявшая пакеты сеть <-> сервер" на
// виртуальном времени (без сокетов и без sleep — тесты детерминированы).
// Первые три теста — дословно примеры из задания (там Catch2, здесь mini_test.h).
#include "mini_test.h"
#include "../protocol/protocol.h"
#include "../reliability/adaptive_timeout.hpp"
#include "../reliability/dedup_window.hpp"
#include "../reliability/reliable_channel.hpp"

#include <map>
#include <queue>
#include <random>
#include <set>
#include <vector>

using namespace reliability;

// ---------------------------------------------------------------- из задания

TEST_CASE("Packet is retransmitted after RTO expires") {
    ReliableChannel channel(/*maxAttempts=*/3);
    channel.OnSent(1, {0x04, 0x00, 0x01}, /*nowUs=*/0);

    auto none = channel.CollectForRetransmission(/*nowUs=*/50'000, /*rtoUs=*/200'000);
    REQUIRE(none.empty());

    auto due = channel.CollectForRetransmission(/*nowUs=*/250'000, /*rtoUs=*/200'000);
    REQUIRE(due.size() == 1);
    REQUIRE(due.front()->attempts == 2);
}

TEST_CASE("Packet exceeding max attempts moves to failed") {
    ReliableChannel channel(/*maxAttempts=*/2);
    channel.OnSent(7, {}, 0);
    channel.CollectForRetransmission(300'000, 200'000); // попытка 2
    channel.CollectForRetransmission(600'000, 200'000); // попытка 3 -> failed

    REQUIRE(channel.FailedCount() == 1);
    REQUIRE(channel.PendingCount() == 0);
}

TEST_CASE("Duplicate ACK is ignored") {
    ReliableChannel channel;
    channel.OnSent(3, {}, 0);
    REQUIRE(channel.OnAckReceived(3));
    REQUIRE_FALSE(channel.OnAckReceived(3));
}

// ------------------------------------------------------------ ReliableChannel

TEST_CASE("ACK снимает пакет с учёта: повторная отправка прекращается") {
    ReliableChannel channel(5);
    channel.OnSent(10, {1, 2, 3}, 0);
    REQUIRE(channel.PendingCount() == 1);

    REQUIRE(channel.OnAckReceived(10));
    REQUIRE(channel.PendingCount() == 0);
    REQUIRE(channel.CollectForRetransmission(10'000'000, 200'000).empty());
    REQUIRE(channel.FailedCount() == 0);
}

TEST_CASE("ACK на неизвестный sequence игнорируется без ошибки") {
    ReliableChannel channel;
    channel.OnSent(1, {}, 0);
    REQUIRE_FALSE(channel.OnAckReceived(999));
    REQUIRE(channel.PendingCount() == 1);
}

TEST_CASE("Пакет не возвращается чаще, чем раз в adaptiveTimeoutUs") {
    ReliableChannel channel(10);
    channel.OnSent(1, {}, 0);

    REQUIRE(channel.CollectForRetransmission(200'000, 200'000).size() == 1); // попытка 2, lastSent = 200k
    REQUIRE(channel.CollectForRetransmission(250'000, 200'000).empty());    // прошло только 50 мс
    REQUIRE(channel.CollectForRetransmission(399'999, 200'000).empty());    // на 1 мкс меньше RTO
    auto again = channel.CollectForRetransmission(400'000, 200'000);        // ровно RTO
    REQUIRE(again.size() == 1);
    REQUIRE(again.front()->attempts == 3);
}

TEST_CASE("Общее число отправок пакета равно maxAttempts, затем недоставка") {
    const std::uint32_t maxAttempts = 4;
    ReliableChannel channel(maxAttempts);
    channel.OnSent(5, {0xAA}, 0);

    std::uint32_t transmissions = 1; // первая отправка
    std::uint64_t now = 0;
    std::vector<std::uint16_t> failedNow;
    for (int i = 0; i < 20 && channel.PendingCount() > 0; ++i) {
        now += 100'000;
        transmissions += static_cast<std::uint32_t>(channel.CollectForRetransmission(now, 100'000, &failedNow).size());
    }
    REQUIRE(transmissions == maxAttempts);
    REQUIRE(channel.FailedCount() == 1);
    REQUIRE(channel.PendingCount() == 0);
    REQUIRE(failedNow.size() == 1);
    REQUIRE(failedNow[0] == 5);
}

TEST_CASE("newlyFailed сообщает о недоставке ровно один раз") {
    ReliableChannel channel(1); // только первая отправка, повторов нет
    channel.OnSent(8, {}, 0);

    std::vector<std::uint16_t> failed1, failed2;
    auto due = channel.CollectForRetransmission(200'000, 200'000, &failed1);
    REQUIRE(due.empty());
    REQUIRE(failed1.size() == 1);
    REQUIRE(failed1[0] == 8);

    channel.CollectForRetransmission(400'000, 200'000, &failed2);
    REQUIRE(failed2.empty());
    REQUIRE(channel.FailedCount() == 1);
}

TEST_CASE("Запоздавший ACK на пакет из failed_ игнорируется") {
    ReliableChannel channel(1);
    channel.OnSent(2, {}, 0);
    channel.CollectForRetransmission(300'000, 200'000); // -> failed
    REQUIRE(channel.FailedCount() == 1);

    REQUIRE_FALSE(channel.OnAckReceived(2));
    REQUIRE(channel.FailedCount() == 1);
    REQUIRE(channel.PendingCount() == 0);
}

TEST_CASE("OnAckReceived сообщает число попыток и время до ACK от первой отправки") {
    ReliableChannel channel(5);
    channel.OnSent(4, {}, 1'000'000);
    channel.CollectForRetransmission(1'300'000, 250'000); // повтор: attempts = 2

    AckInfo info;
    REQUIRE(channel.OnAckReceived(4, 1'420'000, info));
    REQUIRE(info.attempts == 2);
    REQUIRE(info.timeToAckUs == 420'000); // от ПЕРВОЙ отправки, а не от повтора

    AckInfo again;
    REQUIRE_FALSE(channel.OnAckReceived(4, 1'500'000, again)); // дубликат ACK
}

TEST_CASE("Несколько пакетов учитываются независимо, результат упорядочен по времени отправки") {
    ReliableChannel channel(5);
    channel.OnSent(30, {}, 0);
    channel.OnSent(10, {}, 10'000);
    channel.OnSent(20, {}, 20'000);
    REQUIRE(channel.OnAckReceived(10)); // средний подтверждён

    auto due = channel.CollectForRetransmission(1'000'000, 100'000);
    REQUIRE(due.size() == 2);
    REQUIRE(due[0]->firstSentAtUs == 0);
    REQUIRE(due[1]->firstSentAtUs == 20'000);
}

TEST_CASE("rawBytes сохраняются без изменений для повторной отправки") {
    ReliableChannel channel;
    std::vector<std::uint8_t> raw = {9, 8, 7, 6};
    channel.OnSent(1, raw, 0);
    auto due = channel.CollectForRetransmission(500'000, 100'000);
    REQUIRE(due.size() == 1);
    REQUIRE(due.front()->rawBytes == raw);
}

// ---------------------------------------------------------------- DedupWindow

TEST_CASE("DedupWindow: первый раз true, повторный номер — дубликат") {
    DedupWindow window(16);
    REQUIRE(window.MarkProcessed(5));
    REQUIRE_FALSE(window.MarkProcessed(5));
    REQUIRE(window.MarkProcessed(6));
    REQUIRE(window.Contains(5));
    REQUIRE_FALSE(window.Contains(7));
}

TEST_CASE("DedupWindow: при переполнении вытесняется самый старый номер") {
    DedupWindow window(3);
    window.MarkProcessed(1);
    window.MarkProcessed(2);
    window.MarkProcessed(3);
    window.MarkProcessed(4); // вытесняет 1
    REQUIRE(window.Size() == 3);
    REQUIRE_FALSE(window.Contains(1));
    REQUIRE(window.Contains(2));
    REQUIRE_FALSE(window.MarkProcessed(4)); // недавний номер по-прежнему распознаётся
    REQUIRE(window.MarkProcessed(1));       // вытесненный считается новым (ограничение окна)
}

// -------------------------------------------- сквозная симуляция с потерями

namespace {

struct SimResult {
    int sent = 0;
    int acked = 0;
    int failed = 0;
    int serverApplied = 0;           // сколько раз игровой эффект применён на сервере
    int serverDuplicatesIgnored = 0; // сколько копий отброшено окном дедупликации
    int retransmissions = 0;
    std::map<std::uint16_t, int> appliedPerSeq;
    std::set<std::uint16_t> ackedSeqs;
    std::set<std::uint16_t> failedSeqs;
    std::size_t pendingAtEnd = 0;
};

// Виртуальная сеть: каждая датаграмма независимо теряется с вероятностью
// lossPercent в КАЖДУЮ сторону, задержка в одну сторону — oneWayUs.
SimResult RunSimulation(int commands, int lossPercent, std::uint32_t maxAttempts, std::uint32_t seed,
                        std::uint64_t oneWayUs = 20'000) {
    struct Datagram {
        std::uint64_t deliverAtUs;
        bool toServer;
        std::vector<std::uint8_t> bytes;
        bool operator>(const Datagram& o) const { return deliverAtUs > o.deliverAtUs; }
    };
    std::priority_queue<Datagram, std::vector<Datagram>, std::greater<Datagram>> link;

    std::mt19937 rng(seed);
    std::uniform_int_distribution<int> percent(1, 100);
    auto lost = [&] { return lossPercent > 0 && percent(rng) <= lossPercent; };

    ReliableChannel channel(maxAttempts);
    AdaptiveTimeout rto;
    DedupWindow window(1024);
    SimResult r;

    const std::uint64_t sendEveryUs = 10'000;
    const std::uint64_t stepUs = 1'000;
    std::uint16_t nextSeq = 0;

    for (std::uint64_t now = 0;; now += stepUs) {
        if (r.sent < commands && now % sendEveryUs == 0) {
            auto raw = telemetry::SerializeShoot(nextSeq, 90, 1, /*requiresAck=*/true);
            channel.OnSent(nextSeq, raw, now);
            if (!lost()) link.push({now + oneWayUs, true, raw});
            ++nextSeq;
            ++r.sent;
        }

        while (!link.empty() && link.top().deliverAtUs <= now) {
            Datagram d = link.top();
            link.pop();

            if (d.toServer) {
                auto shoot = telemetry::ParseShoot(d.bytes.data(), d.bytes.size());
                REQUIRE(shoot.has_value());
                // Сначала ACK (на каждую копию), затем эффект — только для нового номера.
                if (shoot->requiresAck && !lost()) {
                    link.push({now + oneWayUs, false, telemetry::SerializeAck(shoot->sequenceNumber, shoot->sequenceNumber)});
                }
                if (window.MarkProcessed(shoot->sequenceNumber)) {
                    ++r.serverApplied;
                    ++r.appliedPerSeq[shoot->sequenceNumber];
                } else {
                    ++r.serverDuplicatesIgnored;
                }
            } else {
                auto ack = telemetry::ParseAck(d.bytes.data(), d.bytes.size());
                REQUIRE(ack.has_value());
                AckInfo info;
                if (channel.OnAckReceived(ack->payload.acknowledgedSequence, now, info)) {
                    ++r.acked;
                    r.ackedSeqs.insert(ack->payload.acknowledgedSequence);
                    if (info.attempts == 1) rto.OnSample(static_cast<double>(info.timeToAckUs) / 1000.0); // Karn
                }
            }
        }

        std::vector<std::uint16_t> failedNow;
        for (PendingPacket* p : channel.CollectForRetransmission(now, rto.RtoUs(), &failedNow)) {
            ++r.retransmissions;
            if (!lost()) link.push({now + oneWayUs, true, p->rawBytes});
        }
        for (std::uint16_t seq : failedNow) {
            ++r.failed;
            r.failedSeqs.insert(seq);
        }

        if (r.sent == commands && channel.PendingCount() == 0) break;
        if (now > 600'000'000ULL) break; // защита от зависания теста (10 минут виртуального времени)
    }
    r.pendingAtEnd = channel.PendingCount();
    return r;
}

} // namespace

TEST_CASE("Симуляция без потерь: все команды подтверждены с первой попытки, повторов нет") {
    SimResult r = RunSimulation(100, 0, 5, 1);
    REQUIRE(r.acked == 100);
    REQUIRE(r.failed == 0);
    REQUIRE(r.retransmissions == 0);
    REQUIRE(r.serverApplied == 100);
    REQUIRE(r.serverDuplicatesIgnored == 0);
}

TEST_CASE("Симуляция с потерями 20%: каждая команда применена на сервере не более одного раза") {
    SimResult r = RunSimulation(200, 20, 8, 12345);
    REQUIRE(r.pendingAtEnd == 0);
    REQUIRE(r.acked + r.failed == 200);
    REQUIRE(r.retransmissions > 0);
    // Повторно присланные копии были, но эффект применён ровно один раз на номер.
    REQUIRE(r.serverDuplicatesIgnored > 0);
    for (const auto& [seq, count] : r.appliedPerSeq) {
        REQUIRE(count == 1);
    }
    // Каждая подтверждённая команда действительно дошла до сервера.
    for (std::uint16_t seq : r.ackedSeqs) {
        REQUIRE(r.appliedPerSeq.count(seq) == 1);
    }
    // Команда не может быть одновременно подтверждена и объявлена недоставленной.
    for (std::uint16_t seq : r.failedSeqs) {
        REQUIRE(r.ackedSeqs.count(seq) == 0);
    }
}

TEST_CASE("Симуляция: потерян только ACK — сервер получает копию, эффект не дублируется") {
    // Потери 50% дают много потерянных ACK; инвариант "эффект <= 1 раза" обязан сохраняться.
    SimResult r = RunSimulation(100, 50, 10, 777);
    for (const auto& [seq, count] : r.appliedPerSeq) {
        REQUIRE(count == 1);
    }
    REQUIRE(r.serverApplied <= 100);
}

TEST_CASE("Симуляция полной потери связи: все команды уходят в failed после maxAttempts попыток") {
    SimResult r = RunSimulation(10, 100, 3, 5);
    REQUIRE(r.acked == 0);
    REQUIRE(r.failed == 10);
    REQUIRE(r.serverApplied == 0);
    REQUIRE(r.retransmissions == 10 * (3 - 1)); // каждая команда: 1 первая отправка + 2 повтора
    REQUIRE(r.pendingAtEnd == 0);
}
