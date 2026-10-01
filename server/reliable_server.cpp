// server/reliable_server.cpp
// UDP-сервер надёжной доставки (ПР №3). Принимает PING / MOVEMENT / SHOOT:
//   PING     -> PONG (как в ПР №2);
//   MOVEMENT -> применяется без подтверждения (ненадёжная команда);
//   SHOOT    -> если requiresAck = 1, НЕМЕДЛЕННО ставит в очередь ACK с тем же
//               sequenceNumber, затем применяет эффект ОДИН раз: повторно
//               присланные копии (retransmission) распознаются окном
//               reliability::DedupWindow и эффект не дублируют, но ACK на них
//               отправляется снова — исходный ACK мог потеряться.
//
// Эмуляция сети (Clumsy доступен только под Windows — см.
// docs/Experiment_Config.md, та же причина, что и в ПР №2):
//   --loss-percent=N  каждая датаграмма теряется с вероятностью N% НЕЗАВИСИМО
//                     в каждую сторону: входящие пакеты (клиент -> сервер) и
//                     исходящие ACK/PONG (сервер -> клиент). Потеря ACK — это
//                     именно тот случай, когда клиент шлёт копию уже
//                     обработанного пакета.
//   --delay-ms=N, --jitter-min-ms=N, --jitter-max-ms=N
//                     задержка ответов. В отличие от pong_server (ПР №2), ответы
//                     не блокируют приём: они ставятся в очередь с моментом
//                     отправки, поэтому несколько ответов могут быть "в полёте"
//                     одновременно и при джиттере переупорядочиваться.
//
// Использование:
//   reliable_server_app [port=27017] [--delay-ms=N] [--jitter-min-ms=N]
//                       [--jitter-max-ms=N] [--loss-percent=N] [--seed=N]
//                       [--dedup-window=N]

#include "../protocol/protocol.h"
#include "../reliability/dedup_window.hpp"
#include "../telemetry/transport.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <random>
#include <string>
#include <vector>

using namespace std::chrono;

