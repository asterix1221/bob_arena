// tests/test_telemetry.cpp
// Тесты расчёта RTT/SRTT/джиттера/потерь и классификации ответов
// (см. задание: "автоматические тесты... статистики...").
#include "mini_test.h"
#include "../telemetry/telemetry.h"

using namespace telemetry;

TEST_CASE("Первый успешный RTT инициализирует SRTT") {
    Telemetry tel;
    tel.OnPingSent(1, 1'000'000, "s");
    double rtt = 0, srtt = 0;
    auto status = tel.OnPongReceived(1, 1'050'000, rtt, srtt); // +50 000 мкс = 50 мс
    REQUIRE(status == ResponseStatus::Received);
    REQUIRE_APPROX(rtt, 50.0, 1e-9);
    REQUIRE_APPROX(srtt, 50.0, 1e-9); // первое измерение = сразу SRTT
}

TEST_CASE("SRTT обновляется по формуле 0.875*SRTT + 0.125*RTT") {
    Telemetry tel;
    tel.OnPingSent(1, 0, "s");
    double rtt = 0, srtt = 0;
    tel.OnPongReceived(1, 100'000, rtt, srtt); // RTT=100мс -> SRTT=100
    REQUIRE_APPROX(srtt, 100.0, 1e-9);

    tel.OnPingSent(2, 1'000'000, "s");
    tel.OnPongReceived(2, 1'000'000 + 20'000, rtt, srtt); // RTT=20мс
    // SRTT = 0.875*100 + 0.125*20 = 87.5 + 2.5 = 90.0
    REQUIRE_APPROX(rtt, 20.0, 1e-9);
    REQUIRE_APPROX(srtt, 90.0, 1e-9);
}

TEST_CASE("PONG без соответствующего PING -> unknown_response") {
    Telemetry tel;
    double rtt = 0, srtt = 0;
    auto status = tel.OnPongReceived(123, 500, rtt, srtt);
    REQUIRE(status == ResponseStatus::UnknownResponse);
}

TEST_CASE("Повторный PONG на уже полученное измерение -> duplicate_response") {
    Telemetry tel;
    tel.OnPingSent(5, 0, "s");
    double rtt = 0, srtt = 0;
    auto first = tel.OnPongReceived(5, 10'000, rtt, srtt);
    REQUIRE(first == ResponseStatus::Received);

    auto second = tel.OnPongReceived(5, 20'000, rtt, srtt);
    REQUIRE(second == ResponseStatus::DuplicateResponse);
}

TEST_CASE("Ответ, пришедший позже тайм-аута, -> late_response, а не received") {
    Telemetry tel(/*timeoutUs=*/1000); // тайм-аут = 1 мс, чтобы легко превысить в тесте
    tel.OnPingSent(9, 0, "s");
    double rtt = 0, srtt = 0;
    auto status = tel.OnPongReceived(9, 5000, rtt, srtt); // 5 мс > тайм-аута 1 мс
    REQUIRE(status == ResponseStatus::LateResponse);
    REQUIRE_APPROX(rtt, 5.0, 1e-9);
}

TEST_CASE("Late-ответ, за которым следует ещё один PONG, классифицируется как duplicate") {
    Telemetry tel(/*timeoutUs=*/1000);
    tel.OnPingSent(9, 0, "s");
    double rtt = 0, srtt = 0;
    REQUIRE(tel.OnPongReceived(9, 5000, rtt, srtt) == ResponseStatus::LateResponse);
    REQUIRE(tel.OnPongReceived(9, 6000, rtt, srtt) == ResponseStatus::DuplicateResponse);
}

TEST_CASE("ExpireTimeouts помечает просроченные измерения, а PONG, пришедший позже, -> late_response") {
    Telemetry tel(/*timeoutUs=*/1000);
    tel.OnPingSent(3, 0, "s");
    auto expired = tel.ExpireTimeouts(2000); // прошло 2 мс > тайм-аута 1 мс
    REQUIRE(expired == 1);

    double rtt = 0, srtt = 0;
    auto status = tel.OnPongReceived(3, 3000, rtt, srtt); // PONG всё же пришёл позже
    REQUIRE(status == ResponseStatus::LateResponse);
}

TEST_CASE("Джиттер — среднее модулей разностей соседних RTT (только по Received)") {
    Telemetry tel;
    double rtt = 0, srtt = 0;
    // RTT: 10, 30, 20 мс -> |30-10| + |20-30| = 20+10=30, /(3-1)=15
    tel.OnPingSent(1, 0, "s");
    tel.OnPongReceived(1, 10'000, rtt, srtt);
    tel.OnPingSent(2, 100'000, "s");
    tel.OnPongReceived(2, 130'000, rtt, srtt);
    tel.OnPingSent(3, 200'000, "s");
    tel.OnPongReceived(3, 220'000, rtt, srtt);

    REQUIRE_APPROX(tel.MeanJitterMs(), 15.0, 1e-9);
}

TEST_CASE("ComputeSeriesStats: sent/received/timeout и loss rate") {
    std::vector<Sample> samples;
    for (int i = 0; i < 10; ++i) {
        Sample s;
        s.seriesId = "loss_test";
        s.sampleIndex = i + 1;
        s.sequenceNumber = static_cast<std::uint16_t>(i);
        s.sentAtMs = i * 300.0;
        if (i % 2 == 0) {
            s.status = ResponseStatus::Received;
            s.rttMs = 10.0 + i;
            s.srttMs = 10.0 + i;
        } else {
            s.status = ResponseStatus::Timeout;
        }
        samples.push_back(s);
    }
    auto stats = ComputeSeriesStats("loss_test", samples);
    REQUIRE(stats.sent == 10);
    REQUIRE(stats.received == 5);
    REQUIRE(stats.timedOut == 5);
    REQUIRE_APPROX(stats.lossRatePercent, 50.0, 1e-9);
    REQUIRE_APPROX(stats.minRttMs, 10.0, 1e-9);
    REQUIRE_APPROX(stats.maxRttMs, 18.0, 1e-9); // i=8 -> 10+8=18
}

TEST_CASE("ComputeSeriesStats: медиана для чётного и нечётного числа RTT") {
    std::vector<Sample> odd;
    for (double v : {10.0, 30.0, 20.0}) {
        Sample s;
        s.status = ResponseStatus::Received;
        s.rttMs = v;
        odd.push_back(s);
    }
    auto oddStats = ComputeSeriesStats("odd", odd);
    REQUIRE_APPROX(oddStats.medianRttMs, 20.0, 1e-9); // отсортировано: 10,20,30 -> средний 20

    std::vector<Sample> even;
    for (double v : {10.0, 20.0, 30.0, 40.0}) {
        Sample s;
        s.status = ResponseStatus::Received;
        s.rttMs = v;
        even.push_back(s);
    }
    auto evenStats = ComputeSeriesStats("even", even);
    REQUIRE_APPROX(evenStats.medianRttMs, 25.0, 1e-9); // (20+30)/2
}

TEST_CASE("Ограниченный inFlight-контейнер не растёт бесконечно") {
    Telemetry tel(/*timeoutUs=*/1'000'000, /*maxInFlight=*/4);
    for (int i = 0; i < 10; ++i) {
        tel.OnPingSent(static_cast<std::uint16_t>(i), static_cast<std::uint64_t>(i) * 1000, "s");
    }
    REQUIRE(tel.InFlightCount() <= 4);
}
