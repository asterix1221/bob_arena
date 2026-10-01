// client/reliable_client.cpp
// UDP-клиент надёжной доставки (ПР №3). Отправляет серию надёжных команд
// SHOOT (requiresAck = 1) с постоянным интервалом и параллельно — PING для
// измерения RTT (ПР №2). Логика разнесена по модулям:
//   protocol/        — сериализация/разбор пакетов;
//   reliability/     — ReliableChannel (учёт неподтверждённых пакетов),
//                      AdaptiveTimeout (RTO по SRTT/RTTVAR);
//   telemetry/       — Telemetry (RTT по PING/PONG), UdpTransport (сокет).
// Этот файл — только "клеевой" игровой цикл: читает сокет, отдаёт пакеты
// модулям и повторно отправляет то, что просит ReliableChannel.
//
// В одном потоке sequenceNumber у клиента общий счётчик для всех типов
// пакетов (PING и SHOOT получают разные номера), поэтому номера никогда не
// пересекаются между учётом PING (Telemetry) и SHOOT (ReliableChannel).
//
// Использование:
//   reliable_client_app <server_ip> <port> <experiment_id> [count] [interval_ms] [csv_path]
//                       [--rto-csv=path] [--max-attempts=N] [--fixed-rto-ms=N]
//                       [--ping-interval-ms=N]
// По умолчанию: 127.0.0.1 27017 baseline 100 100 docs/reliability_samples.csv
// --fixed-rto-ms=N  вместо адаптивного RTO использовать постоянный (для сравнения
//                   с фиксированным тайм-аутом из ПР №2; RTT-сэмплы всё равно
//                   считаются и пишутся в журнал RTO).

#include "../protocol/protocol.h"
#include "../reliability/adaptive_timeout.hpp"
#include "../reliability/reliable_channel.hpp"
#include "../telemetry/telemetry.h"
#include "../telemetry/transport.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <unordered_map>
#include <vector>

using namespace std::chrono;

