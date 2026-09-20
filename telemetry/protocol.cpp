// telemetry/protocol.cpp
#include "protocol.h"

namespace telemetry {

void WriteU8(std::vector<std::uint8_t>& out, std::uint8_t v) {
    out.push_back(v);
}

void WriteU16(std::vector<std::uint8_t>& out, std::uint16_t v) {
    out.push_back(static_cast<std::uint8_t>(v >> 8));
    out.push_back(static_cast<std::uint8_t>(v));
}

void WriteU64(std::vector<std::uint8_t>& out, std::uint64_t v) {
    for (int shift = 56; shift >= 0; shift -= 8) {
        out.push_back(static_cast<std::uint8_t>(v >> shift));
    }
}

std::optional<std::uint8_t> ReadU8(const std::uint8_t*& p, const std::uint8_t* end) {
    if (end - p < 1) return std::nullopt;
    std::uint8_t v = *p;
    p += 1;
    return v;
}

std::optional<std::uint16_t> ReadU16(const std::uint8_t*& p, const std::uint8_t* end) {
    if (end - p < 2) return std::nullopt;
    std::uint16_t v = static_cast<std::uint16_t>((p[0] << 8) | p[1]);
    p += 2;
    return v;
}

std::optional<std::uint64_t> ReadU64(const std::uint8_t*& p, const std::uint8_t* end) {
    if (end - p < 8) return std::nullopt;
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) {
        v = (v << 8) | static_cast<std::uint64_t>(*p++);
    }
    return v;
}

static void WriteHeader(std::vector<std::uint8_t>& out, PacketType type,
                         std::uint16_t sequenceNumber, std::uint16_t payloadSize) {
    WriteU8(out, static_cast<std::uint8_t>(type));
    WriteU16(out, sequenceNumber);
    WriteU16(out, payloadSize);
    WriteU16(out, kProtocolVersion);
}

std::vector<std::uint8_t> SerializePing(std::uint16_t sequenceNumber, std::uint64_t clientSendTimeUs) {
    std::vector<std::uint8_t> out;
    out.reserve(kPingPacketSize);
    WriteHeader(out, PacketType::Ping, sequenceNumber, static_cast<std::uint16_t>(kPingPayloadSize));
    WriteU64(out, clientSendTimeUs);
    return out;
}

std::vector<std::uint8_t> SerializePong(std::uint16_t sequenceNumber,
                                         std::uint64_t clientSendTimeUs,
                                         std::uint64_t serverReceiveTimeUs,
                                         std::uint64_t serverSendTimeUs) {
    std::vector<std::uint8_t> out;
    out.reserve(kPongPacketSize);
    WriteHeader(out, PacketType::Pong, sequenceNumber, static_cast<std::uint16_t>(kPongPayloadSize));
    WriteU64(out, clientSendTimeUs);
    WriteU64(out, serverReceiveTimeUs);
    WriteU64(out, serverSendTimeUs);
    return out;
}

std::optional<Header> ReadHeader(const std::uint8_t* data, std::size_t size) {
    if (data == nullptr || size < kHeaderSize) return std::nullopt;
    const std::uint8_t* p = data;
    const std::uint8_t* end = data + size;

    auto rawType = ReadU8(p, end);
    auto seq = ReadU16(p, end);
    auto payloadSize = ReadU16(p, end);
    auto version = ReadU16(p, end);
    if (!rawType || !seq || !payloadSize || !version) return std::nullopt;

    if (*rawType != static_cast<std::uint8_t>(PacketType::Ping) &&
        *rawType != static_cast<std::uint8_t>(PacketType::Pong)) {
        return std::nullopt; // неизвестный тип пакета
    }
    if (*version != kProtocolVersion) {
        return std::nullopt; // несовместимая версия протокола
    }

    Header h;
    h.packetType = static_cast<PacketType>(*rawType);
    h.sequenceNumber = *seq;
    h.payloadSize = *payloadSize;
    h.protocolVersion = *version;
    return h;
}

std::optional<PingPacket> ParsePing(const std::uint8_t* data, std::size_t size) {
    auto header = ReadHeader(data, size);
    if (!header || header->packetType != PacketType::Ping) return std::nullopt;

    // payloadSize из заголовка обязан совпадать и с ожидаемым размером payload
    // PING, и с фактическим "хвостом" датаграммы после заголовка.
    if (header->payloadSize != kPingPayloadSize) return std::nullopt;
    if (size != kHeaderSize + kPingPayloadSize) return std::nullopt;

    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    auto sendTime = ReadU64(p, end);
    if (!sendTime || p != end) return std::nullopt;

    PingPacket pkt;
    pkt.sequenceNumber = header->sequenceNumber;
    pkt.clientSendTimeUs = *sendTime;
    return pkt;
}

std::optional<PongPacket> ParsePong(const std::uint8_t* data, std::size_t size) {
    auto header = ReadHeader(data, size);
    if (!header || header->packetType != PacketType::Pong) return std::nullopt;

    if (header->payloadSize != kPongPayloadSize) return std::nullopt;
    if (size != kHeaderSize + kPongPayloadSize) return std::nullopt;

    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    auto clientSendTime = ReadU64(p, end);
    auto serverRecvTime = ReadU64(p, end);
    auto serverSendTime = ReadU64(p, end);
    if (!clientSendTime || !serverRecvTime || !serverSendTime || p != end) return std::nullopt;

    PongPacket pkt;
    pkt.sequenceNumber = header->sequenceNumber;
    pkt.clientSendTimeUs = *clientSendTime;
    pkt.serverReceiveTimeUs = *serverRecvTime;
    pkt.serverSendTimeUs = *serverSendTime;
    return pkt;
}

} // namespace telemetry
