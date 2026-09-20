// tests/mini_test.h
//
// Совсем маленький header-only тестовый харнесс без внешних зависимостей.
// Осознанный выбор вместо Catch2 (который используется в примере из
// задания): ПР №1 уже собирается голым g++/cl без пакетных менеджеров
// (vcpkg/conan), и хотелось сохранить тот же принцип сборки "один
// компилятор — ноль внешних библиотек" для тестов ПР №2 тоже. Даёт
// TEST_CASE/REQUIRE с тем же смыслом, что и в Catch2, но без подключения
// сторонней библиотеки.

#pragma once

#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace mini_test {

struct TestCase {
    std::string name;
    std::function<void()> fn;
};

inline std::vector<TestCase>& Registry() {
    static std::vector<TestCase> registry;
    return registry;
}

struct Registrar {
    Registrar(const std::string& name, std::function<void()> fn) {
        Registry().push_back({name, std::move(fn)});
    }
};

struct AssertionFailure {
    std::string message;
};

inline int RunAll() {
    int failed = 0;
    for (auto& test : Registry()) {
        std::printf("[ RUN      ] %s\n", test.name.c_str());
        try {
            test.fn();
            std::printf("[       OK ] %s\n", test.name.c_str());
        } catch (const AssertionFailure& f) {
            std::printf("[  FAILED  ] %s: %s\n", test.name.c_str(), f.message.c_str());
            ++failed;
        } catch (const std::exception& e) {
            std::printf("[  FAILED  ] %s: необработанное исключение: %s\n", test.name.c_str(), e.what());
            ++failed;
        }
    }
    std::printf("---\n%zu тестов, %d провалено\n", Registry().size(), failed);
    return failed == 0 ? 0 : 1;
}

} // namespace mini_test

#define MT_CONCAT_INNER(a, b) a##b
#define MT_CONCAT(a, b) MT_CONCAT_INNER(a, b)

#define TEST_CASE(name) \
    static void MT_CONCAT(mt_test_fn_, __LINE__)(); \
    static ::mini_test::Registrar MT_CONCAT(mt_registrar_, __LINE__)(name, MT_CONCAT(mt_test_fn_, __LINE__)); \
    static void MT_CONCAT(mt_test_fn_, __LINE__)()

#define REQUIRE(cond) \
    do { \
        if (!(cond)) { \
            throw ::mini_test::AssertionFailure{ \
                std::string("REQUIRE(" #cond ") failed at ") + __FILE__ + ":" + std::to_string(__LINE__)}; \
        } \
    } while (0)

#define REQUIRE_FALSE(cond) REQUIRE(!(cond))

// Сравнение с плавающей точкой в пределах эпсилон (RTT/SRTT/джиттер — double).
#define REQUIRE_APPROX(a, b, eps) \
    do { \
        double mt_a = (a), mt_b = (b), mt_eps = (eps); \
        if (!(mt_a - mt_b <= mt_eps && mt_b - mt_a <= mt_eps)) { \
            throw ::mini_test::AssertionFailure{ \
                std::string("REQUIRE_APPROX(" #a ", " #b ") failed at ") + __FILE__ + ":" + std::to_string(__LINE__) + \
                " (" + std::to_string(mt_a) + " vs " + std::to_string(mt_b) + ")"}; \
        } \
    } while (0)
