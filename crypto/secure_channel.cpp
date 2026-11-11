// crypto/secure_channel.cpp — реализация, см. secure_channel.h
#include "secure_channel.h"

#include <openssl/crypto.h>

namespace crypto {

using namespace telemetry;

bool ReplayWindow::WouldAccept(std::uint64_t c) const {
    if (!any_ || c > highest_) return true;
    if (highest_ - c >= ring_.size()) return false;           // старше окна
    return ring_[c % ring_.size()] != c;                       // в окне: принять, если такого счётчика ещё не было
}

void ReplayWindow::Commit(std::uint64_t c) {
    if (!any_ || c > highest_) { highest_ = c; any_ = true; }
    ring_[c % ring_.size()] = c;
}

const char* ToString(OpenResult r) {
    switch (r) {
        case OpenResult::Ok: return "OK";
        case OpenResult::Malformed: return "MALFORMED";
        case OpenResult::WrongDirection: return "WRONG_DIRECTION";
        case OpenResult::Replay: return "REPLAY";
        case OpenResult::AuthFail: return "AUTH_FAIL";
    }
    return "?";
}

Session::~Session() { OPENSSL_cleanse(key, sizeof(key)); }

std::vector<std::uint8_t> SealPacket(Session& s, const std::uint8_t* inner, std::size_t innerSize) {
    auto h = ReadHeader(inner, innerSize);
    if (!h || innerSize != kHeaderSize + h->payloadSize) return {};
    if (h->packetType == PacketType::KeyExchange || h->packetType == PacketType::Encrypted) return {};

    // открытый текст: тип внутреннего пакета + его payload (остальные поля заголовка восстановятся из внешнего)
    std::vector<std::uint8_t> plain;
    plain.reserve(1 + h->payloadSize);
    plain.push_back(static_cast<std::uint8_t>(h->packetType));
    plain.insert(plain.end(), inner + kHeaderSize, inner + innerSize);

    const std::size_t sealedSize = NONCE_SIZE + plain.size() + TAG_SIZE;
    if (sealedSize > 0xFFFF) return {};

    // Заголовок строим ДО шифрования с окончательным payloadSize: он идёт в AAD и должен совпасть с тем, что уйдёт в сеть.
    std::vector<std::uint8_t> header = SerializeEncryptedHeader(h->sequenceNumber, h->requiresAck, sealedSize);
    const std::uint64_t counter = (s.isServer ? DIRECTION_BIT : 0) | (++s.sendCounter);
    std::vector<std::uint8_t> sealed = EncryptAES(s.key, counter, plain.data(), (int)plain.size(),
                                                  header.data(), (int)header.size());
    if (sealed.size() != sealedSize) return {};

    header.insert(header.end(), sealed.begin(), sealed.end());
    ++s.sealed;
    return header;
}

OpenResult OpenPacket(Session& s, const std::uint8_t* data, std::size_t size, std::vector<std::uint8_t>& outInner) {
    auto h = CheckEncryptedHeader(data, size);
    if (!h) { ++s.malformed; return OpenResult::Malformed; }

    const std::uint8_t* sealed = data + kHeaderSize;
    std::uint64_t counter = 0;
    if (!CounterFromNonce(sealed, counter)) { ++s.malformed; return OpenResult::Malformed; }
    // Пакет должен идти В нашу сторону: счётчик собеседника имеет бит направления, противоположный нашему.
    const bool fromServer = (counter & DIRECTION_BIT) != 0;
    if (fromServer == s.isServer) { ++s.malformed; return OpenResult::WrongDirection; }
    const std::uint64_t n = counter & ~DIRECTION_BIT;
    if (!s.replay.WouldAccept(n)) { ++s.replayDrops; return OpenResult::Replay; }

    std::vector<std::uint8_t> plain;
    if (!DecryptAES(s.key, sealed, (int)h->payloadSize, data, (int)kHeaderSize, plain)) {
        ++s.authFail;
        return OpenResult::AuthFail;
    }
    s.replay.Commit(n);   // записываем только после успешной проверки тега
    if (plain.empty()) { ++s.malformed; return OpenResult::Malformed; }

    // Восстанавливаем внутренний пакет: тип — из шифртекста, остальные поля — из (аутентифицированного) заголовка.
    std::vector<std::uint8_t> inner;
    inner.reserve(kHeaderSize + plain.size() - 1);
    WriteU8(inner, plain[0]);
    WriteU16(inner, h->sequenceNumber);
    WriteU16(inner, static_cast<std::uint16_t>(plain.size() - 1));
    WriteU16(inner, h->protocolVersion);
    WriteU8(inner, h->requiresAck ? 1 : 0);
    inner.insert(inner.end(), plain.begin() + 1, plain.end());

    auto ih = ReadHeader(inner.data(), inner.size());
    if (!ih || ih->packetType == PacketType::KeyExchange || ih->packetType == PacketType::Encrypted) {
        ++s.malformed;
        return OpenResult::Malformed;
    }
    ++s.opened;
    outInner = std::move(inner);
    return OpenResult::Ok;
}

} // namespace crypto
