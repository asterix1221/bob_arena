// server.cpp — UDP-сервер для Smash Arena
// Практика №1: эхо-режим с разбором заголовка и логом команд.
// Слушает UDP-порт 9000.
//
// Сборка:
//   Linux/macOS:  g++ server.cpp -o server
//   MinGW:        g++ server.cpp -o server.exe -lws2_32
//   MSVC:         cl /EHsc server.cpp ws2_32.lib

// ---------- Платформенные includes ----------

#ifdef _WIN32
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #pragma comment(lib, "ws2_32.lib")
    #define close(s) closesocket(s)
#else
    #include <arpa/inet.h>
    #include <unistd.h>
#endif

#include <iostream>
#include <cstring>
#include <ctime>

// ---------- Протокол (должен совпадать с client.cpp) ----------

#pragma pack(push, 1)

struct PacketHeader {
    uint8_t  type;        // 1 = MOVEMENT, 2 = SHOOT, 3 = STATE
    uint16_t seqNumber;   // порядковый номер
    uint8_t  payloadSize; // размер полезной нагрузки
};

struct MovementCmd {
    uint8_t playerId;
    int8_t  dx, dy;
};

struct ShootCmd {
    uint8_t playerId;
    uint8_t weaponId;
    int8_t  dirX, dirY;
    uint8_t aimTargetId;
};

#pragma pack(pop)

enum PacketType : uint8_t { MOVEMENT = 1, SHOOT = 2, STATE = 3 };

// ---------- Лог ----------

const char* typeName(uint8_t t) {
    switch (t) {
        case MOVEMENT: return "MOVEMENT";
        case SHOOT:    return "SHOOT";
        case STATE:    return "STATE";
        default:       return "UNKNOWN";
    }
}

void logPacket(const sockaddr_in& client, const PacketHeader& h) {
    char ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &client.sin_addr, ip, sizeof(ip));

    time_t now = time(nullptr);
    char ts[32];
    strftime(ts, sizeof(ts), "%H:%M:%S", localtime(&now));

    std::cout << "[" << ts << "] type=" << typeName(h.type)
              << " seq=" << h.seqNumber
              << " size=" << (int)h.payloadSize
              << " from " << ip << ":" << ntohs(client.sin_port)
              << std::endl;
}

void onMovement(const MovementCmd& cmd) {
    std::cout << "  -> move player " << (int)cmd.playerId
              << " dir=(" << (int)cmd.dx << "," << (int)cmd.dy << ")"
              << std::endl;
}

void onShoot(const ShootCmd& cmd) {
    std::cout << "  -> player " << (int)cmd.playerId
              << " attacks wpn=" << (int)cmd.weaponId
              << " dir=(" << (int)cmd.dirX << "," << (int)cmd.dirY << ")"
              << " target=" << (int)cmd.aimTargetId
              << std::endl;
}

// ---------- main ----------

int main() {
    // Windows: обязательная инициализация Winsock
#ifdef _WIN32
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        std::cerr << "WSAStartup failed\n";
        return 1;
    }
#endif

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        std::cerr << "socket() failed\n";
        return 1;
    }

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(9000);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(sock, (sockaddr*)&addr, sizeof(addr)) < 0) {
        std::cerr << "bind() failed (port busy?)\n";
        close(sock);
#ifdef _WIN32
        WSACleanup();
#endif
        return 1;
    }

    std::cout << "Server listening on UDP port 9000\n";
    std::cout << "Ctrl+C to stop\n\n";

    char buf[1024];
    while (true) {
        sockaddr_in client{};
        socklen_t len = sizeof(client);

        int n = recvfrom(sock, buf, sizeof(buf), 0, (sockaddr*)&client, &len);
        if (n < (int)sizeof(PacketHeader)) {
            std::cout << "[WARN] short packet: " << n << " bytes\n";
            continue;
        }

        PacketHeader h;
        memcpy(&h, buf, sizeof(h));
        logPacket(client, h);

        switch (h.type) {
            case MOVEMENT: {
                if (h.payloadSize != sizeof(MovementCmd)) {
                    std::cout << "[WARN] bad MOVEMENT size\n";
                    break;
                }
                MovementCmd cmd;
                memcpy(&cmd, buf + sizeof(PacketHeader), sizeof(cmd));
                onMovement(cmd);
                break;
            }
            case SHOOT: {
                if (h.payloadSize != sizeof(ShootCmd)) {
                    std::cout << "[WARN] bad SHOOT size\n";
                    break;
                }
                ShootCmd cmd;
                memcpy(&cmd, buf + sizeof(PacketHeader), sizeof(cmd));
                onShoot(cmd);
                break;
            }
            default:
                std::cout << "[WARN] unknown type=" << (int)h.type << "\n";
                break;
        }

        // Эхо клиенту — для отладки.
        sendto(sock, buf, n, 0, (sockaddr*)&client, len);
    }

    close(sock);
#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}
