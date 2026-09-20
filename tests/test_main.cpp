// tests/test_main.cpp
// Точка входа тестового бинарника: mini_test.h сам собирает список тестов
// из TEST_CASE(...) в test_protocol.cpp / test_telemetry.cpp (статическая
// регистрация при инициализации глобальных объектов), здесь только запуск.
#include "mini_test.h"

int main() {
    return mini_test::RunAll();
}
