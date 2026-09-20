// telemetry/transport.h
//
// Тонкая обёртка над UDP-сокетом для подсистемы телеметрии. Модуль знает
// ТОЛЬКО о передаче сырых байт по сети (открыть сокет, отправить буфер,
// принять буфер, выставить тайм-аут) — он ничего не знает ни о формате
// пакетов PING/PONG (см. protocol.h), ни о расчёте RTT/SRTT (см. telemetry.h).
// Переиспользует общие кроссплатформенные примитивы common/net_common.h,
// чтобы не дублировать код инициализации Winsock/Berkeley sockets.

#pragma once

#include "../common/net_common.h"

#include <cstdint>
#include <cstddef>
#include <string>

namespace telemetry {

// Результат Receive(): различаем "пришли данные", "истёк тайм-аут ожидания"
// и "ошибка сокета", чтобы вызывающий код (ping_client/pong_server) мог
// корректно отличить потерю/задержку пакета от сбоя самой сети.
enum class RecvResult { Data, TimedOut, Error };

class UdpTransport {
public:
    UdpTransport();
    ~UdpTransport();

    UdpTransport(const UdpTransport&) = delete;
    UdpTransport& operator=(const UdpTransport&) = delete;

    // Клиентский режим: создаёт сокет, "подключает" его к serverIp:port
    // (connect() на UDP-сокете не устанавливает соединение, но фиксирует
    // адрес по умолчанию для send()/recv()) и выставляет тайм-аут приёма.
    bool OpenClient(const std::string& serverIp, std::uint16_t port, int recvTimeoutMs);

    // Серверный режим: создаёт сокет и делает bind() на указанный порт
    // (INADDR_ANY). Тайм-аут приёма опционален (0 = ждать бесконечно,
    // как в PR №1); для симуляции задержки ответа сервер сам решает,
    // сколько спать между Receive() и Send(), это не забота транспорта.
    bool OpenServer(std::uint16_t port, int recvTimeoutMs = 0);

    // Отправка по адресу, ранее полученному через Receive() (роль сервера,
    // отвечающего конкретному клиенту), либо по адресу, зафиксированному
    // OpenClient() (roleClient, when 'to' == nullptr).
    bool Send(const std::uint8_t* data, std::size_t size, const sockaddr_in* to = nullptr);

    // Принимает один пакет. buffer/bufferSize — куда класть сырые байты,
    // outSize — фактически принятый размер, fromAddr — адрес отправителя
    // (нужен серверу, чтобы знать, кому отвечать).
    RecvResult Receive(std::uint8_t* buffer, std::size_t bufferSize, std::size_t& outSize, sockaddr_in& fromAddr);

    bool IsOpen() const { return isOpen_; }
    void Close();

private:
    socket_t socket_ = INVALID_SOCKET;
    bool isOpen_ = false;
    bool netInitialized_ = false;
    sockaddr_in defaultTarget_{}; // используется клиентом как адрес по умолчанию
    bool hasDefaultTarget_ = false;
};

} // namespace telemetry
