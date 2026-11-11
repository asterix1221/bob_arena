// tools/gen_crypto_vectors.cpp
// Генерирует godot/tests/crypto_vectors.json: эталонные байты криптографии и зашифрованных пакетов из C++-реализации
// (OpenSSL). Тесты GDScript (godot/tests/run_crypto_tests.gd) сверяют свою реализацию X25519/HKDF/AES-GCM с этим файлом.
// Закрытые ключи фиксированы — результат детерминирован. Сборка и запуск (из корня репозитория, нужен OpenSSL 3):
//   g++ -std=c++17 protocol/protocol.cpp crypto/crypto.cpp crypto/secure_channel.cpp tools/gen_crypto_vectors.cpp -lcrypto -o gen_crypto
//   ./gen_crypto > godot/tests/crypto_vectors.json
#include "../crypto/secure_channel.h"
#include "../protocol/protocol.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace crypto;
using namespace telemetry;

static std::string Hex(const std::uint8_t* b, std::size_t n) {
    std::string s; char t[3];
    for (std::size_t i = 0; i < n; ++i) { std::snprintf(t, sizeof t, "%02x", b[i]); s += t; }
    return s;
}
static std::string Hex(const std::vector<std::uint8_t>& v) { return Hex(v.data(), v.size()); }

int main() {
    std::uint8_t privA[32], privB[32];
    for (int i = 0; i < 32; ++i) { privA[i] = (std::uint8_t)(i * 5 + 3); privB[i] = (std::uint8_t)(250 - i * 3); }
    KeyPair a = KeyPairFromPrivate(privA), b = KeyPairFromPrivate(privB);
    std::uint8_t shared[32], kA[32];
    X25519Shared(a.pkey, b.pub, shared);
    DeriveSessionKey(a.pkey, b.pub, kA);

    std::printf("{\n  \"x25519\": {\"priv_a\": \"%s\", \"priv_b\": \"%s\", \"pub_a\": \"%s\", \"pub_b\": \"%s\", \"shared\": \"%s\", \"session_key\": \"%s\"},\n",
                Hex(privA, 32).c_str(), Hex(privB, 32).c_str(), Hex(a.pub, 32).c_str(), Hex(b.pub, 32).c_str(),
                Hex(shared, 32).c_str(), Hex(kA, 32).c_str());

    // AES-GCM: разные длины открытого текста (граничные для блоков 16 байт) и AAD
    std::printf("  \"gcm\": [\n");
    const int lens[] = {0, 1, 15, 16, 17, 31, 32, 33, 64, 100};
    bool first = true;
    for (int L : lens) {
        std::vector<std::uint8_t> plain(L), aad(8);
        for (int i = 0; i < L; ++i) plain[i] = (std::uint8_t)(i * 11 + L);
        for (int i = 0; i < 8; ++i) aad[i] = (std::uint8_t)(0x10 + i);
        std::uint64_t counter = 1000 + L;
        auto pkt = EncryptAES(kA, counter, plain.data(), L, aad.data(), 8);
        std::printf("%s    {\"counter\": \"%llu\", \"aad\": \"%s\", \"plain\": \"%s\", \"packet\": \"%s\"}", first ? "" : ",\n",
                    (unsigned long long)counter, Hex(aad).c_str(), Hex(plain).c_str(), Hex(pkt).c_str());
        first = false;
    }
    std::printf("\n  ],\n");

    // запечатанные пакеты протокола: клиент шлёт 3 пакета, сервер — 2 (счётчики детерминированы)
    Session client(kA, false), server(kA, true);
    std::vector<std::vector<std::uint8_t>> c2s = {
        SerializeHello(1, 1, 2, {0xD0, 0x91, 'o', 'b'}),
        SerializeShoot(300, 271, 4, true),
        SerializeInput(10, 65534, {{-127, 33}, {127, 6}}),
    };
    std::vector<std::vector<std::uint8_t>> s2c = { SerializeAck(1, 1), SerializePong(5, 1000, 2000, 3000) };
    std::printf("  \"sealed\": [\n");
    first = true;
    for (auto& in : c2s) {
        auto out = SealPacket(client, in);
        std::printf("%s    {\"from\": \"client\", \"inner\": \"%s\", \"datagram\": \"%s\"}", first ? "" : ",\n", Hex(in).c_str(), Hex(out).c_str());
        first = false;
    }
    for (auto& in : s2c) {
        auto out = SealPacket(server, in);
        std::printf(",\n    {\"from\": \"server\", \"inner\": \"%s\", \"datagram\": \"%s\"}", Hex(in).c_str(), Hex(out).c_str());
    }
    std::printf("\n  ],\n");
    std::printf("  \"key_exchange\": {\"seq\": 258, \"pub\": \"%s\", \"datagram\": \"%s\"}\n}\n",
                Hex(a.pub, 32).c_str(), Hex(SerializeKeyExchange(258, a.pub)).c_str());
    FreeKeyPair(a); FreeKeyPair(b);
}
