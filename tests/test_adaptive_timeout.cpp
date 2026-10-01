// tests/test_adaptive_timeout.cpp
// Тесты адаптивного RTO (ПР №3): формулы SRTT/RTTVAR/RTO, границы, реакция на
// всплеск задержки.
#include "mini_test.h"
#include "../reliability/adaptive_timeout.hpp"

#include <cmath>

using namespace reliability;

TEST_CASE("RTO до первого измерения равен начальному значению (1000 мс)") {
    AdaptiveTimeout t;
    REQUIRE_FALSE(t.HasSamples());
    REQUIRE_APPROX(t.RtoMs(), 1000.0, 1e-9);
    REQUIRE(t.RtoUs() == 1'000'000ULL);
}

TEST_CASE("Первое измерение: SRTT = RTT, RTTVAR = RTT / 2, RTO = 3 * RTT") {
    AdaptiveTimeout t;
    t.OnSample(200.0);
    REQUIRE(t.HasSamples());
    REQUIRE_APPROX(t.SrttMs(), 200.0, 1e-9);
    REQUIRE_APPROX(t.RttVarMs(), 100.0, 1e-9);
    REQUIRE_APPROX(t.RtoMs(), 600.0, 1e-9); // 200 + 4 * 100
}

TEST_CASE("Второе измерение: RTTVAR считается по СТАРОМУ SRTT, затем обновляется SRTT") {
    AdaptiveTimeout t;
    t.OnSample(200.0);
    t.OnSample(100.0);
    // RTTVAR = 0.75 * 100 + 0.25 * |200 - 100| = 100
    // SRTT   = 0.875 * 200 + 0.125 * 100      = 187.5
    REQUIRE_APPROX(t.RttVarMs(), 100.0, 1e-9);
    REQUIRE_APPROX(t.SrttMs(), 187.5, 1e-9);
    REQUIRE_APPROX(t.RtoMs(), 587.5, 1e-9); // 187.5 + 4 * 100
}

TEST_CASE("Нижняя граница RTO — 100 мс") {
    AdaptiveTimeout t;
    t.OnSample(10.0); // сырое значение 10 + 4 * 5 = 30 мс
    REQUIRE_APPROX(t.RtoMs(), 100.0, 1e-9);
}

TEST_CASE("Верхняя граница RTO — 3000 мс") {
    AdaptiveTimeout t;
    t.OnSample(5000.0); // сырое значение 15000 мс
    REQUIRE_APPROX(t.RtoMs(), 3000.0, 1e-9);
}

TEST_CASE("При стабильном RTT разброс затухает, RTO сходится к SRTT (не ниже границы)") {
    AdaptiveTimeout t;
    for (int i = 0; i < 100; ++i) t.OnSample(150.0);
    REQUIRE_APPROX(t.SrttMs(), 150.0, 1e-6);
    REQUIRE(t.RttVarMs() < 1e-6);
    REQUIRE_APPROX(t.RtoMs(), 150.0, 1e-3);
}

TEST_CASE("Всплеск задержки быстро увеличивает RTO") {
    AdaptiveTimeout t;
    for (int i = 0; i < 100; ++i) t.OnSample(50.0);
    const double before = t.RtoMs(); // ~ 100 мс (нижняя граница)
    t.OnSample(300.0);
    // RTTVAR = 0.25 * 250 = 62.5, SRTT = 81.25 -> RTO = 331.25
    REQUIRE_APPROX(t.RtoMs(), 331.25, 1e-6);
    REQUIRE(t.RtoMs() > 3.0 * before);
}

TEST_CASE("Некорректные измерения (отрицательные, NaN) игнорируются") {
    AdaptiveTimeout t;
    t.OnSample(-5.0);
    t.OnSample(std::nan(""));
    REQUIRE_FALSE(t.HasSamples());
    t.OnSample(100.0);
    t.OnSample(-1.0);
    REQUIRE_APPROX(t.SrttMs(), 100.0, 1e-9);
}
