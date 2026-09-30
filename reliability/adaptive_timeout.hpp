// reliability/adaptive_timeout.hpp
//
// Адаптивный расчёт тайм-аута повторной передачи (RTO) по мотивам алгоритма
// Джекобсона/Карелса из TCP (RFC 6298). Модуль НЕ знает о сокетах и пакетах —
// получает на вход только измеренные значения RTT в миллисекундах.
//
//   первое измерение:  SRTT = RTT,  RTTVAR = RTT / 2
//   далее:             RTTVAR = (1 - beta) * RTTVAR + beta * |SRTT - RTT|
//                      SRTT   = (1 - alpha) * SRTT + alpha * RTT
//   RTO = clamp(SRTT + 4 * RTTVAR, [100 мс, 3000 мс])
//
// Важно: RTTVAR обновляется ДО SRTT (по старому SRTT) — порядок из RFC 6298.
// Источники сэмплов (решает вызывающий код, см. client/reliable_client.cpp):
//   - RTT из пар PING/PONG (ПР №2, telemetry::Telemetry);
//   - время до ACK на надёжный пакет — ТОЛЬКО для пакетов, отправленных с
//     первой попытки (правило Карелса: для повторно отправленного пакета
//     неизвестно, на какую из попыток пришёл ACK, и такой сэмпл исказил бы RTT).

#pragma once

#include <cstdint>

namespace reliability {

class AdaptiveTimeout {
public:
    static constexpr double kAlpha = 0.125;
    static constexpr double kBeta = 0.25;
    static constexpr double kMinRtoMs = 100.0;
    static constexpr double kMaxRtoMs = 3000.0;
    // RTO до первого измерения (RFC 6298, п. 2.1: начальное значение 1 с).
    // Формула SRTT + 4*RTTVAR без данных дала бы 0 -> 100 мс (нижняя граница),
    // то есть агрессивные ложные повторы ещё до первого измерения RTT.
    static constexpr double kInitialRtoMs = 1000.0;

    // Учитывает одно измерение RTT. Отрицательные и нечисловые значения игнорируются.
    void OnSample(double rttMs);

    double RtoMs() const;
    std::uint64_t RtoUs() const;

    double SrttMs() const { return srttMs_; }
    double RttVarMs() const { return rttVarMs_; }
    bool HasSamples() const { return initialized_; }

private:
    double srttMs_ = 0.0;
    double rttVarMs_ = 0.0;
    bool initialized_ = false;
};

} // namespace reliability
