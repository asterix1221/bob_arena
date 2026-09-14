// client.cpp
// UDP-клиент сквозного проекта. Сначала авторизуется на сервере
// (логин/пароль), затем раз в секунду отправляет команды MOVEMENT и
// SHOOT по очереди, печатая ответ сервера.
//
// Использование:
//   client <server_ip> <port> <login> <password> [iterations]
// По умолчанию: 127.0.0.1 27015 player1 pass1 10

#include "../common/net_common.h"
#include "../common/protocol.h"

#include <thread>
#include <chrono>
#include <cstdlib>
#include <vector>
#include <cstring>

static uint16_t g_seq = 0;

// Отправляет пакет (заголовок + payload) и ждёт ответ с таймаутом.
// Возвращает true, если ответ получен.
static bool sendAndReceive(socket_t sock, const sockaddr_in& serverAddr,
                            PacketType type, const void* payload, uint16_t payloadSize,
                            char* respBuf, int respBufSize, int& respLen) {
    PacketHeader header;
    header.packetType = static_cast<uint8_t>(type);
    header.sequenceNumber = g_seq++;
    header.payloadSize = payloadSize;
    header.checksum = crc32(reinterpret_cast<const uint8_t*>(payload), payloadSize);

    std::vector<char> outBuf(sizeof(PacketHeader) + payloadSize);
    std::memcpy(outBuf.data(), &header, sizeof(header));
    if (payloadSize > 0) {
        std::memcpy(outBuf.data() + sizeof(header), payload, payloadSize);
    }

    if (sendto(sock, outBuf.data(), (int)outBuf.size(), 0,
               (const sockaddr*)&serverAddr, sizeof(serverAddr)) == SOCK_ERR) {
        std::fprintf(stderr, "Ошибка отправки пакета\n");
        return false;
    }

    sockaddr_in fromAddr{};
    socklen_t fromLen = sizeof(fromAddr);
    respLen = recvfrom(sock, respBuf, respBufSize, 0, (sockaddr*)&fromAddr, &fromLen);
    return respLen != SOCK_ERR && respLen >= (int)sizeof(PacketHeader);
}

int main(int argc, char** argv) {
    enable_utf8_console(); // иначе кириллица в консоли Windows выводится нечитаемыми символами

    const char* serverIp = argc >= 2 ? argv[1] : "127.0.0.1";
    uint16_t port = argc >= 3 ? static_cast<uint16_t>(std::atoi(argv[2])) : 27015;
    const char* login = argc >= 4 ? argv[3] : "player1";
    const char* password = argc >= 5 ? argv[4] : "pass1";
    int iterations = argc >= 6 ? std::atoi(argv[5]) : 10;

    if (!net_init()) {
        std::fprintf(stderr, "Не удалось инициализировать сетевую подсистему\n");
        return 1;
    }

    socket_t sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) {
        std::fprintf(stderr, "Не удалось создать сокет\n");
        return 1;
    }
    set_recv_timeout(sock, 2000); // 2 секунды на ответ, иначе считаем пакет потерянным

    sockaddr_in serverAddr{};
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_port = htons(port);
    inet_pton(AF_INET, serverIp, &serverAddr.sin_addr);

    char respBuf[256];
    int respLen = 0;

    // --- Авторизация ---
    AuthPayload auth{};
    // std::snprintf вместо strncpy: гарантированно завершает строку нулём
    // и не зависит от того, обнулён ли буфер заранее (strncpy этого не
    // гарантирует, если источник длиннее или равен размеру буфера).
    std::snprintf(auth.login, sizeof(auth.login), "%s", login);
    std::snprintf(auth.password, sizeof(auth.password), "%s", password);

    if (!sendAndReceive(sock, serverAddr, PacketType::AUTH_REQUEST, &auth, sizeof(auth), respBuf, sizeof(respBuf), respLen)) {
        std::fprintf(stderr, "Сервер не ответил на AUTH_REQUEST (таймаут)\n");
        CLOSESOCKET(sock);
        net_shutdown();
        return 1;
    }
    PacketHeader authRespHeader;
    std::memcpy(&authRespHeader, respBuf, sizeof(authRespHeader));
    AuthResponsePayload authResp{};
    std::memcpy(&authResp, respBuf + sizeof(authRespHeader), sizeof(authResp));

    if (!authResp.success) {
        std::printf("Авторизация отклонена сервером. Проверьте логин/пароль.\n");
        CLOSESOCKET(sock);
        net_shutdown();
        return 1;
    }
    std::printf("Авторизация успешна. Начинаю отправку команд...\n");

    // --- Периодическая отправка команд ---
    float posX = 0.0f;
    for (int i = 0; i < iterations; ++i) {
        bool sendMovement = (i % 2 == 0);

        if (sendMovement) {
            posX += 1.5f; // имитация движения персонажа вправо
            MovementPayload move{ posX, 0.0f, 0.0f };

            if (sendAndReceive(sock, serverAddr, PacketType::MOVEMENT, &move, sizeof(move), respBuf, sizeof(respBuf), respLen)) {
                PacketHeader h;
                std::memcpy(&h, respBuf, sizeof(h));
                StateUpdatePayload state{};
                std::memcpy(&state, respBuf + sizeof(h), sizeof(state));
                std::printf("[%d] MOVEMENT отправлен (x=%.2f) -> сервер подтвердил позицию (%.2f, %.2f, %.2f), health=%u\n",
                            i, posX, state.x, state.y, state.z, state.health);
            } else {
                std::printf("[%d] MOVEMENT: ответ от сервера не получен (таймаут)\n", i);
            }
        } else {
            ShootPayload shoot{ static_cast<uint8_t>(1 + (i % 3)) }; // имитация разного оружия
            if (sendAndReceive(sock, serverAddr, PacketType::SHOOT, &shoot, sizeof(shoot), respBuf, sizeof(respBuf), respLen)) {
                std::printf("[%d] SHOOT отправлен (weaponId=%u) -> сервер подтвердил (ACK)\n", i, shoot.weaponId);
            } else {
                std::printf("[%d] SHOOT: ответ от сервера не получен (таймаут)\n", i);
            }
        }

        std::this_thread::sleep_for(std::chrono::seconds(1));
    }

    CLOSESOCKET(sock);
    net_shutdown();
    return 0;
}
