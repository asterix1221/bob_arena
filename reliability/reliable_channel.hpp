// reliability/reliable_channel.hpp
//
// Менеджер надёжной доставки: учитывает отправленные, но ещё не
// подтверждённые пакеты, решает, какие из них пора отправить повторно, и
// фиксирует окончательную недоставку. Класс НЕ обращается к сокетам, не
// сериализует пакеты и не читает системные часы: время (nowUs) и
// текущий RTO (adaptiveTimeoutUs) передаёт вызывающий код — поэтому его
// можно тестировать детерминированно, с "виртуальным" временем.

#pragma once

#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace reliability {

struct PendingPacket {
    std::vector<std::uint8_t> rawBytes; // сериализованный пакет для повторной отправки
    std::uint64_t lastSentAtUs = 0;     // момент последней (пере)отправки
    std::uint32_t attempts = 1;         // сколько раз пакет уже отправлен (включая первую отправку)
    std::uint64_t firstSentAtUs = 0;    // момент первой отправки (для времени до ACK)
};

// Сведения о только что подтверждённом пакете (для метрик и адаптивного RTO).
struct AckInfo {
    std::uint32_t attempts = 0;       // за сколько попыток пакет был подтверждён
    std::uint64_t timeToAckUs = 0;    // от ПЕРВОЙ отправки до получения ACK
};

class ReliableChannel {
public:
    explicit ReliableChannel(std::uint32_t maxAttempts = 5) : maxAttempts_(maxAttempts) {}

    // Регистрирует отправленный надёжный пакет (первая попытка). Если пакет с таким
    // же sequence уже ожидает подтверждения (переполнение 16-битного счётчика),
    // старая запись заменяется новой.
    void OnSent(std::uint16_t sequence, std::vector<std::uint8_t> rawBytes, std::uint64_t nowUs);

    // Обрабатывает входящий ACK. Возвращает true, если pending-запись найдена и снята.
    // Дубликат ACK, ACK на неизвестный пакет и ACK на уже признанный недоставленным
    // пакет игнорируются без ошибки (возвращают false).
    bool OnAckReceived(std::uint16_t sequence);

    // То же, но дополнительно сообщает число попыток и время до ACK в info.
    bool OnAckReceived(std::uint16_t sequence, std::uint64_t nowUs, AckInfo& info);

    // Возвращает пакеты, которые нужно отправить повторно прямо сейчас (с момента
    // последней отправки прошло >= adaptiveTimeoutUs), и увеличивает их attempts.
    // Пакет, у которого уже использованы все maxAttempts_ попыток и истёк тайм-аут
    // ожидания последней из них, переносится в failed_ и НЕ возвращается.
    // Один и тот же пакет возвращается не чаще, чем раз в adaptiveTimeoutUs.
    // Результат упорядочен по времени первой отправки. Указатели действительны
    // до следующего вызова OnAckReceived/OnSent/CollectForRetransmission.
    // newlyFailed (необязательно) — сюда дописываются sequence пакетов, признанных
    // недоставленными ИМЕННО в этом вызове: вызывающий код пишет их в лог.
    std::vector<PendingPacket*> CollectForRetransmission(std::uint64_t nowUs,
                                                         std::uint64_t adaptiveTimeoutUs,
                                                         std::vector<std::uint16_t>* newlyFailed = nullptr);

    std::size_t PendingCount() const { return pending_.size(); }
    std::size_t FailedCount() const { return failed_.size(); }
    const std::vector<std::uint16_t>& Failed() const { return failed_; }
    std::uint32_t MaxAttempts() const { return maxAttempts_; }

private:
    std::uint32_t maxAttempts_;
    std::unordered_map<std::uint16_t, PendingPacket> pending_;
    std::vector<std::uint16_t> failed_;
};

} // namespace reliability