namespace {

std::uint64_t NowUs() {
    return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

enum class CommandStatus { Pending, Acked, Failed };

// Итог по одной надёжной команде — строка журнала docs/reliability_samples.csv.
struct CommandRecord {
    int index = 0;                 // порядковый номер команды в серии (1..N)
    std::uint16_t sequence = 0;
    double firstSentAtMs = 0.0;    // относительно начала серии
    std::uint32_t attempts = 1;
    double timeToAckMs = -1.0;     // от первой отправки до ACK; <0 — ACK не получен
    double rtoAtResolveMs = 0.0;   // RTO на момент подтверждения/признания недоставленной
    CommandStatus status = CommandStatus::Pending;
};

// Точка временного ряда RTO (docs/rto_timeline.csv).
struct RtoPoint {
    double tMs;
    const char* source; // "ping" / "ack"
    double rttMs;
    double srttMs;
    double rttVarMs;
    double rtoMs;
};

struct Options {
    std::string serverIp = "127.0.0.1";
    std::uint16_t port = 27017;
    std::string series = "baseline";
    int count = 100;
    int intervalMs = 100;
    std::string csvPath = "docs/reliability_samples.csv";
    std::string rtoCsvPath = "docs/rto_timeline.csv";
    std::uint32_t maxAttempts = 5;
    int fixedRtoMs = 0;       // 0 — адаптивный RTO
    int pingIntervalMs = 200;
};

bool ParseIntFlag(const std::string& arg, const std::string& name, int& out) {
    const std::string prefix = "--" + name + "=";
    if (arg.rfind(prefix, 0) != 0) return false;
    out = std::atoi(arg.c_str() + prefix.size());
    return true;
}

Options ParseOptions(int argc, char** argv) {
    Options o;
    std::vector<std::string> positional;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        int value = 0;
        if (arg.rfind("--rto-csv=", 0) == 0) o.rtoCsvPath = arg.substr(10);
        else if (ParseIntFlag(arg, "max-attempts", value)) o.maxAttempts = value > 0 ? static_cast<std::uint32_t>(value) : 1;
        else if (ParseIntFlag(arg, "fixed-rto-ms", value)) o.fixedRtoMs = value;
        else if (ParseIntFlag(arg, "ping-interval-ms", value)) o.pingIntervalMs = value > 0 ? value : 200;
        else if (arg.rfind("--", 0) == 0) std::fprintf(stderr, "Неизвестный аргумент проигнорирован: %s\n", arg.c_str());
        else positional.push_back(arg);
    }
    if (positional.size() >= 1) o.serverIp = positional[0];
    if (positional.size() >= 2) o.port = static_cast<std::uint16_t>(std::atoi(positional[1].c_str()));
    if (positional.size() >= 3) o.series = positional[2];
    if (positional.size() >= 4) o.count = std::atoi(positional[3].c_str());
    if (positional.size() >= 5) o.intervalMs = std::atoi(positional[4].c_str());
    if (positional.size() >= 6) o.csvPath = positional[5];
    return o;
}

bool FileIsEmpty(const std::string& path) {
    std::ifstream in(path, std::ios::ate);
    if (!in.is_open()) return true; // файла ещё нет -> нужен заголовок
    return in.tellg() == 0;
}

const char* ToString(CommandStatus s) {
    switch (s) {
        case CommandStatus::Acked:   return "acked";
        case CommandStatus::Failed:  return "failed";
        case CommandStatus::Pending: return "pending";
    }
    return "pending";
}

void WriteSamplesCsv(const std::string& path, const std::string& series, const std::vector<CommandRecord>& records) {
    const bool needHeader = FileIsEmpty(path);
    std::FILE* f = std::fopen(path.c_str(), "a");
    if (!f) {
        std::fprintf(stderr, "Не удалось открыть CSV-файл для записи: %s\n", path.c_str());
        return;
    }
    if (needHeader) {
        std::fprintf(f, "experiment_id;command;sequence;sent_at_ms;attempts;time_to_ack_ms;rto_ms;status\n");
    }
    for (const auto& r : records) {
        char ackBuf[32] = "";
        if (r.timeToAckMs >= 0.0) std::snprintf(ackBuf, sizeof(ackBuf), "%.2f", r.timeToAckMs);
        std::fprintf(f, "%s;%d;%u;%.3f;%u;%s;%.2f;%s\n", series.c_str(), r.index, r.sequence,
                     r.firstSentAtMs, r.attempts, ackBuf, r.rtoAtResolveMs, ToString(r.status));
    }
    std::fclose(f);
}

void WriteRtoCsv(const std::string& path, const std::string& series, const std::vector<RtoPoint>& points) {
    const bool needHeader = FileIsEmpty(path);
    std::FILE* f = std::fopen(path.c_str(), "a");
    if (!f) {
        std::fprintf(stderr, "Не удалось открыть CSV-файл для записи: %s\n", path.c_str());
        return;
    }
    if (needHeader) {
        std::fprintf(f, "experiment_id;t_ms;source;rtt_ms;srtt_ms;rttvar_ms;rto_ms\n");
    }
    for (const auto& p : points) {
        std::fprintf(f, "%s;%.3f;%s;%.2f;%.2f;%.2f;%.2f\n", series.c_str(), p.tMs, p.source, p.rttMs,
                     p.srttMs, p.rttVarMs, p.rtoMs);
    }
    std::fclose(f);
}

} // namespace

