// client/ping_client.cpp
// UDP-клиент подсистемы телеметрии (ПР №2). Отправляет серию PING с
// постоянным интервалом, вычисляет RTT/SRTT через telemetry::Telemetry
// и по завершении серии дописывает результаты в общий CSV-журнал
// (docs/latency_samples.csv), используемый для docs/Latency_Report.md.
//
// Использование:
//   ping_client_app <server_ip> <port> <experiment_id> [count] [interval_ms] [csv_path]
// По умолчанию: 127.0.0.1 27016 baseline 50 300 docs/latency_samples.csv
//
// ВАЖНО: это ОТДЕЛЬНЫЙ порт/протокол от игрового клиента ПР №1
// (client/client.cpp, порт 27015) — см. обоснование в telemetry/protocol.h.

#include "../telemetry/protocol.h"
#include "../telemetry/telemetry.h"
#include "../telemetry/transport.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace std::chrono;

namespace {

std::uint64_t NowUs() {
    return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

void FormatOptional(char* buf, size_t bufSize, const std::optional<double>& v, const char* fmt) {
    if (v) {
        std::snprintf(buf, bufSize, fmt, *v);
    } else {
        buf[0] = '\0';
    }
}

bool FileIsEmpty(const std::string& path) {
    std::ifstream in(path, std::ios::ate);
    if (!in.is_open()) return true; // файла ещё нет -> считаем "пустым" (нужен заголовок)
    return in.tellg() == 0;
}

void WriteCsv(const std::string& path, const std::vector<telemetry::Sample>& samples) {
    bool needHeader = FileIsEmpty(path);
    std::FILE* f = std::fopen(path.c_str(), "a");
    if (!f) {
        std::fprintf(stderr, "Не удалось открыть CSV-файл для записи: %s\n", path.c_str());
        return;
    }
    if (needHeader) {
        std::fprintf(f, "experiment_id;sample;sequence;sent_at_ms;rtt_ms;srtt_ms;status\n");
    }
    for (const auto& s : samples) {
        char rttBuf[32];
        char srttBuf[32];
        FormatOptional(rttBuf, sizeof(rttBuf), s.rttMs, "%.2f");
        FormatOptional(srttBuf, sizeof(srttBuf), s.srttMs, "%.2f");
        std::fprintf(f, "%s;%d;%u;%.3f;%s;%s;%s\n",
                     s.seriesId.c_str(), s.sampleIndex, s.sequenceNumber, s.sentAtMs,
                     rttBuf, srttBuf, telemetry::ToString(s.status));
    }
    std::fclose(f);
}

} // namespace

int main(int argc, char** argv) {
    enable_utf8_console();

    const std::string serverIp = argc >= 2 ? argv[1] : "127.0.0.1";
    const std::uint16_t port = argc >= 3 ? static_cast<std::uint16_t>(std::atoi(argv[2])) : 27016;
    const std::string experimentId = argc >= 4 ? argv[3] : "baseline";
    const int count = argc >= 5 ? std::atoi(argv[4]) : 50;
    const int intervalMs = argc >= 6 ? std::atoi(argv[5]) : 300;
    const std::string csvPath = argc >= 7 ? argv[6] : "docs/latency_samples.csv";

    if (count <= 0) {
        std::fprintf(stderr, "count должен быть положительным (получено %d)\n", count);
        return 1;
    }
    if (intervalMs < 200 || intervalMs > 1000) {
        std::fprintf(stderr,
                      "Предупреждение: интервал %d мс вне рекомендованного диапазона 200-1000 мс "
                      "(п. \"Эксперимент\" задания), продолжаю всё равно.\n", intervalMs);
    }

    telemetry::UdpTransport transport;
    // Короткий тайм-аут приёма (20 мс) используется как период опроса цикла,
    // а НЕ как тайм-аут измерения RTT — тайм-аут самого измерения (1000 мс,
    // telemetry::kDefaultTimeoutUs) считает отдельно telemetry::Telemetry.
    if (!transport.OpenClient(serverIp, port, /*recvTimeoutMs=*/20)) {
        std::fprintf(stderr, "Не удалось открыть UDP-клиент до %s:%d\n", serverIp.c_str(), port);
        return 1;
    }

    telemetry::Telemetry tel;
    std::vector<telemetry::Sample> samples(count);

    const auto startInstant = steady_clock::now();
    auto nextSendTime = startInstant;
    bool allSent = false;
    steady_clock::time_point graceDeadline{};
    const auto gracePeriod = milliseconds(3000); // ждём поздние PONG после конца серии

    std::printf("Серия '%s': %d PING на %s:%d, интервал %d мс, тайм-аут измерения %llu мкс\n",
                experimentId.c_str(), count, serverIp.c_str(), port, intervalMs,
                static_cast<unsigned long long>(telemetry::kDefaultTimeoutUs));

    int sentCount = 0;
    std::uint8_t recvBuf[256];

    for (;;) {
        const auto now = steady_clock::now();

        if (!allSent && now >= nextSendTime) {
            const std::uint16_t seq = static_cast<std::uint16_t>(sentCount);
            const std::uint64_t sendUs = NowUs();

            auto bytes = telemetry::SerializePing(seq, sendUs);
            if (!transport.Send(bytes.data(), bytes.size())) {
                std::fprintf(stderr, "[%d] Ошибка отправки PING seq=%u\n", sentCount, seq);
            }
            tel.OnPingSent(seq, sendUs, experimentId);

            telemetry::Sample& s = samples[sentCount];
            s.seriesId = experimentId;
            s.sampleIndex = sentCount + 1;
            s.sequenceNumber = seq;
            s.sentAtMs = duration<double, std::milli>(now - startInstant).count();
            // s.rttMs / s.srttMs остаются пустыми, s.status по умолчанию Timeout —
            // это ровно правильное финальное значение, если PONG так и не придёт.

            std::printf("[%d] PING seq=%u отправлен (t=%.1f мс)\n", sentCount, seq, s.sentAtMs);

            ++sentCount;
            nextSendTime += milliseconds(intervalMs);
            if (sentCount == count) {
                allSent = true;
                graceDeadline = now + gracePeriod;
            }
        }

        std::size_t recvSize = 0;
        sockaddr_in fromAddr{};
        auto recvResult = transport.Receive(recvBuf, sizeof(recvBuf), recvSize, fromAddr);
        if (recvResult == telemetry::RecvResult::Data) {
            const std::uint64_t recvUs = NowUs();
            auto header = telemetry::ReadHeader(recvBuf, recvSize);
            if (!header) {
                std::fprintf(stderr, "Отброшен некорректный пакет от сервера (%zu байт)\n", recvSize);
            } else if (header->packetType != telemetry::PacketType::Pong) {
                std::fprintf(stderr, "Отброшен пакет неожиданного типа (%u), ожидался PONG\n",
                              static_cast<unsigned>(header->packetType));
            } else {
                auto pong = telemetry::ParsePong(recvBuf, recvSize);
                if (!pong) {
                    std::fprintf(stderr, "Отброшен некорректный PONG (%zu байт)\n", recvSize);
                } else {
                    double rttMs = 0.0, srttMs = 0.0;
                    auto status = tel.OnPongReceived(pong->sequenceNumber, recvUs, rttMs, srttMs);

                    if (pong->sequenceNumber < static_cast<std::uint16_t>(count)) {
                        telemetry::Sample& s = samples[pong->sequenceNumber];
                        if (status == telemetry::ResponseStatus::Received) {
                            s.status = status;
                            s.rttMs = rttMs;
                            s.srttMs = srttMs;
                            std::printf("[seq=%u] PONG получен: RTT=%.2f мс, SRTT=%.2f мс\n",
                                        pong->sequenceNumber, rttMs, srttMs);
                        } else if (status == telemetry::ResponseStatus::LateResponse) {
                            s.status = status;
                            s.rttMs = rttMs;
                            std::printf("[seq=%u] PONG пришёл ПОЗЖЕ тайм-аута: RTT=%.2f мс (status=late_response)\n",
                                        pong->sequenceNumber, rttMs);
                        } else if (status == telemetry::ResponseStatus::DuplicateResponse) {
                            std::printf("[seq=%u] Повторный PONG проигнорирован (status=duplicate_response)\n",
                                        pong->sequenceNumber);
                        } else {
                            std::printf("[seq=%u] PONG с неизвестным измерением (status=unknown_response)\n",
                                        pong->sequenceNumber);
                        }
                    } else {
                        std::fprintf(stderr, "PONG seq=%u вне диапазона текущей серии, игнорирую\n",
                                      pong->sequenceNumber);
                    }
                }
            }
        }
        // telemetry::RecvResult::TimedOut — штатный случай (просто нет данных
        // за последние 20 мс), Error трактуется так же (см. transport.cpp).

        tel.ExpireTimeouts(NowUs());

        if (allSent && steady_clock::now() >= graceDeadline) {
            break;
        }
    }

    std::size_t received = 0, timedOut = 0, other = 0;
    for (const auto& s : samples) {
        if (s.status == telemetry::ResponseStatus::Received) ++received;
        else if (s.status == telemetry::ResponseStatus::Timeout) ++timedOut;
        else ++other;
    }
    std::printf("Серия '%s' завершена: отправлено=%d, получено=%zu, тайм-аутов=%zu, прочее=%zu\n",
                experimentId.c_str(), count, received, timedOut, other);

    WriteCsv(csvPath, samples);
    std::printf("Результаты дописаны в %s\n", csvPath.c_str());

    return 0;
}
