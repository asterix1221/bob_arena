// crypto/crypto.h
//
// ПР №6: криптомодуль UDP-протокола — обмен ключами X25519, вывод ключа HKDF-SHA256, шифрование AES-256-GCM.
// Модуль ничего не знает о формате пакетов игры (он в protocol/protocol.h и crypto/secure_channel.h), поэтому
// собирается и проверяется отдельно: g++ -std=c++17 crypto/crypto.cpp tests/crypto_selftest.cpp -lcrypto
// Нужен OpenSSL 3 (на Windows: MSYS2 `pacman -S mingw-w64-ucrt-x86_64-openssl`, см. README).
//
// Отличия от учебного каркаса из «материалов ПР №6» (подробно — docs/Security.md, раздел 8):
//   * счётчик пакета кладётся в nonce в сетевом порядке байт (big-endian), а не memcpy «как лежит в памяти»:
//     nonce всё равно передаётся в пакете целиком, но приёмник читает из него счётчик для защиты от повтора;
//   * добавлены KeyPairFromPrivate (детерминированные ключи для тестовых векторов) и X25519Shared (общий секрет
//     отдельно, чтобы сверять промежуточные значения с реализацией на GDScript);
//   * секреты затираются OPENSSL_cleanse, каждая ошибка OpenSSL приводит к отказу (пустой результат / false).
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include <openssl/evp.h>

namespace crypto {

constexpr int KEY_SIZE   = 32;  // AES-256
constexpr int PUB_SIZE   = 32;  // открытый ключ X25519
constexpr int NONCE_SIZE = 12;  // GCM: 4 байта нулей + 8 байт счётчика (big-endian)
constexpr int TAG_SIZE   = 16;

// Старший бит 64-битного счётчика — направление: 0 = клиент -> сервер, 1 = сервер -> клиент.
// Ключ сессии общий для обоих направлений, поэтому именно это разводит пространства nonce
// и гарантирует, что пара «ключ + nonce» не повторится ни при каких обстоятельствах.
constexpr uint64_t DIRECTION_BIT = 1ULL << 63;

struct KeyPair {
    EVP_PKEY* pkey = nullptr;
    uint8_t   pub[PUB_SIZE] = {0};
};

// Эфемерная пара ключей X25519 (открытая часть уходит в пакете KEY_EXCHANGE). pkey == nullptr при ошибке.
KeyPair GenerateKeyPair();
// Пара из заданного закрытого ключа (для тестовых векторов; в игре не используется).
KeyPair KeyPairFromPrivate(const uint8_t priv[32]);
void    FreeKeyPair(KeyPair& kp);

// Общий секрет X25519. Возвращает false, если OpenSSL отказал — в том числе для точек малого порядка
// (результат из одних нулей): такой «открытый ключ» присылает только атакующий.
bool X25519Shared(EVP_PKEY* mine, const uint8_t peerPub[PUB_SIZE], uint8_t outSecret[32]);

// Общий секрет (X25519) -> сессионный ключ 32 байта (HKDF-SHA256, info = "game-udp-v1", соль не задана).
bool DeriveSessionKey(EVP_PKEY* mine, const uint8_t peerPub[PUB_SIZE], uint8_t outKey[KEY_SIZE]);

// Формат результата: [nonce 12][ciphertext][tag 16].
// aad — открытый заголовок пакета (аутентифицируется, но не шифруется).
// counter — монотонный счётчик отправителя (НИКОГДА не повторять с тем же ключом; в старшем бите — направление).
// При ошибке OpenSSL возвращает пустой вектор.
std::vector<uint8_t> EncryptAES(const uint8_t key[KEY_SIZE], uint64_t counter,
                                const uint8_t* plain, int plainLen,
                                const uint8_t* aad, int aadLen);

// false, если тег не сошёлся (пакет подделан или повреждён, ключ или заголовок другие) — такой пакет отбросить.
bool DecryptAES(const uint8_t key[KEY_SIZE],
                const uint8_t* packet, int packetLen,
                const uint8_t* aad, int aadLen,
                std::vector<uint8_t>& outPlain);

// Счётчик из nonce (то, что положил EncryptAES): нужен приёмнику для окна защиты от повтора.
// Возвращает false, если первые 4 байта nonce не нули (такого формата мы не создаём).
bool CounterFromNonce(const uint8_t nonce[NONCE_SIZE], uint64_t& outCounter);

} // namespace crypto
