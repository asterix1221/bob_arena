// crypto/secure_channel.h
//
// ПР №6: слой «запечатывания» пакетов протокола поверх crypto.h. Сокетов и игры не знает — получает и отдаёт байты,
// поэтому полностью проверяется юнит-тестами (tests/test_crypto.cpp) без сети.
//
//   handshake:  клиент --KEY_EXCHANGE(pubC)--> сервер;  сервер --KEY_EXCHANGE(pubS)--> клиент;
//               обе стороны: ключ = HKDF(X25519(мой закрытый, чужой открытый))  — crypto::DeriveSessionKey
//   Seal:   внутренний пакет (любой Serialize* из protocol.h) -> ENCRYPTED
//   Open:   ENCRYPTED -> внутренний пакет (заголовок восстановлен), либо отказ с причиной
//
// Формат ENCRYPTED (все поля заголовка открыты и входят в AAD, поэтому подмена любого из них ломает тег):
//   [type=16 u8][seq u16][payloadSize u16][version u16][requiresAck u8]   <- 8 байт, AAD
//   [nonce 12][шифртекст: тип внутреннего пакета u8 + его payload][tag 16]
//   nonce = 00 00 00 00 | счётчик (u64 big-endian); старший бит счётчика — направление (crypto::DIRECTION_BIT).
// sequenceNumber и requiresAck — как у внутреннего пакета, поэтому ACK/повтор/дедупликация (ПР №3) работают как раньше.
// Счётчик — ОТДЕЛЬНО от sequenceNumber и растёт на КАЖДУЮ отправку, включая повторную передачу того же пакета:
// повтор уходит с новым nonce (nonce никогда не повторяется), а получатель дедуплицирует его по sequenceNumber.
#pragma once

#include "crypto.h"
#include "../protocol/protocol.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace crypto {

// Окно приёма: защита от повторного проигрывания перехваченных пакетов (как anti-replay в IPsec/DTLS).
// Счётчик принимается, если он новее всех виденных, либо ещё не встречался и не старше окна (допускает перестановку).
class ReplayWindow {
public:
    explicit ReplayWindow(std::size_t size = 1024) : ring_(size == 0 ? 1 : size, kEmpty) {}
    // Проверка БЕЗ записи: вызывается до расшифровки (дёшево отсекает копии). Запись — Commit() после проверки тега,
    // иначе подделка с «будущим» счётчиком сдвинула бы окно и выбросила легитимные пакеты.
    bool WouldAccept(std::uint64_t c) const;
    void Commit(std::uint64_t c);
    std::uint64_t Highest() const { return highest_; }
    bool Empty() const { return !any_; }
private:
    static constexpr std::uint64_t kEmpty = ~0ULL;
    std::vector<std::uint64_t> ring_;
    std::uint64_t highest_ = 0;
    bool any_ = false;
};

enum class OpenResult {
    Ok,
    Malformed,   // не ENCRYPTED, неверные размеры, неизвестный внутренний тип
    WrongDirection, // счётчик другого направления (эхо нашего же пакета обратно)
    Replay,      // счётчик уже был или слишком старый
    AuthFail,    // тег не сошёлся: подделка, повреждение, чужой ключ или изменённый заголовок (AAD)
};

const char* ToString(OpenResult r);

// Сессия одного собеседника (на сервере — по одной на адрес клиента).
struct Session {
    std::uint8_t key[KEY_SIZE] = {0};
    bool isServer = false;            // роль ЭТОЙ стороны: определяет бит направления в счётчике
    std::uint64_t sendCounter = 0;    // последний использованный счётчик; первый пакет — 1
    ReplayWindow replay{1024};
    // статистика для логов и net_graph
    std::uint64_t sealed = 0, opened = 0, authFail = 0, replayDrops = 0, malformed = 0;

    Session() = default;
    Session(const std::uint8_t k[KEY_SIZE], bool server) : isServer(server) {
        for (int i = 0; i < KEY_SIZE; ++i) key[i] = k[i];
    }
    ~Session();
};

// Внутренний пакет -> ENCRYPTED. Пустой вектор, если внутренний пакет некорректен, это handshake/ENCRYPTED
// (вкладывать их нельзя) или не помещается в 16-битное payloadSize.
std::vector<std::uint8_t> SealPacket(Session& s, const std::uint8_t* inner, std::size_t innerSize);
inline std::vector<std::uint8_t> SealPacket(Session& s, const std::vector<std::uint8_t>& inner) {
    return SealPacket(s, inner.data(), inner.size());
}

// ENCRYPTED -> внутренний пакет. При любом отказе outInner не трогается.
OpenResult OpenPacket(Session& s, const std::uint8_t* data, std::size_t size, std::vector<std::uint8_t>& outInner);

} // namespace crypto
