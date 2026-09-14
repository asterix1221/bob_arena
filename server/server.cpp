// server.cpp
// UDP-сервер сквозного проекта. Принимает пакеты от клиентов,
// обрабатывает игровые команды (MOVEMENT, SHOOT, ATTACK_*, AUTH_REQUEST)
// и отправляет обратно подтверждение / обновлённое состояние.
// Сервер авторитетен: он хранит и валидирует позицию каждого игрока
// (простая проверка границ арены), а не просто отражает то, что
// прислал клиент.

#include "../common/net_common.h"
#include "../common/protocol.h"

#include <unordered_map>
#include <algorithm> // std::min / std::max (обрезка координат по границам арены)
#include <ctime>
#include <cstdlib>

// Границы центральной арены (условные, см. docs/Architecture_Design.md)
static constexpr float ARENA_MIN_X = -50.0f, ARENA_MAX_X = 50.0f;
static constexpr float ARENA_MIN_Y = 0.0f,   ARENA_MAX_Y = 50.0f;
static constexpr float ARENA_MIN_Z = -50.0f, ARENA_MAX_Z = 50.0f;

struct PlayerState {
    uint32_t id;
    float x = 0, y = 0, z = 0;
    uint16_t health = 100;
    bool authorized = false;
};

// Заранее заданный список пользователей для простой авторизации
// (доп. задание). В реальном проекте — не хардкодить пароли в исходниках.
static bool checkCredentials(const char* login, const char* password) {
    struct Cred { const char* login; const char* password; };
    static const Cred creds[] = {
        {"player1", "pass1"},
        {"player2", "pass2"}
    };
    for (const auto& c : creds) {
        if (std::strcmp(login, c.login) == 0 && std::strcmp(password, c.password) == 0) {
            return true;
        }
    }
    return false;
}

// std::localtime возвращает указатель на статический внутренний буфер и не
// потокобезопасен; на MSVC/UCRT дополнительно помечен как deprecated
// (C4996: "This function or variable may be unsafe... consider using
// localtime_s instead"). Используем потокобезопасный вариант под каждую
// платформу: localtime_s на Windows (обратный порядок аргументов —
// сначала tm*, потом time_t*), localtime_r на POSIX/MinGW.
static std::tm safeLocalTime(std::time_t t) {
    std::tm result{};
#if defined(_WIN32)
    localtime_s(&result, &t);
#else
    localtime_r(&t, &result);
#endif
    return result;
}

static void logLine(const std::string& endpoint, const char* what) {
    std::time_t t = std::time(nullptr);
    std::tm tmValue = safeLocalTime(t);
    char timeBuf[16];
    std::strftime(timeBuf, sizeof(timeBuf), "%H:%M:%S", &tmValue);
    std::printf("[%s] [%s] %s\n", timeBuf, endpoint.c_str(), what);
}