namespace {

std::uint64_t NowUs() {
    return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

struct Args {
    std::uint16_t port = 27017;
    int delayMs = 0;
    int jitterMinMs = 0;
    int jitterMaxMs = 0;
    int lossPercent = 0;
    unsigned long seed = 0;
    bool hasSeed = false;
    int dedupWindow = 1024;
};

bool ParseIntFlag(const std::string& arg, const std::string& name, int& out) {
    const std::string prefix = "--" + name + "=";
    if (arg.rfind(prefix, 0) != 0) return false;
    out = std::atoi(arg.c_str() + prefix.size());
    return true;
}

Args ParseArgs(int argc, char** argv) {
    Args a;
    int argIndex = 1;
    if (argc >= 2 && std::string(argv[1]).rfind("--", 0) != 0) {
        a.port = static_cast<std::uint16_t>(std::atoi(argv[1]));
        argIndex = 2;
    }
    for (int i = argIndex; i < argc; ++i) {
        std::string arg = argv[i];
        int value = 0;
        if (ParseIntFlag(arg, "delay-ms", value)) a.delayMs = value;
        else if (ParseIntFlag(arg, "jitter-min-ms", value)) a.jitterMinMs = value;
        else if (ParseIntFlag(arg, "jitter-max-ms", value)) a.jitterMaxMs = value;
        else if (ParseIntFlag(arg, "loss-percent", value)) a.lossPercent = value;
        else if (ParseIntFlag(arg, "seed", value)) { a.seed = static_cast<unsigned long>(value); a.hasSeed = true; }
        else if (ParseIntFlag(arg, "dedup-window", value)) a.dedupWindow = value > 0 ? value : 1;
        else std::fprintf(stderr, "Неизвестный аргумент проигнорирован: %s\n", arg.c_str());
    }
    return a;
}

// Ответ, ожидающий момента отправки (эмуляция задержки без блокировки приёма).
struct OutgoingReply {
    std::vector<std::uint8_t> bytes;
    sockaddr_in to;
    const char* what; // "ACK" / "PONG" — для лога
    std::uint16_t sequence;
};

} // namespace

int main(int argc, char** argv) {
    enable_utf8_console();
    // Сервер останавливают принудительно (kill / Stop-Process) — без этого при
    // перенаправлении вывода в файл хвост лога остался бы в буфере и потерялся.
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    Args args = ParseArgs(argc, argv);

    std::mt19937 rng(args.hasSeed ? args.seed : std::random_device{}());
    if (!args.hasSeed) {
        args.seed = rng();
        rng.seed(args.seed);
    }
    std::uniform_int_distribution<int> jitterDist(
        std::min(args.jitterMinMs, args.jitterMaxMs), std::max(args.jitterMinMs, args.jitterMaxMs));
    std::uniform_int_distribution<int> lossDist(1, 100);
    auto lostByNetwork = [&] { return args.lossPercent > 0 && lossDist(rng) <= args.lossPercent; };

    telemetry::UdpTransport transport;
    // Короткий тайм-аут приёма (1 мс) — период опроса очереди ответов.
    if (!transport.OpenServer(args.port, /*recvTimeoutMs=*/1)) {
        std::fprintf(stderr, "Не удалось запустить сервер надёжной доставки на порту %d\n", args.port);
        return 1;
    }

    std::printf("Сервер надёжной доставки запущен на порту %d\n", args.port);
    std::printf("Параметры эмуляции: delay=%d мс, jitter=[%d..%d] мс, loss=%d%% в каждую сторону, seed=%lu, "
                "окно дедупликации=%d\n",
                args.delayMs, args.jitterMinMs, args.jitterMaxMs, args.lossPercent, args.seed, args.dedupWindow);

    reliability::DedupWindow dedup(static_cast<std::size_t>(args.dedupWindow));
    std::multimap<std::uint64_t, OutgoingReply> outbox; // ключ — момент отправки, мкс
    unsigned long shootsApplied = 0;
    unsigned long duplicatesIgnored = 0;
    unsigned long movementsApplied = 0;

    // Ставит ответ в очередь с учётом эмуляции потерь (исходящее направление) и задержки.
    auto scheduleReply = [&](std::vector<std::uint8_t> bytes, const sockaddr_in& to, const char* what,
                              std::uint16_t sequence, const std::string& endpoint) {
        if (lostByNetwork()) {
            std::printf("[%s] %s seq=%u потерян по пути к клиенту (эмуляция потерь %d%%)\n",
                        endpoint.c_str(), what, sequence, args.lossPercent);
            return;
        }
        int delayMs = args.delayMs;
        if (args.jitterMaxMs > 0) delayMs += jitterDist(rng);
        outbox.emplace(NowUs() + static_cast<std::uint64_t>(std::max(delayMs, 0)) * 1000ULL,
                       OutgoingReply{std::move(bytes), to, what, sequence});
    };

    auto flushDue = [&] {
        const std::uint64_t now = NowUs();
        while (!outbox.empty() && outbox.begin()->first <= now) {
            OutgoingReply& r = outbox.begin()->second;
            if (!transport.Send(r.bytes.data(), r.bytes.size(), &r.to)) {
                std::printf("Ошибка отправки %s seq=%u\n", r.what, r.sequence);
            }
            outbox.erase(outbox.begin());
        }
    };

    std::uint8_t buf[256];

    for (;;) {
        flushDue();

        std::size_t recvSize = 0;
        sockaddr_in fromAddr{};
        auto result = transport.Receive(buf, sizeof(buf), recvSize, fromAddr);
        if (result != telemetry::RecvResult::Data) {
            continue; // штатный случай: за 1 мс ничего не пришло
        }

        const std::uint64_t serverReceiveTimeUs = NowUs();
        const std::string endpoint = endpoint_to_string(fromAddr);

        auto header = telemetry::ReadHeader(buf, recvSize);
        if (!header) {
            std::printf("[%s] отброшен: некорректный заголовок (%zu байт)\n", endpoint.c_str(), recvSize);
            continue;
        }

        // Потеря входящего пакета: сервер его "не видел" — ни ACK, ни эффекта.
        if (lostByNetwork()) {
            std::printf("[%s] пакет типа %u seq=%u потерян по пути к серверу (эмуляция потерь %d%%)\n",
                        endpoint.c_str(), static_cast<unsigned>(header->packetType),
                        header->sequenceNumber, args.lossPercent);
            continue;
        }

        switch (header->packetType) {
            case telemetry::PacketType::Ping: {
                auto ping = telemetry::ParsePing(buf, recvSize);
                if (!ping) {
                    std::printf("[%s] отброшен: PING не прошёл валидацию\n", endpoint.c_str());
                    break;
                }
                const std::uint64_t sendTimeUs = NowUs();
                scheduleReply(telemetry::SerializePong(ping->sequenceNumber, ping->clientSendTimeUs,
                                                        serverReceiveTimeUs, sendTimeUs),
                              fromAddr, "PONG", ping->sequenceNumber, endpoint);
                break;
            }
            case telemetry::PacketType::Movement: {
                auto move = telemetry::ParseMovement(buf, recvSize);
                if (!move) {
                    std::printf("[%s] отброшен: MOVEMENT не прошёл валидацию\n", endpoint.c_str());
                    break;
                }
                ++movementsApplied;
                std::printf("[%s] MOVEMENT seq=%u x=%u y=%u применён (без подтверждения)\n",
                            endpoint.c_str(), move->sequenceNumber, move->x, move->y);
                if (move->requiresAck) {
                    scheduleReply(telemetry::SerializeAck(move->sequenceNumber, move->sequenceNumber),
                                  fromAddr, "ACK", move->sequenceNumber, endpoint);
                }
                break;
            }
            case telemetry::PacketType::Shoot: {
                auto shoot = telemetry::ParseShoot(buf, recvSize);
                if (!shoot) {
                    std::printf("[%s] отброшен: SHOOT не прошёл валидацию\n", endpoint.c_str());
                    break;
                }
                // 1) ACK — сразу и на КАЖДУЮ копию (в т.ч. на дубликат).
                if (shoot->requiresAck) {
                    scheduleReply(telemetry::SerializeAck(shoot->sequenceNumber, shoot->sequenceNumber),
                                  fromAddr, "ACK", shoot->sequenceNumber, endpoint);
                }
                // 2) Эффект — только для нового sequenceNumber.
                if (dedup.MarkProcessed(shoot->sequenceNumber)) {
                    ++shootsApplied;
                    std::printf("[%s] SHOOT seq=%u угол=%u оружие=%u ПРИМЕНЁН (эффектов всего: %lu)\n",
                                endpoint.c_str(), shoot->sequenceNumber, shoot->aimAngleDeg,
                                static_cast<unsigned>(shoot->weaponId), shootsApplied);
                } else {
                    ++duplicatesIgnored;
                    std::printf("[%s] SHOOT seq=%u — ДУБЛИКАТ, эффект не применён, ACK повторён "
                                "(дубликатов всего: %lu)\n",
                                endpoint.c_str(), shoot->sequenceNumber, duplicatesIgnored);
                }
                break;
            }
            case telemetry::PacketType::Pong:
            case telemetry::PacketType::Ack:
                std::printf("[%s] отброшен: сервер не принимает пакеты типа %u\n",
                            endpoint.c_str(), static_cast<unsigned>(header->packetType));
                break;
        }
    }

    return 0;
}