int main(int argc, char** argv) {
    enable_utf8_console();

    const Options opt = ParseOptions(argc, argv);
    if (opt.count <= 0 || opt.intervalMs <= 0) {
        std::fprintf(stderr, "count и interval_ms должны быть положительными\n");
        return 1;
    }

    telemetry::UdpTransport transport;
    // Короткий тайм-аут приёма (2 мс) — "такт" игрового цикла, а не RTO.
    if (!transport.OpenClient(opt.serverIp, opt.port, /*recvTimeoutMs=*/2)) {
        std::fprintf(stderr, "Не удалось открыть UDP-клиент до %s:%d\n", opt.serverIp.c_str(), opt.port);
        return 1;
    }

    reliability::ReliableChannel channel(opt.maxAttempts);
    reliability::AdaptiveTimeout adaptiveRto;
    telemetry::Telemetry tel; // RTT по PING/PONG (ПР №2)

    std::vector<CommandRecord> records;
    records.reserve(static_cast<std::size_t>(opt.count));
    std::unordered_map<std::uint16_t, std::size_t> recordBySeq;
    std::vector<RtoPoint> rtoTimeline;

    const auto startInstant = steady_clock::now();
    auto elapsedMs = [&] { return duration<double, std::milli>(steady_clock::now() - startInstant).count(); };
    auto currentRtoUs = [&]() -> std::uint64_t {
        return opt.fixedRtoMs > 0 ? static_cast<std::uint64_t>(opt.fixedRtoMs) * 1000ULL : adaptiveRto.RtoUs();
    };
    auto currentRtoMs = [&] { return static_cast<double>(currentRtoUs()) / 1000.0; };
    auto addRtoSample = [&](const char* source, double rttMs) {
        adaptiveRto.OnSample(rttMs);
        rtoTimeline.push_back({elapsedMs(), source, rttMs, adaptiveRto.SrttMs(), adaptiveRto.RttVarMs(),
                               adaptiveRto.RtoMs()});
    };

    std::printf("Серия '%s': %d надёжных SHOOT на %s:%d, интервал %d мс, maxAttempts=%u, RTO: %s\n",
                opt.series.c_str(), opt.count, opt.serverIp.c_str(), opt.port, opt.intervalMs, opt.maxAttempts,
                opt.fixedRtoMs > 0 ? ("фиксированный " + std::to_string(opt.fixedRtoMs) + " мс").c_str() : "адаптивный");

    std::uint16_t nextSeq = 0;
    int sentCommands = 0;
    unsigned long retransmissions = 0;
    unsigned long duplicateAcks = 0;
    auto nextShootTime = startInstant;
    auto nextPingTime = startInstant;
    std::uint8_t recvBuf[256];

    for (;;) {
        const auto now = steady_clock::now();
        const std::uint64_t nowUs = NowUs();

        // --- Новая надёжная команда SHOOT ---
        if (sentCommands < opt.count && now >= nextShootTime) {
            const std::uint16_t seq = nextSeq++;
            const auto raw = telemetry::SerializeShoot(seq, static_cast<std::uint16_t>((sentCommands * 37) % 360),
                                                        /*weaponId=*/1, /*requiresAck=*/true);
            if (!transport.Send(raw.data(), raw.size())) {
                std::fprintf(stderr, "[SHOOT seq=%u] ошибка отправки\n", seq);
            }
            channel.OnSent(seq, raw, nowUs);

            CommandRecord rec;
            rec.index = sentCommands + 1;
            rec.sequence = seq;
            rec.firstSentAtMs = duration<double, std::milli>(now - startInstant).count();
            recordBySeq[seq] = records.size();
            records.push_back(rec);

            std::printf("[%d] SHOOT seq=%u отправлен (t=%.1f мс, RTO=%.1f мс)\n", rec.index, seq,
                        rec.firstSentAtMs, currentRtoMs());
            ++sentCommands;
            nextShootTime += milliseconds(opt.intervalMs);
        }

        // --- PING для измерения RTT (пока серия не закончилась) ---
        if ((sentCommands < opt.count || channel.PendingCount() > 0) && now >= nextPingTime) {
            const std::uint16_t seq = nextSeq++;
            const auto bytes = telemetry::SerializePing(seq, nowUs);
            transport.Send(bytes.data(), bytes.size());
            tel.OnPingSent(seq, nowUs, opt.series);
            nextPingTime += milliseconds(opt.pingIntervalMs);
        }

        // --- Приём: PONG (RTT) или ACK (подтверждение надёжной команды) ---
        std::size_t recvSize = 0;
        sockaddr_in fromAddr{};
        if (transport.Receive(recvBuf, sizeof(recvBuf), recvSize, fromAddr) == telemetry::RecvResult::Data) {
            const std::uint64_t recvUs = NowUs();
            auto header = telemetry::ReadHeader(recvBuf, recvSize);
            if (!header) {
                std::fprintf(stderr, "Отброшен некорректный пакет от сервера (%zu байт)\n", recvSize);
            } else if (header->packetType == telemetry::PacketType::Pong) {
                auto pong = telemetry::ParsePong(recvBuf, recvSize);
                if (pong) {
                    double rttMs = 0.0, srttMs = 0.0;
                    if (tel.OnPongReceived(pong->sequenceNumber, recvUs, rttMs, srttMs) ==
                        telemetry::ResponseStatus::Received) {
                        addRtoSample("ping", rttMs);
                    }
                }
            } else if (header->packetType == telemetry::PacketType::Ack) {
                auto ack = telemetry::ParseAck(recvBuf, recvSize);
                if (!ack) {
                    std::fprintf(stderr, "Отброшен некорректный ACK (%zu байт)\n", recvSize);
                } else {
                    const std::uint16_t acked = ack->payload.acknowledgedSequence;
                    reliability::AckInfo info;
                    if (channel.OnAckReceived(acked, recvUs, info)) {
                        CommandRecord& rec = records[recordBySeq[acked]];
                        rec.status = CommandStatus::Acked;
                        rec.attempts = info.attempts;
                        rec.timeToAckMs = static_cast<double>(info.timeToAckUs) / 1000.0;
                        // Правило Карелса: сэмпл RTT только для пакетов с первой попытки.
                        if (info.attempts == 1) addRtoSample("ack", rec.timeToAckMs);
                        rec.rtoAtResolveMs = currentRtoMs();
                        std::printf("[seq=%u] ACK получен: попыток=%u, время до ACK=%.2f мс, RTO=%.1f мс\n",
                                    acked, info.attempts, rec.timeToAckMs, rec.rtoAtResolveMs);
                    } else {
                        ++duplicateAcks;
                        std::printf("[seq=%u] повторный/неизвестный ACK проигнорирован\n", acked);
                    }
                }
            } else {
                std::fprintf(stderr, "Отброшен пакет неожиданного типа (%u)\n",
                             static_cast<unsigned>(header->packetType));
            }
        }

        // --- Таймеры: тайм-ауты PING и повторная отправка надёжных пакетов ---
        tel.ExpireTimeouts(NowUs());

        std::vector<std::uint16_t> failedNow;
        for (reliability::PendingPacket* p : channel.CollectForRetransmission(NowUs(), currentRtoUs(), &failedNow)) {
            transport.Send(p->rawBytes.data(), p->rawBytes.size());
            ++retransmissions;
            // sequenceNumber лежит в байтах 1-2 сериализованного пакета (заголовок, big-endian).
            const std::uint16_t seq = static_cast<std::uint16_t>((p->rawBytes[1] << 8) | p->rawBytes[2]);
            records[recordBySeq[seq]].attempts = p->attempts;
            std::printf("[seq=%u] RTO=%.1f мс истёк — повторная отправка (попытка %u из %u)\n", seq,
                        currentRtoMs(), p->attempts, opt.maxAttempts);
        }
        for (std::uint16_t seq : failedNow) {
            CommandRecord& rec = records[recordBySeq[seq]];
            rec.status = CommandStatus::Failed;
            rec.attempts = opt.maxAttempts;
            rec.rtoAtResolveMs = currentRtoMs();
            // Событие уровня приложения: в реальной игре выстрел не засчитан сервером.
            std::printf("[seq=%u] ОКОНЧАТЕЛЬНАЯ НЕДОСТАВКА: выстрел не подтверждён сервером после %u попыток\n",
                        seq, opt.maxAttempts);
        }

        if (sentCommands == opt.count && channel.PendingCount() == 0) break;
    }

    // --- Итоги серии ---
    int acked = 0, failed = 0, firstAttempt = 0;
    double attemptsSum = 0.0, ackTimeSum = 0.0;
    for (const auto& r : records) {
        attemptsSum += r.attempts;
        if (r.status == CommandStatus::Acked) {
            ++acked;
            ackTimeSum += r.timeToAckMs;
            if (r.attempts == 1) ++firstAttempt;
        } else if (r.status == CommandStatus::Failed) {
            ++failed;
        }
    }
    std::printf("Серия '%s' завершена: команд=%d, подтверждено=%d (с 1-й попытки: %d), недоставлено=%d, "
                "повторных отправок=%lu, повторных ACK=%lu, среднее число попыток=%.3f, "
                "среднее время до ACK=%.2f мс, итоговый RTO=%.1f мс (SRTT=%.1f мс, RTTVAR=%.1f мс)\n",
                opt.series.c_str(), opt.count, acked, firstAttempt, failed, retransmissions, duplicateAcks,
                attemptsSum / opt.count, acked > 0 ? ackTimeSum / acked : 0.0, currentRtoMs(),
                adaptiveRto.SrttMs(), adaptiveRto.RttVarMs());

    WriteSamplesCsv(opt.csvPath, opt.series, records);
    WriteRtoCsv(opt.rtoCsvPath, opt.series, rtoTimeline);
    std::printf("Результаты дописаны в %s и %s\n", opt.csvPath.c_str(), opt.rtoCsvPath.c_str());
    return 0;
}
