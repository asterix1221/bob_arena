// tests/test_crypto.cpp
// ПР №6: тесты криптомодуля и слоя запечатывания пакетов. Эталонные значения посчитаны НЕЗАВИСИМО (RFC 7748 §6.1 и
// библиотека `cryptography` для Python), чтобы тест не сверял OpenSSL сам с собой.
// Сборка (нужен OpenSSL 3): см. README, раздел «Практическая работа №6».
#include "mini_test.h"
#include "../crypto/crypto.h"
#include "../crypto/secure_channel.h"
#include "../protocol/protocol.h"

#include <cstdlib>
#include <cstring>
#include <set>
#include <string>

using namespace crypto;
using telemetry::PacketType;

namespace {

std::vector<std::uint8_t> FromHex(const std::string& s) {
    std::vector<std::uint8_t> out;
    for (std::size_t i = 0; i + 1 < s.size(); i += 2) out.push_back((std::uint8_t)std::stoi(s.substr(i, 2), nullptr, 16));
    return out;
}

// Пара сессий после «рукопожатия» (клиент и сервер выводят ключ из чужого открытого ключа).
struct Pair {
    Session client, server;
    Pair() {
        KeyPair c = GenerateKeyPair(), s = GenerateKeyPair();
        std::uint8_t kc[KEY_SIZE], ks[KEY_SIZE];
        bool ok = DeriveSessionKey(c.pkey, s.pub, kc) && DeriveSessionKey(s.pkey, c.pub, ks);
        FreeKeyPair(c); FreeKeyPair(s);
        if (!ok) throw mini_test::AssertionFailure{"handshake не удался"};
        client = Session(kc, false);
        server = Session(ks, true);
    }
};

} // namespace

