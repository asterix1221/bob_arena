// client/secure_client.cpp
// ПР №6: клиент к secure_server_app. 1) handshake X25519 (повтор KEY_EXCHANGE при потере), 2) серия зашифрованных
// MOVEMENT (ненадёжно) и SHOOT (надёжно: ACK, повторная передача по RTO, ПР №3). При повторной передаче пакет
// ЗАПЕЧАТЫВАЕТСЯ заново — новый nonce, тот же sequenceNumber.
// Использование: secure_client_app [ip=127.0.0.1] [port=27019] [--count=5] [--interval-ms=300] [--max-attempts=6]
// Код возврата: 0 — все SHOOT подтверждены, 2 — часть не доставлена, 1 — handshake не удался.
#include "../crypto/secure_channel.h"
#include "../protocol/protocol.h"
#include "../reliability/adaptive_timeout.hpp"
#include "../reliability/reliable_channel.hpp"
#include "../telemetry/transport.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

namespace {
std::uint64_t NowUs() {
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
}

int main(int argc, char** argv) {
    enable_utf8_console();
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::string ip = "127.0.0.1";
    std::uint16_t port = 27019;
    int count = 5, intervalMs = 300, maxAttempts = 6, positional = 0;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        auto num = [&](const char* name, int& out) {
            const std::string pre = std::string("--") + name + "=";
            if (a.rfind(pre, 0) != 0) return false;
            out = std::atoi(a.c_str() + pre.size());
            return true;
        };
        if (a.rfind("--", 0) != 0) {
            if (positional == 0) ip = a; else if (positional == 1) port = static_cast<std::uint16_t>(std::atoi(a.c_str()));
            ++positional;
        } else if (!num("count", count) && !num("interval-ms", intervalMs) && !num("max-attempts", maxAttempts)) {
            std::fprintf(stderr, "Неизвестный аргумент проигнорирован: %s\n", a.c_str());
        }
    }
    if (count < 0) count = 0;
    if (maxAttempts < 1) maxAttempts = 1;

    telemetry::UdpTransport transport;
    if (!transport.OpenClient(ip, port, 5)) { std::fprintf(stderr, "Не удалось открыть сокет до %s:%d\n", ip.c_str(), port); return 1; }

    // ---- handshake ----
    crypto::KeyPair kp = crypto::GenerateKeyPair();
    if (!kp.pkey) { std::fprintf(stderr, "Не удалось сгенерировать ключ\n"); return 1; }
    const auto kx = telemetry::SerializeKeyExchange(0, kp.pub);
    crypto::Session session;
    bool established = false;
    std::uint8_t buf[2048];
    for (int attempt = 1; attempt <= 6 && !established; ++attempt) {
        transport.Send(kx.data(), kx.size());
        const std::uint64_t until = NowUs() + 500000;
        while (NowUs() < until && !established) {
            std::size_t n = 0; sockaddr_in from{};
            if (transport.Receive(buf, sizeof(buf), n, from) != telemetry::RecvResult::Data) continue;
            auto reply = telemetry::ParseKeyExchange(buf, n);
            std::uint8_t key[crypto::KEY_SIZE];
            if (reply && crypto::DeriveSessionKey(kp.pkey, reply->publicKey, key)) {
                session = crypto::Session(key, /*server=*/false);
                established = true;
            }
        }
        if (!established) std::printf("handshake: ответа нет, повтор %d/6\n", attempt);
    }
    crypto::FreeKeyPair(kp);
    if (!established) { std::puts("handshake не удался"); return 1; }
    std::puts("handshake OK: сессионный ключ выведен (X25519 + HKDF-SHA256)");

    // ---- обмен ----
    reliability::ReliableChannel channel(static_cast<std::uint32_t>(maxAttempts));
    reliability::AdaptiveTimeout rto;
    std::uint16_t seq = 1;
    int acked = 0, failed = 0, retransmits = 0, drops = 0;
    std::vector<std::uint16_t> shootSeqs;
    auto sendSealed = [&](const std::vector<std::uint8_t>& inner) {
        auto sealed = crypto::SealPacket(session, inner);
        if (!sealed.empty()) transport.Send(sealed.data(), sealed.size());
    };
    auto pump = [&](std::uint64_t untilUs) {
        while (NowUs() < untilUs) {
            std::size_t n = 0; sockaddr_in from{};
            if (transport.Receive(buf, sizeof(buf), n, from) == telemetry::RecvResult::Data) {
                std::vector<std::uint8_t> inner;
                auto r = crypto::OpenPacket(session, buf, n, inner);
                if (r != crypto::OpenResult::Ok) { ++drops; std::printf("входящий пакет отброшен: %s\n", crypto::ToString(r)); continue; }
                if (auto ack = telemetry::ParseAck(inner.data(), inner.size())) {
                    reliability::AckInfo info;
                    if (channel.OnAckReceived(ack->payload.acknowledgedSequence, NowUs(), info)) {
                        ++acked;
                        if (info.attempts == 1) rto.OnSample(static_cast<double>(info.timeToAckUs) / 1000.0);
                        std::printf("ACK seq=%u получен и расшифрован (попыток: %u, %.1f мс)\n", ack->payload.acknowledgedSequence,
                                    info.attempts, static_cast<double>(info.timeToAckUs) / 1000.0);
                    }
                }
            }
            std::vector<std::uint16_t> newlyFailed;
            for (auto* pk : channel.CollectForRetransmission(NowUs(), rto.RtoUs(), &newlyFailed)) {
                ++retransmits;
                sendSealed(pk->rawBytes);      // новый nonce, тот же seq
                std::printf("повторная передача seq=%u (попытка %u, новый nonce)\n",
                            telemetry::ReadHeader(pk->rawBytes.data(), pk->rawBytes.size())->sequenceNumber, pk->attempts);
            }
            failed += static_cast<int>(newlyFailed.size());
        }
    };
    for (int i = 0; i < count; ++i) {
        sendSealed(telemetry::SerializeMovement(seq++, static_cast<std::uint16_t>(100 + 10 * i), static_cast<std::uint16_t>(200 + 5 * i), false));
        auto shoot = telemetry::SerializeShoot(seq, static_cast<std::uint16_t>(90 + 30 * i), 1, true);
        shootSeqs.push_back(seq++);
        channel.OnSent(shootSeqs.back(), shoot, NowUs());
        sendSealed(shoot);
        std::printf("отправлено: MOVEMENT и SHOOT seq=%u (зашифрованы)\n", shootSeqs.back());
        pump(NowUs() + static_cast<std::uint64_t>(intervalMs) * 1000ULL);
    }
    for (int w = 0; w < 100 && channel.PendingCount() > 0; ++w) pump(NowUs() + 100000);
    std::printf("итог: SHOOT подтверждено %d из %d, повторных передач %d, не доставлено %d, отброшено входящих %d\n",
                acked, count, retransmits, failed + static_cast<int>(channel.PendingCount()), drops);
    return acked == count ? 0 : 2;
}
