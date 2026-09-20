// server/pong_server.cpp
// UDP-сервер подсистемы телеметрии (ПР №2). Отвечает PONG на каждый
// валидный PING, опционально эмулируя задержку/джиттер/потери на своей
// стороне флагами командной строки (см. README.md и docs/Experiment_Config.md
// для объяснения, почему это сделано так — Clumsy доступен только под
// Windows и не может быть запущен в среде, где проверялась и собиралась
// эта работа, поэтому эмуляция сделана явным и воспроизводимым образом
// прямо в сервере — что явно допускается формулировкой задания).
//
// Использование:
//   pong_server_app [port=27016] [--delay-ms=N] [--jitter-min-ms=N]
//                    [--jitter-max-ms=N] [--loss-percent=N] [--seed=N]

#include "../telemetry/protocol.h"
#include "../telemetry/transport.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <thread>

using namespace std::chrono;

namespace {

std::uint64_t NowUs() {
    return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

struct Args {
    std::uint16_t port = 27016;
    int delayMs = 0;
    int jitterMinMs = 0;
    int jitterMaxMs = 0;
    int lossPercent = 0;
    unsigned long seed = 0;
    bool hasSeed = false;
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
        else std::fprintf(stderr, "Неизвестный аргумент проигнорирован: %s\n", arg.c_str());
    }
    return a;
}

} // namespace

int main(int argc, char** argv) {
    enable_utf8_console();

    Args args = ParseArgs(argc, argv);

    std::mt19937 rng(args.hasSeed ? args.seed : std::random_device{}());
    if (!args.hasSeed) {
        // Печатаем сгенерированный seed, чтобы его можно было зафиксировать
        // в docs/Experiment_Config.md для воспроизводимости запуска.
        args.seed = rng();
        rng.seed(args.seed);
    }
    std::uniform_int_distribution<int> jitterDist(
        std::min(args.jitterMinMs, args.jitterMaxMs), std::max(args.jitterMinMs, args.jitterMaxMs));
    std::uniform_int_distribution<int> lossDist(1, 100);

    telemetry::UdpTransport transport;
    if (!transport.OpenServer(args.port)) {
        std::fprintf(stderr, "Не удалось запустить телеметрийный сервер на порту %d\n", args.port);
        return 1;
    }

    std::printf("Телеметрийный PONG-сервер запущен на порту %d\n", args.port);
    std::printf("Параметры эмуляции: delay=%d мс, jitter=[%d..%d] мс, loss=%d%%, seed=%lu\n",
                args.delayMs, args.jitterMinMs, args.jitterMaxMs, args.lossPercent, args.seed);

    std::uint8_t buf[256];

    for (;;) {
        std::size_t recvSize = 0;
        sockaddr_in fromAddr{};
        auto result = transport.Receive(buf, sizeof(buf), recvSize, fromAddr);
        if (result != telemetry::RecvResult::Data) {
            continue; // сервер слушает без тайм-аута, но метод оставлен универсальным
        }

        const std::uint64_t serverReceiveTimeUs = NowUs();
        const std::string endpoint = endpoint_to_string(fromAddr);

        auto header = telemetry::ReadHeader(buf, recvSize);
        if (!header) {
            std::printf("[%s] отброшен: некорректный заголовок (%zu байт)\n", endpoint.c_str(), recvSize);
            continue;
        }
        if (header->packetType != telemetry::PacketType::Ping) {
            std::printf("[%s] отброшен: ожидался PING, получен тип %u\n",
                        endpoint.c_str(), static_cast<unsigned>(header->packetType));
            continue;
        }

        auto ping = telemetry::ParsePing(buf, recvSize);
        if (!ping) {
            std::printf("[%s] отброшен: PING не прошёл валидацию (payloadSize/версия/длина)\n", endpoint.c_str());
            continue;
        }

        if (args.lossPercent > 0 && lossDist(rng) <= args.lossPercent) {
            std::printf("[%s] PING seq=%u намеренно отброшен (эмуляция потерь %d%%)\n",
                        endpoint.c_str(), ping->sequenceNumber, args.lossPercent);
            continue; // не отвечаем вовсе -> клиент зафиксирует timeout
        }

        int sleepMs = args.delayMs;
        if (args.jitterMaxMs > 0) {
            sleepMs += jitterDist(rng);
        }
        if (sleepMs > 0) {
            std::this_thread::sleep_for(milliseconds(sleepMs));
        }

        const std::uint64_t serverSendTimeUs = NowUs();
        auto pongBytes = telemetry::SerializePong(ping->sequenceNumber, ping->clientSendTimeUs,
                                                    serverReceiveTimeUs, serverSendTimeUs);
        if (!transport.Send(pongBytes.data(), pongBytes.size(), &fromAddr)) {
            std::printf("[%s] Ошибка отправки PONG seq=%u\n", endpoint.c_str(), ping->sequenceNumber);
        } else {
            std::printf("[%s] PING seq=%u -> PONG (искусственная задержка %d мс)\n",
                        endpoint.c_str(), ping->sequenceNumber, sleepMs);
        }
    }

    return 0;
}