int main(int argc, char** argv) {
    // Отключаем буферизацию stdout: иначе при перенаправлении лога в файл
    // (server_app > server.log) записи появляются только после закрытия
    // процесса, а не по мере поступления пакетов.
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    enable_utf8_console(); // иначе кириллица в консоли Windows выводится нечитаемыми символами

    uint16_t port = 27015;
    if (argc >= 2) port = static_cast<uint16_t>(std::atoi(argv[1]));

    if (!net_init()) {
        std::fprintf(stderr, "Не удалось инициализировать сетевую подсистему\n");
        return 1;
    }

    socket_t sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) {
        std::fprintf(stderr, "Не удалось создать сокет\n");
        return 1;
    }

    sockaddr_in serverAddr{};
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_addr.s_addr = INADDR_ANY;
    serverAddr.sin_port = htons(port);

    if (bind(sock, (sockaddr*)&serverAddr, sizeof(serverAddr)) == SOCK_ERR) {
        std::fprintf(stderr, "Не удалось выполнить bind на порт %d\n", port);
        CLOSESOCKET(sock);
        return 1;
    }

    std::printf("UDP-сервер запущен на порту %d. Ожидание пакетов...\n", port);

    std::unordered_map<std::string, PlayerState> players;
    uint32_t nextPlayerId = 1;

    char buffer[1024];

    for (;;) {
        sockaddr_in clientAddr{};
        socklen_t clientAddrLen = sizeof(clientAddr);

        int received = recvfrom(sock, buffer, sizeof(buffer), 0,
                                 (sockaddr*)&clientAddr, &clientAddrLen);
        if (received == SOCK_ERR) {
            continue; // без таймаута на сервере — просто продолжаем ждать
        }
        if (received < (int)sizeof(PacketHeader)) {
            continue; // пакет короче заголовка — отбрасываем
        }

        std::string endpoint = endpoint_to_string(clientAddr);

        PacketHeader header;
        std::memcpy(&header, buffer, sizeof(PacketHeader));

        const uint8_t* payload = reinterpret_cast<const uint8_t*>(buffer) + sizeof(PacketHeader);
        size_t availablePayload = received - sizeof(PacketHeader);

        if (header.payloadSize > availablePayload) {
            logLine(endpoint, "отброшен: payloadSize больше фактических данных");
            continue;
        }

        // Проверка целостности (доп. задание)
        uint32_t actualChecksum = crc32(payload, header.payloadSize);
        if (actualChecksum != header.checksum) {
            logLine(endpoint, "отброшен: несовпадение CRC32 (повреждённый пакет)");
            continue;
        }

        // Получаем/создаём состояние игрока по его адресу
        auto it = players.find(endpoint);
        if (it == players.end()) {
            PlayerState newPlayer;
            newPlayer.id = nextPlayerId++;
            it = players.emplace(endpoint, newPlayer).first;
        }
        PlayerState& player = it->second;

        char logMsg[160];

        switch (static_cast<PacketType>(header.packetType)) {
            case PacketType::AUTH_REQUEST: {
                AuthPayload auth{};
                std::memcpy(&auth, payload, sizeof(AuthPayload));
                // Данные пришли по сети и могут не содержать завершающего
                // нуля (например, если прислали ровно 32 непустых байта) —
                // принудительно терминируем перед strcmp, иначе возможно
                // чтение за пределами массива.
                auth.login[sizeof(auth.login) - 1] = '\0';
                auth.password[sizeof(auth.password) - 1] = '\0';
                bool ok = checkCredentials(auth.login, auth.password);
                player.authorized = ok;

                std::snprintf(logMsg, sizeof(logMsg), "AUTH_REQUEST login='%s' -> %s",
                              auth.login, ok ? "УСПЕХ" : "ОТКАЗ");
                logLine(endpoint, logMsg);

                AuthResponsePayload resp{ static_cast<uint8_t>(ok ? 1 : 0) };
                PacketHeader outHeader;
                outHeader.packetType = static_cast<uint8_t>(PacketType::AUTH_RESPONSE);
                outHeader.sequenceNumber = header.sequenceNumber;
                outHeader.payloadSize = sizeof(resp);
                outHeader.checksum = crc32(reinterpret_cast<uint8_t*>(&resp), sizeof(resp));

                char outBuf[sizeof(PacketHeader) + sizeof(AuthResponsePayload)];
                std::memcpy(outBuf, &outHeader, sizeof(outHeader));
                std::memcpy(outBuf + sizeof(outHeader), &resp, sizeof(resp));
                sendto(sock, outBuf, sizeof(outBuf), 0, (sockaddr*)&clientAddr, clientAddrLen);
                break;
            }

            case PacketType::MOVEMENT: {
                if (!player.authorized) {
                    logLine(endpoint, "MOVEMENT отклонён: клиент не авторизован");
                    break;
                }
                MovementPayload move{};
                std::memcpy(&move, payload, sizeof(MovementPayload));

                // Сервер авторитетен: обрезаем координаты по границам арены,
                // а не просто доверяем клиенту (базовая защита от читов).
                player.x = std::min(std::max(move.x, ARENA_MIN_X), ARENA_MAX_X);
                player.y = std::min(std::max(move.y, ARENA_MIN_Y), ARENA_MAX_Y);
                player.z = std::min(std::max(move.z, ARENA_MIN_Z), ARENA_MAX_Z);

                std::snprintf(logMsg, sizeof(logMsg),
                              "MOVEMENT seq=%u pos=(%.2f, %.2f, %.2f) playerId=%u",
                              header.sequenceNumber, player.x, player.y, player.z, player.id);
                logLine(endpoint, logMsg);

                StateUpdatePayload state{ player.id, player.x, player.y, player.z, player.health };
                PacketHeader outHeader;
                outHeader.packetType = static_cast<uint8_t>(PacketType::STATE_UPDATE);
                outHeader.sequenceNumber = header.sequenceNumber;
                outHeader.payloadSize = sizeof(state);
                outHeader.checksum = crc32(reinterpret_cast<uint8_t*>(&state), sizeof(state));

                char outBuf[sizeof(PacketHeader) + sizeof(StateUpdatePayload)];
                std::memcpy(outBuf, &outHeader, sizeof(outHeader));
                std::memcpy(outBuf + sizeof(outHeader), &state, sizeof(state));
                sendto(sock, outBuf, sizeof(outBuf), 0, (sockaddr*)&clientAddr, clientAddrLen);
                break;
            }

            case PacketType::SHOOT: {
                if (!player.authorized) {
                    logLine(endpoint, "SHOOT отклонён: клиент не авторизован");
                    break;
                }
                ShootPayload shoot{};
                std::memcpy(&shoot, payload, sizeof(ShootPayload));

                std::snprintf(logMsg, sizeof(logMsg), "SHOOT seq=%u weaponId=%u playerId=%u",
                              header.sequenceNumber, shoot.weaponId, player.id);
                logLine(endpoint, logMsg);

                PacketHeader outHeader;
                outHeader.packetType = static_cast<uint8_t>(PacketType::ACK);
                outHeader.sequenceNumber = header.sequenceNumber;
                outHeader.payloadSize = 0;
                outHeader.checksum = crc32(nullptr, 0);

                sendto(sock, reinterpret_cast<char*>(&outHeader), sizeof(outHeader), 0,
                       (sockaddr*)&clientAddr, clientAddrLen);
                break;
            }

            case PacketType::ATTACK_LIGHT:
            case PacketType::ATTACK_HEAVY: {
                AttackPayload atk{};
                std::memcpy(&atk, payload, sizeof(AttackPayload));
                std::snprintf(logMsg, sizeof(logMsg), "%s seq=%u playerId=%u",
                              header.packetType == static_cast<uint8_t>(PacketType::ATTACK_LIGHT)
                                  ? "ATTACK_LIGHT" : "ATTACK_HEAVY",
                              header.sequenceNumber, player.id);
                logLine(endpoint, logMsg);

                PacketHeader outHeader;
                outHeader.packetType = static_cast<uint8_t>(PacketType::ACK);
                outHeader.sequenceNumber = header.sequenceNumber;
                outHeader.payloadSize = 0;
                outHeader.checksum = crc32(nullptr, 0);
                sendto(sock, reinterpret_cast<char*>(&outHeader), sizeof(outHeader), 0,
                       (sockaddr*)&clientAddr, clientAddrLen);
                break;
            }

            default:
                std::snprintf(logMsg, sizeof(logMsg), "Неизвестный/пока не реализованный тип пакета: %u",
                              header.packetType);
                logLine(endpoint, logMsg);
                break;
        }
    }

    CLOSESOCKET(sock);
    net_shutdown();
    return 0;
}
