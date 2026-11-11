// server/secure_server.cpp
// ПР №6: UDP-сервер с шифрованием. Тот же протокол и тот же надёжный уровень (ACK, дедупликация по sequenceNumber),
// что в reliable_server (ПР №3), но весь обмен после handshake идёт в пакетах ENCRYPTED (AES-256-GCM).
//   KEY_EXCHANGE -> сервер создаёт эфемерную пару X25519, отвечает своим открытым ключом, хранит ключ сессии
//                   в таблице по адресу клиента (у UDP нет соединений, клиентов может быть много);
//   ENCRYPTED    -> расшифровка; при ошибке тега пакет молча отбрасывается и пишется AUTH_FAIL с адресом отправителя;
//   всё остальное (открытые PING/MOVEMENT/SHOOT) -> отбрасывается: после включения шифрования plaintext не принимаем.
// Использование: secure_server_app [port=27019] [--loss-percent=N] [--seed=N] [--max-sessions=N]
#include "../crypto/secure_channel.h"
#include "../protocol/protocol.h"
#include "../reliability/dedup_window.hpp"
#include "../telemetry/transport.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <random>
#include <string>
#include <vector>

namespace {

std::uint64_t NowUs() {
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct Peer {
    crypto::Session session;
    std::uint8_t clientPub[32];
    std::vector<std::uint8_t> reply;       // наш KEY_EXCHANGE: повторяем тот же, если клиент не получил ответ
    reliability::DedupWindow dedup{1024};
    unsigned long shoots = 0, dups = 0, moves = 0;
};

bool FlagInt(const std::string& a, const char* name, int& out) {
    const std::string p = std::string("--") + name + "=";
    if (a.rfind(p, 0) != 0) return false;
    out = std::atoi(a.c_str() + p.size());
    return true;
}

} // namespace

int main(int argc, char** argv) {
    enable_utf8_console();
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::uint16_t port = 27019;
    int lossPercent = 0, maxSessions = 256, seedArg = -1;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        int v = 0;
        if (a.rfind("--", 0) != 0) port = static_cast<std::uint16_t>(std::atoi(a.c_str()));
        else if (FlagInt(a, "loss-percent", v)) lossPercent = v;
        else if (FlagInt(a, "max-sessions", v)) maxSessions = v > 0 ? v : 1;
        else if (FlagInt(a, "seed", v)) seedArg = v;
        else std::fprintf(stderr, "Неизвестный аргумент проигнорирован: %s\n", a.c_str());
    }
    std::mt19937 rng(seedArg >= 0 ? static_cast<unsigned>(seedArg) : std::random_device{}());
    std::uniform_int_distribution<int> pct(1, 100);
    auto lost = [&] { return lossPercent > 0 && pct(rng) <= lossPercent; };

    telemetry::UdpTransport transport;
    if (!transport.OpenServer(port, 0)) {
        std::fprintf(stderr, "Не удалось открыть порт %d\n", port);
        return 1;
    }
    std::printf("Защищённый сервер запущен на UDP %d (X25519 + HKDF-SHA256 + AES-256-GCM), потери=%d%%\n", port, lossPercent);