TEST_CASE("X25519: векторы RFC 7748 §6.1 (открытые ключи и общий секрет)") {
    auto a = FromHex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    auto b = FromHex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
    KeyPair ka = KeyPairFromPrivate(a.data()), kb = KeyPairFromPrivate(b.data());
    REQUIRE(ka.pkey && kb.pkey);
    REQUIRE(std::vector<std::uint8_t>(ka.pub, ka.pub + 32) == FromHex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"));
    REQUIRE(std::vector<std::uint8_t>(kb.pub, kb.pub + 32) == FromHex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"));
    std::uint8_t s1[32], s2[32];
    REQUIRE(X25519Shared(ka.pkey, kb.pub, s1));
    REQUIRE(X25519Shared(kb.pkey, ka.pub, s2));
    const auto expect = FromHex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");
    REQUIRE(std::vector<std::uint8_t>(s1, s1 + 32) == expect);
    REQUIRE(std::vector<std::uint8_t>(s2, s2 + 32) == expect);
    FreeKeyPair(ka); FreeKeyPair(kb);
}

TEST_CASE("HKDF-SHA256: ключ сессии совпадает с независимым эталоном (Python cryptography)") {
    auto a = FromHex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    auto b = FromHex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
    KeyPair ka = KeyPairFromPrivate(a.data()), kb = KeyPairFromPrivate(b.data());
    std::uint8_t k1[KEY_SIZE], k2[KEY_SIZE];
    REQUIRE(DeriveSessionKey(ka.pkey, kb.pub, k1));
    REQUIRE(DeriveSessionKey(kb.pkey, ka.pub, k2));
    const auto expect = FromHex("7ccaa77ccb6b91b578683758694a48e8e077b3f5b36b40742a5b722ea77d4f69");
    REQUIRE(std::vector<std::uint8_t>(k1, k1 + 32) == expect);
    REQUIRE(std::memcmp(k1, k2, KEY_SIZE) == 0);
    FreeKeyPair(ka); FreeKeyPair(kb);
}

TEST_CASE("Handshake: случайные эфемерные пары дают одинаковый ключ, разные сессии — разные ключи") {
    std::set<std::string> keys;
    for (int i = 0; i < 20; ++i) {
        KeyPair a = GenerateKeyPair(), b = GenerateKeyPair();
        std::uint8_t k1[KEY_SIZE], k2[KEY_SIZE];
        REQUIRE(DeriveSessionKey(a.pkey, b.pub, k1));
        REQUIRE(DeriveSessionKey(b.pkey, a.pub, k2));
        REQUIRE(std::memcmp(k1, k2, KEY_SIZE) == 0);
        keys.insert(std::string((char*)k1, KEY_SIZE));
        FreeKeyPair(a); FreeKeyPair(b);
    }
    REQUIRE(keys.size() == 20);
}

TEST_CASE("Handshake: «открытый ключ» из нулей (точка малого порядка) отклоняется") {
    KeyPair a = GenerateKeyPair();
    std::uint8_t zero[PUB_SIZE] = {0}, key[KEY_SIZE];
    REQUIRE_FALSE(DeriveSessionKey(a.pkey, zero, key));
    std::uint8_t one[PUB_SIZE] = {1};       // u = 1 — тоже точка малого порядка
    REQUIRE_FALSE(DeriveSessionKey(a.pkey, one, key));
    FreeKeyPair(a);
}

TEST_CASE("AES-256-GCM: известный ответ (эталон Python) и round-trip") {
    const auto key = FromHex("7ccaa77ccb6b91b578683758694a48e8e077b3f5b36b40742a5b722ea77d4f69");
    const auto aad = FromHex("1000010020000200");
    const std::string msg = "MOVE 12.5 0.0 7.3";
    auto pkt = EncryptAES(key.data(), 1, (const std::uint8_t*)msg.data(), (int)msg.size(), aad.data(), (int)aad.size());
    REQUIRE(pkt.size() == NONCE_SIZE + msg.size() + TAG_SIZE);
    // [nonce 12][шифртекст + тег] == nonce || ct||tag из Python AESGCM(key).encrypt(nonce, msg, aad)
    std::vector<std::uint8_t> expect = FromHex("000000000000000000000001");
    auto tail = FromHex("d23e95f89d9e23df9a0da99c4a5256eab02d8ba1c920d107807cdaed78d07587f9");
    // длина эталона: 17 байт шифртекста + 16 тега = 33
    expect.insert(expect.end(), tail.begin(), tail.end());
    REQUIRE(pkt.size() == expect.size());
    REQUIRE(pkt == expect);
    std::vector<std::uint8_t> out;
    REQUIRE(DecryptAES(key.data(), pkt.data(), (int)pkt.size(), aad.data(), (int)aad.size(), out));
    REQUIRE(std::string(out.begin(), out.end()) == msg);
}

TEST_CASE("AES-GCM: пустой открытый текст и пустой AAD") {
    std::uint8_t key[KEY_SIZE] = {7};
    auto pkt = EncryptAES(key, 5, nullptr, 0, nullptr, 0);
    REQUIRE(pkt.size() == NONCE_SIZE + TAG_SIZE);
    std::vector<std::uint8_t> out{1, 2, 3};
    REQUIRE(DecryptAES(key, pkt.data(), (int)pkt.size(), nullptr, 0, out));
    REQUIRE(out.empty());
}

TEST_CASE("AES-GCM: подмена любого байта (nonce, шифртекст, тег), AAD или ключа отклоняется") {
    Pair p;
    const std::uint8_t aad[8] = {16, 0, 1, 0, 40, 0, 2, 0};
    const std::string msg = "SHOOT angle=271 weapon=4";
    auto pkt = EncryptAES(p.client.key, 1, (const std::uint8_t*)msg.data(), (int)msg.size(), aad, 8);
    std::vector<std::uint8_t> out;
    REQUIRE(DecryptAES(p.client.key, pkt.data(), (int)pkt.size(), aad, 8, out));
    for (std::size_t i = 0; i < pkt.size(); ++i) {            // каждый байт: nonce, шифртекст, тег
        auto bad = pkt;
        bad[i] ^= 0x01;
        REQUIRE_FALSE(DecryptAES(p.client.key, bad.data(), (int)bad.size(), aad, 8, out));
        REQUIRE(out.empty());                                  // открытый текст при отказе не выдаётся
    }
    std::uint8_t aad2[8]; std::memcpy(aad2, aad, 8); aad2[2] ^= 1;                 // подмена заголовка
    REQUIRE_FALSE(DecryptAES(p.client.key, pkt.data(), (int)pkt.size(), aad2, 8, out));
    std::uint8_t other[KEY_SIZE]; std::memcpy(other, p.client.key, KEY_SIZE); other[0] ^= 1;   // чужой ключ
    REQUIRE_FALSE(DecryptAES(other, pkt.data(), (int)pkt.size(), aad, 8, out));
    REQUIRE_FALSE(DecryptAES(p.client.key, pkt.data(), (int)pkt.size() - 1, aad, 8, out));    // обрезан
    REQUIRE_FALSE(DecryptAES(p.client.key, pkt.data(), 10, aad, 8, out));                     // короче nonce+tag
}

TEST_CASE("Nonce: счётчик даёт уникальные nonce, направление разводит пространства клиента и сервера") {
    std::uint8_t key[KEY_SIZE] = {1};
    std::set<std::string> nonces;
    for (std::uint64_t c = 1; c <= 5000; ++c) {
        auto a = EncryptAES(key, c, nullptr, 0, nullptr, 0);
        auto b = EncryptAES(key, c | DIRECTION_BIT, nullptr, 0, nullptr, 0);
        nonces.insert(std::string((char*)a.data(), NONCE_SIZE));
        nonces.insert(std::string((char*)b.data(), NONCE_SIZE));
    }
    REQUIRE(nonces.size() == 10000);
    auto pkt = EncryptAES(key, 0x0102030405060708ULL, nullptr, 0, nullptr, 0);
    REQUIRE(pkt[0] == 0 && pkt[3] == 0 && pkt[4] == 1 && pkt[11] == 8);     // big-endian, 4 нулевых байта в начале
    std::uint64_t back = 0;
    REQUIRE(CounterFromNonce(pkt.data(), back));
    REQUIRE(back == 0x0102030405060708ULL);
}

TEST_CASE("ReplayWindow: новые принимаются, копии и слишком старые — нет, перестановка в окне допустима") {
    ReplayWindow w(64);
    REQUIRE(w.WouldAccept(1));
    REQUIRE(w.WouldAccept(1));        // проверка ничего не записывает
    w.Commit(1);
    REQUIRE_FALSE(w.WouldAccept(1));
    w.Commit(5);
    REQUIRE(w.WouldAccept(3));        // опоздавший, но в окне
    w.Commit(3);
    REQUIRE_FALSE(w.WouldAccept(3));
    REQUIRE_FALSE(w.WouldAccept(5));
    REQUIRE(w.WouldAccept(2));
    w.Commit(200);                    // окно уехало вперёд
    REQUIRE_FALSE(w.WouldAccept(100)); // старше окна
    REQUIRE(w.WouldAccept(150));
    REQUIRE_FALSE(w.WouldAccept(200));
}

TEST_CASE("Seal/Open: каждый тип пакета проходит туда-обратно, внутренний пакет восстанавливается побайтно") {
    using namespace telemetry;
    Pair p;
    std::vector<std::vector<std::uint8_t>> packets = {
        SerializePing(1, 123456789ULL), SerializeMovement(2, 1280, 720, true), SerializeShoot(300, 271, 4, true),
        SerializeAck(7, 7), SerializeHello(8, 1, 2, {0xD0, 0x91, 'o', 'b'}), SerializeLeave(9, 1),
    };
    InputCmd c1{-127, 33}, c2{127, 6};
    packets.push_back(SerializeInput(10, 65534, {c1, c2}));
    for (auto& inner : packets) {
        auto sealed = SealPacket(p.client, inner);
        REQUIRE_FALSE(sealed.empty());
        auto h = CheckEncryptedHeader(sealed.data(), sealed.size());
        REQUIRE(h.has_value());
        auto ih = ReadHeader(inner.data(), inner.size());
        REQUIRE(h->sequenceNumber == ih->sequenceNumber);          // seq и requiresAck остались открытыми (ACK/повтор работают)
        REQUIRE(h->requiresAck == ih->requiresAck);
        REQUIRE(sealed.size() == inner.size() + kEncryptedOverhead);
        std::vector<std::uint8_t> back;
        REQUIRE(OpenPacket(p.server, sealed.data(), sealed.size(), back) == OpenResult::Ok);
        REQUIRE(back == inner);
    }
}

TEST_CASE("Seal: открытый текст не просматривается в пакете, а тип внутреннего пакета скрыт") {
    using namespace telemetry;
    Pair p;
    auto inner = SerializeMovement(3, 0x1234, 0x5678, false);
    auto sealed = SealPacket(p.client, inner);
    REQUIRE(sealed[0] == (std::uint8_t)PacketType::Encrypted);      // снаружи — только ENCRYPTED
    bool found = false;
    for (std::size_t i = kHeaderSize; i + 3 < sealed.size(); ++i)
        if (sealed[i] == 0x12 && sealed[i + 1] == 0x34 && sealed[i + 2] == 0x56 && sealed[i + 3] == 0x78) found = true;
    REQUIRE_FALSE(found);
}

TEST_CASE("Open: подмена seq, requiresAck, payloadSize или типа во внешнем заголовке даёт AUTH_FAIL / Malformed") {
    using namespace telemetry;
    Pair p;
    auto sealed = SealPacket(p.client, SerializeShoot(300, 271, 4, true));
    std::vector<std::uint8_t> out;
    {   auto bad = sealed; bad[2] ^= 1;   // seq
        REQUIRE(OpenPacket(p.server, bad.data(), bad.size(), out) == OpenResult::AuthFail); }
    {   auto bad = sealed; bad[7] = 0;    // requiresAck 1 -> 0 (атакующий хочет, чтобы повтор не требовался)
        REQUIRE(OpenPacket(p.server, bad.data(), bad.size(), out) == OpenResult::AuthFail); }
    {   auto bad = sealed; bad[3] ^= 1;   // payloadSize — не совпадёт с длиной датаграммы
        REQUIRE(OpenPacket(p.server, bad.data(), bad.size(), out) == OpenResult::Malformed); }
    {   auto bad = sealed; bad[0] = (std::uint8_t)PacketType::Shoot;   // тип изменён на «не ENCRYPTED»
        REQUIRE(OpenPacket(p.server, bad.data(), bad.size(), out) == OpenResult::Malformed); }
    REQUIRE(OpenPacket(p.server, sealed.data(), sealed.size(), out) == OpenResult::Ok);   // оригинал по-прежнему принимается
    REQUIRE(p.server.authFail == 2);
}

TEST_CASE("Open: подмена одного байта шифртекста (негативный тест из задания) отклоняется, сессия остаётся рабочей") {
    using namespace telemetry;
    Pair p;
    auto first = SealPacket(p.client, SerializeMovement(1, 10, 20, false));
    auto bad = first;
    bad[kHeaderSize + NONCE_SIZE] ^= 0x80;           // первый байт шифртекста
    std::vector<std::uint8_t> out;
    REQUIRE(OpenPacket(p.server, bad.data(), bad.size(), out) == OpenResult::AuthFail);
    REQUIRE(out.empty());
    REQUIRE(OpenPacket(p.server, first.data(), first.size(), out) == OpenResult::Ok);     // подделка не «сожгла» счётчик
    auto next = SealPacket(p.client, SerializeMovement(2, 11, 21, false));
    REQUIRE(OpenPacket(p.server, next.data(), next.size(), out) == OpenResult::Ok);
}

TEST_CASE("Replay: тот же датаграмм второй раз отклоняется, повторная передача (новый nonce) принимается и дедуплицируется по seq") {
    using namespace telemetry;
    Pair p;
    auto inner = SerializeShoot(42, 90, 1, true);
    auto first = SealPacket(p.client, inner);
    auto retransmit = SealPacket(p.client, inner);     // «повторная отправка» того же внутреннего пакета
    REQUIRE(first != retransmit);                       // другой nonce -> другие байты
    REQUIRE(first[kHeaderSize + 11] != retransmit[kHeaderSize + 11]);
    std::vector<std::uint8_t> out;
    REQUIRE(OpenPacket(p.server, first.data(), first.size(), out) == OpenResult::Ok);
    REQUIRE(OpenPacket(p.server, first.data(), first.size(), out) == OpenResult::Replay);   // атака повтором
    REQUIRE(OpenPacket(p.server, retransmit.data(), retransmit.size(), out) == OpenResult::Ok);
    auto ih = ReadHeader(out.data(), out.size());
    REQUIRE(ih->sequenceNumber == 42);                  // тот же seq: уровень надёжной доставки отбросит как дубликат
    REQUIRE(p.server.replayDrops == 1);
}

TEST_CASE("Replay: пакеты в другом порядке принимаются (UDP переставляет), старше окна — нет") {
    using namespace telemetry;
    Pair p;
    std::vector<std::vector<std::uint8_t>> sent;
    for (int i = 0; i < 6; ++i) sent.push_back(SealPacket(p.client, SerializeMovement((std::uint16_t)i, 1, 2, false)));
    std::vector<std::uint8_t> out;
    for (int i : {3, 1, 5, 0, 4, 2}) REQUIRE(OpenPacket(p.server, sent[i].data(), sent[i].size(), out) == OpenResult::Ok);
    for (int i = 0; i < 6; ++i) REQUIRE(OpenPacket(p.server, sent[i].data(), sent[i].size(), out) == OpenResult::Replay);
    auto old = SealPacket(p.client, SerializeMovement(100, 1, 2, false));
    for (int i = 0; i < 2000; ++i) {
        auto s = SealPacket(p.client, SerializeMovement(101, 1, 2, false));
        REQUIRE(OpenPacket(p.server, s.data(), s.size(), out) == OpenResult::Ok);
    }
    REQUIRE(OpenPacket(p.server, old.data(), old.size(), out) == OpenResult::Replay);      // слишком старый
}

TEST_CASE("Направление: своё же эхо и пакет «не в ту сторону» отклоняются; сервер -> клиент работает") {
    using namespace telemetry;
    Pair p;
    std::vector<std::uint8_t> out;
    auto c2s = SealPacket(p.client, SerializeMovement(1, 1, 2, false));
    REQUIRE(OpenPacket(p.client, c2s.data(), c2s.size(), out) == OpenResult::WrongDirection);   // отражение
    auto s2c = SealPacket(p.server, SerializeAck(1, 1));
    REQUIRE(OpenPacket(p.server, s2c.data(), s2c.size(), out) == OpenResult::WrongDirection);
    REQUIRE(OpenPacket(p.client, s2c.data(), s2c.size(), out) == OpenResult::Ok);
    REQUIRE(ReadHeader(out.data(), out.size())->packetType == PacketType::Ack);
}

TEST_CASE("Seal: handshake и ENCRYPTED вкладывать нельзя, мусор и пакет другой сессии не открываются") {
    using namespace telemetry;
    Pair p, other;
    std::uint8_t pub[32] = {9};
    REQUIRE(SealPacket(p.client, SerializeKeyExchange(0, pub)).empty());
    auto sealed = SealPacket(p.client, SerializeMovement(1, 1, 2, false));
    REQUIRE(SealPacket(p.client, sealed).empty());
    std::vector<std::uint8_t> out;
    REQUIRE(OpenPacket(other.server, sealed.data(), sealed.size(), out) == OpenResult::AuthFail);   // чужой ключ
    REQUIRE(SealPacket(p.client, std::vector<std::uint8_t>{1, 2, 3}).empty());
}

TEST_CASE("Open: случайный мусор и обрезанные пакеты не падают и не принимаются (фаззинг 3000 датаграмм)") {
    using namespace telemetry;
    Pair p;
    std::srand(6);
    std::vector<std::uint8_t> out;
    auto real = SealPacket(p.client, SerializeShoot(1, 2, 3, true));
    for (int i = 0; i < 3000; ++i) {
        std::vector<std::uint8_t> junk(std::rand() % 90);
        for (auto& b : junk) b = (std::uint8_t)std::rand();
        if (i % 3 == 0 && !junk.empty()) junk[0] = (std::uint8_t)PacketType::Encrypted;
        REQUIRE(OpenPacket(p.server, junk.data(), junk.size(), out) != OpenResult::Ok);
    }
    for (std::size_t n = 0; n < real.size(); ++n)
        REQUIRE(OpenPacket(p.server, real.data(), n, out) != OpenResult::Ok);
    REQUIRE(OpenPacket(p.server, real.data(), real.size(), out) == OpenResult::Ok);
}

TEST_CASE("KEY_EXCHANGE: сборка/разбор туда-обратно, строгие проверки; типы 15 и 16 известны, 13 и 14 по-прежнему нет") {
    using namespace telemetry;
    std::uint8_t pub[32];
    for (int i = 0; i < 32; ++i) pub[i] = (std::uint8_t)(i * 7 + 1);
    auto bytes = SerializeKeyExchange(0x0102, pub);
    REQUIRE(bytes.size() == kHeaderSize + 32);
    REQUIRE(bytes[0] == 15);
    auto parsed = ParseKeyExchange(bytes.data(), bytes.size());
    REQUIRE(parsed.has_value());
    REQUIRE(parsed->sequenceNumber == 0x0102);
    REQUIRE(std::memcmp(parsed->publicKey, pub, 32) == 0);
    auto b2 = bytes; b2.pop_back();
    REQUIRE_FALSE(ParseKeyExchange(b2.data(), b2.size()).has_value());          // короткий ключ
    auto b3 = bytes; b3.push_back(0);
    REQUIRE_FALSE(ParseKeyExchange(b3.data(), b3.size()).has_value());          // лишний байт
    auto b4 = bytes; b4[7] = 1;
    REQUIRE_FALSE(ParseKeyExchange(b4.data(), b4.size()).has_value());          // requiresAck у KEY_EXCHANGE должен быть 0
    for (std::uint8_t t : {13, 14}) { auto b = bytes; b[0] = t; REQUIRE_FALSE(ReadHeader(b.data(), b.size()).has_value()); }
    for (std::uint8_t t : {15, 16}) { auto b = bytes; b[0] = t; REQUIRE(ReadHeader(b.data(), b.size()).has_value()); }
    auto b5 = bytes; b5[0] = 17;
    REQUIRE_FALSE(ReadHeader(b5.data(), b5.size()).has_value());
}
