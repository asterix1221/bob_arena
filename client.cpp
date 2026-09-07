// client.cpp — UDP-клиент для Smash Arena
// Практика №1: шлёт MOVEMENT раз в секунду, иногда SHOOT, ловит ответ.
// По умолчанию подключается к 127.0.0.1:9000. Для игры по сети:
//   client.exe 192.168.1.42
//
// Сборка:
//   Linux/macOS:  g++ client.cpp -o client
//   MinGW:        g++ client.cpp -o client.exe -lws2_32
//   MSVC:         cl /EHsc client.cpp ws2_32.lib

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
#include <chrono>
#include <thread>

// ---------- Протокол (должен совпадать с server.cpp) ----------

#pragma pack(push, 1)

struct PacketHeader {
    uint8_t  type;
    uint16_t seqNumber;
    uint8_t  payloadSize;
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

// ---------- Хелперы ----------

void sendPacket(int sock, const sockaddr_in& to, const void* packet, int len) {
    sendto(sock, (const char*)packet, len, 0, (sockaddr*)&to, sizeof(to));
}

void buildMovement(char* outBuf, int& outLen, uint8_t playerId, int8_t dx, int8_t dy, uint16_t seq) {
    PacketHeader* h = (PacketHeader*)outBuf;
    h->type = MOVEMENT;
    h->seqNumber = seq;
    h->payloadSize = sizeof(MovementCmd);

    MovementCmd* cmd = (MovementCmd*)(outBuf + sizeof(PacketHeader));
    cmd->playerId = playerId;
    cmd->dx = dx;
    cmd->dy = dy;

    outLen = sizeof(PacketHeader) + sizeof(MovementCmd);
}

void buildShoot(char* outBuf, int& outLen, uint8_t playerId, uint8_t weaponId,
                int8_t dirX, int8_t dirY, uint8_t targetId, uint16_t seq) {
    PacketHeader* h = (PacketHeader*)outBuf;
    h->type = SHOOT;
    h->seqNumber = seq;
    h->payloadSize = sizeof(ShootCmd);

    ShootCmd* cmd = (ShootCmd*)(outBuf + sizeof(PacketHeader));
    cmd->playerId = playerId;
    cmd->weaponId = weaponId;
    cmd->dirX = dirX;
    cmd->dirY = dirY;
    cmd->aimTargetId = targetId;

    outLen = sizeof(PacketHeader) + sizeof(ShootCmd);
}

const char* typeName(uint8_t t) {
    switch (t) {
        case MOVEMENT: return "MOVEMENT";
        case SHOOT:    return "SHOOT";
        case STATE:    return "STATE";
        default:       return "UNKNOWN";
    }
}

// ---------- main ----------

int main(int argc, char** argv) {
    const char* serverIp = "127.0.0.1";
    if (argc > 1) serverIp = argv[1];

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

    sockaddr_in server{};
    server.sin_family = AF_INET;
    server.sin_port = htons(9000);
    if (inet_pton(AF_INET, serverIp, &server.sin_addr) != 1) {
        std::cerr << "bad IP: " << serverIp << "\n";
        return 1;
    }

    // Таймаут на recv, чтобы не блокироваться вечно
    timeval tv{};
    tv.tv_sec = 0;
    tv.tv_usec = 200000; // 200 мс
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));

    std::cout << "Client started, target " << serverIp << ":9000\n";
    std::cout << "Tick rate: 1 Hz (will be raised to 20-30 Hz later)\n";
    std::cout << "Every 3rd tick sends SHOOT to demo both packet types\n\n";

    char packet[64];
    int  packetLen = 0;
    uint16_t seq = 0;
    int tick = 0;

    while (true) {
        if (tick % 3 == 2) {
            buildShoot(packet, packetLen, 0, 1, 1, 0, 255, seq++);
            std::cout << "[client] send SHOOT    seq=" << seq - 1 << "\n";
        } else {
            int8_t dx = 0, dy = 0;
            switch (tick % 4) {
                case 0: dx =  1; break;
                case 1: dy =  1; break;
                case 2: dx = -1; break;
                case 3: dy = -1; break;
            }
            buildMovement(packet, packetLen, 0, dx, dy, seq++);
            std::cout << "[client] send MOVEMENT seq=" << seq - 1
                      << " dir=(" << (int)dx << "," << (int)dy << ")\n";
        }

        sendPacket(sock, server, packet, packetLen);

        char buf[1024];
        sockaddr_in from{};
        socklen_t flen = sizeof(from);
        int n = recvfrom(sock, buf, sizeof(buf), 0, (sockaddr*)&from, &flen);
        if (n > 0 && n >= (int)sizeof(PacketHeader)) {
            PacketHeader rh;
            memcpy(&rh, buf, sizeof(rh));
            std::cout << "[client] got echo     type=" << typeName(rh.type)
                      << " seq=" << rh.seqNumber
                      << " bytes=" << n << "\n";
        } else {
            std::cout << "[client] no response (timeout)\n";
        }

        tick++;
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }

    close(sock);
#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}
