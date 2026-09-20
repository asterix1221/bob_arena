// telemetry/telemetry.cpp
#include "telemetry.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace telemetry {

const char* ToString(ResponseStatus status) {
    switch (status) {
        case ResponseStatus::Received:          return "received";
        case ResponseStatus::Timeout:           return "timeout";
        case ResponseStatus::LateResponse:       return "late_response";
        case ResponseStatus::DuplicateResponse:  return "duplicate_response";
        case ResponseStatus::UnknownResponse:    return "unknown_response";
    }
    return "unknown_response";
}

Telemetry::Telemetry(std::uint64_t timeoutUs, std::size_t maxInFlight)
    : timeoutUs_(timeoutUs), maxInFlight_(maxInFlight) {}

void Telemetry::OnPingSent(std::uint16_t sequenceNumber, std::uint64_t sentAtUs, const std::string& seriesId) {
    if (inFlight_.size() >= maxInFlight_) {
        // Контейнер ограничен: вытесняем самую старую запись, отдавая
        // приоритет уже завершённым (completed) записям, чтобы не терять
        // измерения, которые ещё ждут ответа.
        auto victim = inFlight_.end();
        bool victimCompleted = false;
        for (auto it = inFlight_.begin(); it != inFlight_.end(); ++it) {
            bool better = (victim == inFlight_.end()) ||
                          (it->second.completed && !victimCompleted) ||
                          (it->second.completed == victimCompleted && it->second.sentAtUs < victim->second.sentAtUs);
            if (better) {
                victim = it;
                victimCompleted = it->second.completed;
            }
        }
        if (victim != inFlight_.end()) {
            inFlight_.erase(victim);
        }
    }

    InFlightRecord rec;
    rec.sequenceNumber = sequenceNumber;
    rec.sentAtUs = sentAtUs;
    rec.seriesId = seriesId;
    rec.status = ResponseStatus::Timeout; // финализируется либо здесь, либо в OnPongReceived
    rec.attempts = 1;
    rec.completed = false;
    inFlight_[sequenceNumber] = rec;
}

ResponseStatus Telemetry::OnPongReceived(std::uint16_t sequenceNumber, std::uint64_t receivedAtUs,
                                          double& rttMsOut, double& srttMsOut) {
    auto it = inFlight_.find(sequenceNumber);
    if (it == inFlight_.end()) {
        return ResponseStatus::UnknownResponse;
    }
    InFlightRecord& rec = it->second;

    // Уже был получен обычный или поздний ответ ранее -> это дубликат.
    if (rec.status == ResponseStatus::Received || rec.status == ResponseStatus::LateResponse) {
        return ResponseStatus::DuplicateResponse;
    }

    // rec.status == Timeout здесь означает "ещё ждём первый ответ"
    // (completed == false) либо "уже был явно просрочен через
    // ExpireTimeouts, но настоящий ответ только сейчас пришёл"
    // (completed == true) — в обоих случаях это первый настоящий ответ.
    const double rttMs = (receivedAtUs >= rec.sentAtUs)
                             ? static_cast<double>(receivedAtUs - rec.sentAtUs) / 1000.0
                             : 0.0; // защита от некорректных/рассинхронизированных меток
    const bool withinTimeout = !rec.completed && (receivedAtUs - rec.sentAtUs <= timeoutUs_);

    if (withinTimeout) {
        rec.status = ResponseStatus::Received;
        rec.completed = true;

        if (hasPreviousRtt_) {
            jitterSumMs_ += std::fabs(rttMs - previousRttMs_);
        }
        previousRttMs_ = rttMs;
        hasPreviousRtt_ = true;

        srttMs_ = hasSrtt_ ? (0.875 * srttMs_ + 0.125 * rttMs) : rttMs;
        hasSrtt_ = true;
        ++sampleCount_;

        rttMsOut = rttMs;
        srttMsOut = srttMs_;
        return ResponseStatus::Received;
    }

    // Либо превышен тайм-аут прямо сейчас, либо запись уже была помечена
    // просроченной ранее и это первый пришедший (пусть и запоздавший) ответ.
    rec.status = ResponseStatus::LateResponse;
    rec.completed = true;
    rttMsOut = rttMs;
    return ResponseStatus::LateResponse;
}

std::size_t Telemetry::ExpireTimeouts(std::uint64_t nowUs) {
    std::size_t expired = 0;
    for (auto& [seq, rec] : inFlight_) {
        if (!rec.completed && (nowUs - rec.sentAtUs > timeoutUs_)) {
            rec.status = ResponseStatus::Timeout;
            rec.completed = true;
            ++expired;
        }
    }
    return expired;
}

SeriesStats ComputeSeriesStats(const std::string& seriesId, const std::vector<Sample>& samples) {
    SeriesStats stats;
    stats.seriesId = seriesId;
    stats.sent = static_cast<int>(samples.size());

    std::vector<double> rttValues;   // Received + LateResponse (у обоих есть измеренный RTT)
    std::vector<double> receivedRtt; // только Received, для SRTT/джиттера
    rttValues.reserve(samples.size());

    for (const auto& s : samples) {
        switch (s.status) {
            case ResponseStatus::Received:
                ++stats.received;
                if (s.rttMs) rttValues.push_back(*s.rttMs);
                if (s.rttMs) receivedRtt.push_back(*s.rttMs);
                if (s.srttMs) stats.lastSrttMs = *s.srttMs;
                break;
            case ResponseStatus::Timeout:
                ++stats.timedOut;
                break;
            case ResponseStatus::LateResponse:
                ++stats.late;
                if (s.rttMs) rttValues.push_back(*s.rttMs);
                break;
            case ResponseStatus::DuplicateResponse:
                ++stats.duplicate;
                break;
            case ResponseStatus::UnknownResponse:
                ++stats.unknown;
                break;
        }
    }

    if (!rttValues.empty()) {
        stats.minRttMs = *std::min_element(rttValues.begin(), rttValues.end());
        stats.maxRttMs = *std::max_element(rttValues.begin(), rttValues.end());
        double sum = 0.0;
        for (double v : rttValues) sum += v;
        stats.meanRttMs = sum / rttValues.size();

        std::vector<double> sorted = rttValues;
        std::sort(sorted.begin(), sorted.end());
        const std::size_t n = sorted.size();
        stats.medianRttMs = (n % 2 == 1)
                                 ? sorted[n / 2]
                                 : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0;
    }

    if (receivedRtt.size() > 1) {
        double jitterSum = 0.0;
        for (std::size_t i = 1; i < receivedRtt.size(); ++i) {
            jitterSum += std::fabs(receivedRtt[i] - receivedRtt[i - 1]);
        }
        stats.meanJitterMs = jitterSum / (receivedRtt.size() - 1);
    }

    stats.lossRatePercent = stats.sent > 0
                                 ? (static_cast<double>(stats.timedOut) / stats.sent) * 100.0
                                 : 0.0;
    return stats;
}

} // namespace telemetry
