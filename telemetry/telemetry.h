// telemetry/telemetry.h
//
// Расчёт метрик качества соединения. Модуль НЕ знает о сокетах и НЕ
// занимается сериализацией — на вход получает уже разобранные номера
// пакетов и метки времени (см. protocol.h / transport.h), на выход
// отдаёт RTT/SRTT/джиттер и статус каждого ответа.

#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <unordered_map>
#include <vector>
#include <optional>

namespace telemetry {

enum class ResponseStatus {
    Received,          // обычный, вовремя пришедший PONG
    Timeout,           // PONG не пришёл за kDefaultTimeoutUs
    LateResponse,      // PONG пришёл, но позже тайм-аута
    DuplicateResponse, // повторный PONG на уже завершённое измерение
    UnknownResponse,   // PONG с sequenceNumber, которого нет в inFlight
};

const char* ToString(ResponseStatus status);

// Тайм-аут ожидания PONG. Обоснование значения — см. docs/Experiment_Config.md
// (кратко: 1000 мс с большим запасом покрывает delay_100 + jitter 150 мс на
// локальной петле, оставаясь при этом достаточно строгим, чтобы отличать
// "медленный, но живой" ответ от реальной потери в серии loss_5).
constexpr std::uint64_t kDefaultTimeoutUs = 1'000'000;

// Верхняя граница числа одновременно отслеживаемых измерений: контейнер
// inFlight ограничен, чтобы клиент с "забытыми" (потерянными) сериями не
// рос неограниченно в памяти при долгой работе.
constexpr std::size_t kDefaultMaxInFlight = 4096;

struct InFlightRecord {
    std::uint16_t sequenceNumber = 0;
    std::uint64_t sentAtUs = 0;     // время отправки по часам клиента (monotonic)
    std::string seriesId;          // идентификатор серии эксперимента (baseline, loss_5, ...)
    ResponseStatus status = ResponseStatus::Timeout; // финальный статус (обновляется по факту)
    int attempts = 1;              // число попыток; в ПР №2 повторная отправка не выполняется
    bool completed = false;        // true после первого PONG или после истечения тайм-аута
};

// Один финализированный результат измерения — то, что уходит в CSV-журнал.
struct Sample {
    std::string seriesId;
    int sampleIndex = 0;           // порядковый номер измерения ВНУТРИ серии (1..N)
    std::uint16_t sequenceNumber = 0;
    double sentAtMs = 0.0;         // время отправки относительно начала серии, мс
    std::optional<double> rttMs;   // пусто для timeout/duplicate/unknown
    std::optional<double> srttMs;  // пусто, если сэмпл не обновлял SRTT
    ResponseStatus status = ResponseStatus::Timeout;
};

class Telemetry {
public:
    explicit Telemetry(std::uint64_t timeoutUs = kDefaultTimeoutUs,
                        std::size_t maxInFlight = kDefaultMaxInFlight);

    // Регистрирует отправку PING. Если inFlight_ уже заполнен до
    // maxInFlight, самая старая незавершённая запись принудительно
    // помечается как Timeout и вытесняется (contain memory growth).
    void OnPingSent(std::uint16_t sequenceNumber, std::uint64_t sentAtUs, const std::string& seriesId);

    // Обрабатывает пришедший PONG. rttMsOut/srttMsOut заполняются только
    // для ResponseStatus::Received (и rttMsOut — дополнительно для
    // LateResponse, см. .cpp). Возвращает классификацию ответа.
    ResponseStatus OnPongReceived(std::uint16_t sequenceNumber, std::uint64_t receivedAtUs,
                                   double& rttMsOut, double& srttMsOut);

    // Помечает Timeout все незавершённые записи старше timeout_us_ на
    // момент nowUs. Возвращает число вновь просроченных записей.
    std::size_t ExpireTimeouts(std::uint64_t nowUs);

    double SrttMs() const { return srttMs_; }
    double MeanJitterMs() const { return sampleCount_ > 1 ? jitterSumMs_ / (sampleCount_ - 1) : 0.0; }
    std::size_t InFlightCount() const { return inFlight_.size(); }

private:
    std::uint64_t timeoutUs_;
    std::size_t maxInFlight_;
    std::unordered_map<std::uint16_t, InFlightRecord> inFlight_;

    double srttMs_ = 0.0;
    bool hasSrtt_ = false;
    double previousRttMs_ = 0.0;
    bool hasPreviousRtt_ = false;
    double jitterSumMs_ = 0.0;
    std::size_t sampleCount_ = 0; // число сэмплов, обновивших SRTT (т.е. Received)
};

// ---- Офлайн-статистика по серии (используется для Latency_Report.md) ----

struct SeriesStats {
    std::string seriesId;
    int sent = 0;
    int received = 0;   // status == Received
    int timedOut = 0;    // status == Timeout (ответ так и не пришёл)
    int late = 0;        // status == LateResponse
    int duplicate = 0;   // status == DuplicateResponse
    int unknown = 0;     // status == UnknownResponse
    double minRttMs = 0.0;
    double maxRttMs = 0.0;
    double meanRttMs = 0.0;
    double medianRttMs = 0.0;
    double lastSrttMs = 0.0;
    double meanJitterMs = 0.0;
    double lossRatePercent = 0.0; // timedOut / sent * 100 (см. .cpp)
};

// Считает агрегаты по уже накопленным сэмплам ОДНОЙ серии (см. Sample выше).
// RTT-статистика (min/max/mean/median) считается по сэмплам со статусом
// Received И LateResponse (для обоих есть измеренный RTT); SRTT и джиттер —
// только по Received (только они обновляют сглаженную оценку и разницу
// последовательных RTT, как того требует определение SRTT/джиттера).
// Loss Rate — строго по Timeout (пакет не ответил вовсе), late/duplicate/
// unknown в неё не входят и приводятся отдельными счётчиками для отчёта.
SeriesStats ComputeSeriesStats(const std::string& seriesId, const std::vector<Sample>& samples);

} // namespace telemetry
