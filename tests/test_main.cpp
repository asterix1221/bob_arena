// tests/test_main.cpp
// Точка входа тестового бинарника: mini_test.h сам собирает список тестов
// из TEST_CASE(...) в test_protocol.cpp / test_telemetry.cpp (статическая
// регистрация при инициализации глобальных объектов), здесь только запуск.
#include "mini_test.h"
#include "../common/net_common.h" // enable_utf8_console()

int main() {
    // Имена тестов и итоговая строка — кириллица в UTF-8; без этого PowerShell/cmd
    // показывают их как "╤В╨╡╤Б╤В╤Л" (консоль Windows по умолчанию в CP866/CP437).
    enable_utf8_console();
    return mini_test::RunAll();
}
