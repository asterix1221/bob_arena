// crypto/crypto.cpp — реализация, см. crypto.h
#include "crypto.h"

#include <openssl/crypto.h>
#include <openssl/kdf.h>

#include <cstring>

namespace crypto {

KeyPair GenerateKeyPair() {
    KeyPair kp;
    EVP_PKEY_CTX* c = EVP_PKEY_CTX_new_id(EVP_PKEY_X25519, nullptr);
    if (!c) return kp;
    if (EVP_PKEY_keygen_init(c) > 0 && EVP_PKEY_keygen(c, &kp.pkey) > 0) {
        size_t len = PUB_SIZE;
        if (EVP_PKEY_get_raw_public_key(kp.pkey, kp.pub, &len) != 1 || len != PUB_SIZE) {
            EVP_PKEY_free(kp.pkey);
            kp.pkey = nullptr;
        }
    } else {
        kp.pkey = nullptr;
    }
    EVP_PKEY_CTX_free(c);
    return kp;
}

KeyPair KeyPairFromPrivate(const uint8_t priv[32]) {
    KeyPair kp;
    kp.pkey = EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, nullptr, priv, 32);
    if (!kp.pkey) return kp;
    size_t len = PUB_SIZE;
    if (EVP_PKEY_get_raw_public_key(kp.pkey, kp.pub, &len) != 1 || len != PUB_SIZE) {
        EVP_PKEY_free(kp.pkey);
        kp.pkey = nullptr;
    }
    return kp;
}

void FreeKeyPair(KeyPair& kp) {
    if (kp.pkey) { EVP_PKEY_free(kp.pkey); kp.pkey = nullptr; }
    OPENSSL_cleanse(kp.pub, sizeof(kp.pub));
}

bool X25519Shared(EVP_PKEY* mine, const uint8_t peerPub[PUB_SIZE], uint8_t outSecret[32]) {
    if (!mine) return false;
    EVP_PKEY* peer = EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, nullptr, peerPub, PUB_SIZE);
    if (!peer) return false;
    size_t sl = 32;
    EVP_PKEY_CTX* c = EVP_PKEY_CTX_new(mine, nullptr);
    bool ok = c && EVP_PKEY_derive_init(c) > 0 &&
              EVP_PKEY_derive_set_peer(c, peer) > 0 &&
              EVP_PKEY_derive(c, outSecret, &sl) > 0 && sl == 32;
    EVP_PKEY_CTX_free(c);
    EVP_PKEY_free(peer);
    if (!ok) return false;
    // Страховка: OpenSSL уже отвергает нулевой результат (точка малого порядка), но проверяем и сами.
    uint8_t acc = 0;
    for (int i = 0; i < 32; ++i) acc |= outSecret[i];
    if (acc == 0) return false;
    return true;
}

bool DeriveSessionKey(EVP_PKEY* mine, const uint8_t peerPub[PUB_SIZE], uint8_t outKey[KEY_SIZE]) {
    uint8_t secret[32];
    if (!X25519Shared(mine, peerPub, secret)) { OPENSSL_cleanse(secret, sizeof(secret)); return false; }

    EVP_PKEY_CTX* k = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, nullptr);
    size_t kl = KEY_SIZE;
    bool ok = k && EVP_PKEY_derive_init(k) > 0 &&
              EVP_PKEY_CTX_set_hkdf_md(k, EVP_sha256()) > 0 &&
              EVP_PKEY_CTX_set1_hkdf_key(k, secret, (int)sizeof(secret)) > 0 &&
              EVP_PKEY_CTX_add1_hkdf_info(k, (const unsigned char*)"game-udp-v1", 11) > 0 &&
              EVP_PKEY_derive(k, outKey, &kl) > 0 && kl == KEY_SIZE;
    EVP_PKEY_CTX_free(k);
    OPENSSL_cleanse(secret, sizeof(secret));
    return ok;
}

std::vector<uint8_t> EncryptAES(const uint8_t key[KEY_SIZE], uint64_t counter,
                                const uint8_t* plain, int plainLen,
                                const uint8_t* aad, int aadLen) {
    if (plainLen < 0 || aadLen < 0) return {};
    uint8_t nonce[NONCE_SIZE] = {0};
    for (int i = 0; i < 8; ++i) nonce[4 + i] = (uint8_t)(counter >> (56 - 8 * i));   // big-endian

    std::vector<uint8_t> out(NONCE_SIZE + plainLen + TAG_SIZE);
    memcpy(out.data(), nonce, NONCE_SIZE);

    EVP_CIPHER_CTX* c = EVP_CIPHER_CTX_new();
    int l = 0, fin = 0;
    bool ok = c &&
        EVP_EncryptInit_ex(c, EVP_aes_256_gcm(), nullptr, key, nonce) == 1 &&
        (aadLen == 0 || EVP_EncryptUpdate(c, nullptr, &l, aad, aadLen) == 1) &&
        (plainLen == 0 || EVP_EncryptUpdate(c, out.data() + NONCE_SIZE, &l, plain, plainLen) == 1) &&
        EVP_EncryptFinal_ex(c, out.data() + NONCE_SIZE + plainLen, &fin) == 1 &&
        EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_GCM_GET_TAG, TAG_SIZE, out.data() + NONCE_SIZE + plainLen) == 1;
    EVP_CIPHER_CTX_free(c);
    if (!ok) out.clear();
    return out;
}

bool DecryptAES(const uint8_t key[KEY_SIZE], const uint8_t* packet, int packetLen,
                const uint8_t* aad, int aadLen, std::vector<uint8_t>& outPlain) {
    outPlain.clear();
    if (packetLen < NONCE_SIZE + TAG_SIZE || aadLen < 0) return false;
    const int cl = packetLen - NONCE_SIZE - TAG_SIZE;
    const uint8_t* nonce = packet;
    const uint8_t* ct = packet + NONCE_SIZE;
    uint8_t tag[TAG_SIZE];
    memcpy(tag, packet + NONCE_SIZE + cl, TAG_SIZE);
    std::vector<uint8_t> buf(cl > 0 ? cl : 1, 0);

    EVP_CIPHER_CTX* c = EVP_CIPHER_CTX_new();
    int l = 0, fin = 0;
    bool ok = c &&
        EVP_DecryptInit_ex(c, EVP_aes_256_gcm(), nullptr, key, nonce) == 1 &&
        (aadLen == 0 || EVP_DecryptUpdate(c, nullptr, &l, aad, aadLen) == 1) &&
        (cl == 0 || EVP_DecryptUpdate(c, buf.data(), &l, ct, cl) == 1) &&
        EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_GCM_SET_TAG, TAG_SIZE, tag) == 1 &&
        EVP_DecryptFinal_ex(c, buf.data() + cl, &fin) > 0;     // здесь и проверяется тег
    EVP_CIPHER_CTX_free(c);
    if (!ok) return false;               // открытый текст при неверном теге наружу не отдаём
    buf.resize(cl);
    outPlain = std::move(buf);
    return true;
}

bool CounterFromNonce(const uint8_t nonce[NONCE_SIZE], uint64_t& outCounter) {
    if (nonce[0] | nonce[1] | nonce[2] | nonce[3]) return false;
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | nonce[4 + i];
    outCounter = v;
    return true;
}

} // namespace crypto
