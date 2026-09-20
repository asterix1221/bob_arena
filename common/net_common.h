// net_common.h
// Тонкая кроссплатформенная обёртка над сокетами: на Windows 11 это
// Winsock2, на Linux (использовался только для проверки в песочнице)
// — обычные Berkeley sockets. Позволяет держать один и тот же
// server.cpp / client.cpp без #ifdef внутри логики.

#pragma once

#ifdef _WIN32
    // Обязательно ДО <cstdio>/windows.h: без этого MSVC (cl.exe) считает
    // fopen/sprintf и т.п. "небезопасными" и требует fopen_s (предупреждение
    // C4996). Функции из common/telemetry используют переносимый std::fopen
    // (работает одинаково на Windows/Linux) — это осознанный выбор ради
    // кроссплатформенности, а не недосмотр, поэтому предупреждение отключено
    // явно, а не заменено на непереносимый fopen_s.
    #ifndef _CRT_SECURE_NO_WARNINGS
    #define _CRT_SECURE_NO_WARNINGS
    #endif

    // Обязательно ДО включения windows.h: без этого windows.h определяет
    // макросы min(a,b)/max(a,b), которые ломают ЛЮБОЙ вызов std::min/std::max
    // в коде (препроцессор подставляет их вместо идентификаторов и получает
    // невалидный синтаксис вида "std::((a)<(b)?...)" -> ошибка компилятора/
    // IntelliSense "expected unqualified-id"). WIN32_LEAN_AND_MEAN снижает
    // риск похожих конфликтов с другими редко используемыми макросами.
    #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
    #endif
    #ifndef NOMINMAX
    #define NOMINMAX
    #endif
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #include <windows.h> // SetConsoleOutputCP / SetConsoleCP для UTF-8-консоли
    #pragma comment(lib, "ws2_32.lib")
    typedef SOCKET socket_t;
    #define CLOSESOCKET closesocket
    #define SOCK_ERR SOCKET_ERROR
#else
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <unistd.h>
    #include <cerrno>
    typedef int socket_t;
    #define CLOSESOCKET close
    #define INVALID_SOCKET (-1)
    #define SOCK_ERR (-1)
#endif

#include <cstdio>
#include <cstring>
#include <string>

inline bool net_init() {
#ifdef _WIN32
    WSADATA wsaData;
    return WSAStartup(MAKEWORD(2, 2), &wsaData) == 0;
#else
    return true;
#endif
}

inline void net_shutdown() {
#ifdef _WIN32
    WSACleanup();
#endif
}

// Исходники в UTF-8, но консоль Windows по умолчанию использует кодовую
// страницу OEM (обычно 866 для русской локали) — из-за этого кириллица
// в printf выводится нечитаемой тарабарщиной. Принудительно переключаем
// консоль на UTF-8 (CP_UTF8 = 65001) на входе и выходе. На Linux/macOS
// терминал по умолчанию уже UTF-8, вызов ничего не делает.
inline void enable_utf8_console() {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
#endif
}

// Ставит таймаут на приём (recvfrom), чтобы клиент/сервер не висли
// вечно на ожидании ответа, если пакет потерялся.
inline void set_recv_timeout(socket_t sock, int milliseconds) {
#ifdef _WIN32
    DWORD timeout = milliseconds;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&timeout, sizeof(timeout));
#else
    struct timeval tv;
    tv.tv_sec = milliseconds / 1000;
    tv.tv_usec = (milliseconds % 1000) * 1000;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
#endif
}

inline std::string endpoint_to_string(const sockaddr_in& addr) {
    char ipStr[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, (void*)&addr.sin_addr, ipStr, INET_ADDRSTRLEN);
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%s:%d", ipStr, ntohs(addr.sin_port));
    return std::string(buf);
}
