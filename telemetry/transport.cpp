// telemetry/transport.cpp
#include "transport.h"

#include <cstring>

namespace telemetry {

UdpTransport::UdpTransport() {
    netInitialized_ = net_init();
}

UdpTransport::~UdpTransport() {
    Close();
    if (netInitialized_) {
        net_shutdown();
    }
}

bool UdpTransport::OpenClient(const std::string& serverIp, std::uint16_t port, int recvTimeoutMs) {
    if (!netInitialized_) return false;

    socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket_ == INVALID_SOCKET) return false;

    if (recvTimeoutMs > 0) {
        set_recv_timeout(socket_, recvTimeoutMs);
    }

    std::memset(&defaultTarget_, 0, sizeof(defaultTarget_));
    defaultTarget_.sin_family = AF_INET;
    defaultTarget_.sin_port = htons(port);
    if (inet_pton(AF_INET, serverIp.c_str(), &defaultTarget_.sin_addr) != 1) {
        CLOSESOCKET(socket_);
        socket_ = INVALID_SOCKET;
        return false;
    }
    hasDefaultTarget_ = true;
    isOpen_ = true;
    return true;
}

bool UdpTransport::OpenServer(std::uint16_t port, int recvTimeoutMs) {
    if (!netInitialized_) return false;

    socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket_ == INVALID_SOCKET) return false;

    if (recvTimeoutMs > 0) {
        set_recv_timeout(socket_, recvTimeoutMs);
    }

    sockaddr_in bindAddr{};
    bindAddr.sin_family = AF_INET;
    bindAddr.sin_addr.s_addr = INADDR_ANY;
    bindAddr.sin_port = htons(port);

    if (bind(socket_, (sockaddr*)&bindAddr, sizeof(bindAddr)) == SOCK_ERR) {
        CLOSESOCKET(socket_);
        socket_ = INVALID_SOCKET;
        return false;
    }
    isOpen_ = true;
    return true;
}

bool UdpTransport::Send(const std::uint8_t* data, std::size_t size, const sockaddr_in* to) {
    if (!isOpen_) return false;

    const sockaddr_in* target = to ? to : (hasDefaultTarget_ ? &defaultTarget_ : nullptr);
    if (!target) return false;

    int sent = sendto(socket_, reinterpret_cast<const char*>(data), static_cast<int>(size), 0,
                       (const sockaddr*)target, sizeof(*target));
    return sent != SOCK_ERR && static_cast<std::size_t>(sent) == size;
}

RecvResult UdpTransport::Receive(std::uint8_t* buffer, std::size_t bufferSize, std::size_t& outSize, sockaddr_in& fromAddr) {
    if (!isOpen_) return RecvResult::Error;

    socklen_t fromLen = sizeof(fromAddr);
    int received = recvfrom(socket_, reinterpret_cast<char*>(buffer), static_cast<int>(bufferSize), 0,
                             (sockaddr*)&fromAddr, &fromLen);
    if (received == SOCK_ERR) {
        // Разделять "тайм-аут" и "настоящую ошибку сокета" переносимо между
        // Winsock и Berkeley sockets неудобно (разные коды/способы их узнать),
        // а для целей этой практической работы это и не требуется: тайм-аут
        // recv — ожидаемый штатный случай при потере/большой задержке пакета,
        // поэтому трактуем любую неудачу recvfrom как TimedOut, а не Error.
        return RecvResult::TimedOut;
    }
    outSize = static_cast<std::size_t>(received);
    return RecvResult::Data;
}

void UdpTransport::Close() {
    if (isOpen_) {
        CLOSESOCKET(socket_);
        socket_ = INVALID_SOCKET;
        isOpen_ = false;
    }
}

} // namespace telemetry