    std::map<std::string, std::unique_ptr<Peer>> peers;   // ключ — «ip:port» отправителя
    std::uint8_t buf[2048];
    for (;;) {
        std::size_t n = 0;
        sockaddr_in from{};
        if (transport.Receive(buf, sizeof(buf), n, from) != telemetry::RecvResult::Data) continue;
        const std::string who = endpoint_to_string(from);
        if (lost()) { std::printf("[%s] датаграмма потеряна (эмуляция %d%%)\n", who.c_str(), lossPercent); continue; }
        auto h = telemetry::ReadHeader(buf, n);
        if (!h) { std::printf("[%s] отброшен: некорректный заголовок (%zu байт)\n", who.c_str(), n); continue; }

        if (h->packetType == telemetry::PacketType::KeyExchange) {
            auto kx = telemetry::ParseKeyExchange(buf, n);
            if (!kx) { std::printf("[%s] отброшен: KEY_EXCHANGE не прошёл валидацию\n", who.c_str()); continue; }
            auto it = peers.find(who);
            if (it != peers.end()) {
                // Повтор того же ключа (ответ потерялся) — отвечаем тем же. Другой ключ с адреса с живой сессией
                // игнорируем: иначе подделанный пакет сбрасывал бы чужую сессию.
                if (std::equal(kx->publicKey, kx->publicKey + 32, it->second->clientPub)) {
                    if (!lost()) transport.Send(it->second->reply.data(), it->second->reply.size(), &from);
                } else {
                    std::printf("[%s] KEY_EXCHANGE с другим ключом при живой сессии — проигнорирован\n", who.c_str());
                }
                continue;
            }
            if ((int)peers.size() >= maxSessions) { std::printf("[%s] отказ: таблица сессий заполнена (%d)\n", who.c_str(), maxSessions); continue; }
            crypto::KeyPair kp = crypto::GenerateKeyPair();
            std::uint8_t key[crypto::KEY_SIZE];
            if (!kp.pkey || !crypto::DeriveSessionKey(kp.pkey, kx->publicKey, key)) {
                std::printf("[%s] отказ: недопустимый открытый ключ (точка малого порядка?)\n", who.c_str());
                crypto::FreeKeyPair(kp);
                continue;
            }
            auto peer = std::make_unique<Peer>();
            peer->session = crypto::Session(key, /*server=*/true);
            std::copy(kx->publicKey, kx->publicKey + 32, peer->clientPub);
            peer->reply = telemetry::SerializeKeyExchange(0, kp.pub);
            crypto::FreeKeyPair(kp);
            if (!lost()) transport.Send(peer->reply.data(), peer->reply.size(), &from);
            peers[who] = std::move(peer);
            std::printf("[%s] сессия установлена (сессий: %zu)\n", who.c_str(), peers.size());
            continue;
        }

        if (h->packetType != telemetry::PacketType::Encrypted) {
            std::printf("[%s] PLAINTEXT_REJECTED: открытый пакет типа %u после включения шифрования не принимается\n",
                        who.c_str(), static_cast<unsigned>(h->packetType));
            continue;
        }
        auto it = peers.find(who);
        if (it == peers.end()) { std::printf("[%s] отброшен: ENCRYPTED без сессии\n", who.c_str()); continue; }
        Peer& p = *it->second;
        std::vector<std::uint8_t> inner;
        auto r = crypto::OpenPacket(p.session, buf, n, inner);
        if (r == crypto::OpenResult::AuthFail) { std::printf("[%s] AUTH_FAIL seq=%u (тег не сошёлся, пакет отброшен)\n", who.c_str(), h->sequenceNumber); continue; }
        if (r != crypto::OpenResult::Ok) { std::printf("[%s] %s seq=%u (пакет отброшен)\n", who.c_str(), crypto::ToString(r), h->sequenceNumber); continue; }

        auto reply = [&](const std::vector<std::uint8_t>& plainReply) {
            auto sealed = crypto::SealPacket(p.session, plainReply);
            if (!sealed.empty() && !lost()) transport.Send(sealed.data(), sealed.size(), &from);
        };
        auto ih = telemetry::ReadHeader(inner.data(), inner.size());
        switch (ih->packetType) {
            case telemetry::PacketType::Ping: {
                auto ping = telemetry::ParsePing(inner.data(), inner.size());
                if (ping) { const std::uint64_t t = NowUs(); reply(telemetry::SerializePong(ping->sequenceNumber, ping->clientSendTimeUs, t, t)); }
                break;
            }
            case telemetry::PacketType::Movement: {
                auto m = telemetry::ParseMovement(inner.data(), inner.size());
                if (m) { ++p.moves; std::printf("[%s] MOVEMENT seq=%u x=%u y=%u (расшифровано)\n", who.c_str(), m->sequenceNumber, m->x, m->y); }
                break;
            }
            case telemetry::PacketType::Shoot: {
                auto s = telemetry::ParseShoot(inner.data(), inner.size());
                if (!s) break;
                if (s->requiresAck) reply(telemetry::SerializeAck(s->sequenceNumber, s->sequenceNumber));   // ACK на каждую копию, тоже зашифрован
                if (p.dedup.MarkProcessed(s->sequenceNumber)) {
                    ++p.shoots;
                    std::printf("[%s] SHOOT seq=%u угол=%u оружие=%u ПРИМЕНЁН (расшифровано, эффектов: %lu)\n", who.c_str(),
                                s->sequenceNumber, s->aimAngleDeg, static_cast<unsigned>(s->weaponId), p.shoots);
                } else {
                    ++p.dups;
                    std::printf("[%s] SHOOT seq=%u — ДУБЛИКАТ (повторная передача), эффект не применён, ACK повторён\n", who.c_str(), s->sequenceNumber);
                }
                break;
            }
            default:
                std::printf("[%s] отброшен: внутренний тип %u сервером не обрабатывается\n", who.c_str(), static_cast<unsigned>(ih->packetType));
        }
    }
}
