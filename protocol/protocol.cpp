// protocol/protocol.cpp
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

void WriteU32(std::vector<std::uint8_t>& out, std::uint32_t v) {
    for (int shift = 24; shift >= 0; shift -= 8) {
        out.push_back(static_cast<std::uint8_t>(v >> shift));
    }
}

void WriteI16(std::vector<std::uint8_t>& out, std::int16_t v) {
    WriteU16(out, static_cast<std::uint16_t>(v));
}

std::optional<std::uint32_t> ReadU32(const std::uint8_t*& p, const std::uint8_t* end) {
    if (end - p < 4) return std::nullopt;
    std::uint32_t v = 0;
    for (int i = 0; i < 4; ++i) {
        v = (v << 8) | static_cast<std::uint32_t>(*p++);
    }
    return v;
}

std::optional<std::int16_t> ReadI16(const std::uint8_t*& p, const std::uint8_t* end) {
    auto u = ReadU16(p, end);
    if (!u) return std::nullopt;
    return static_cast<std::int16_t>(*u);
}

static void WriteHeader(std::vector<std::uint8_t>& out, PacketType type,
                         std::uint16_t sequenceNumber, std::uint16_t payloadSize,
                         bool requiresAck = false) {
    WriteU8(out, static_cast<std::uint8_t>(type));
    WriteU16(out, sequenceNumber);
    WriteU16(out, payloadSize);
    WriteU16(out, kProtocolVersion);
    WriteU8(out, requiresAck ? 1 : 0);
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

std::vector<std::uint8_t> SerializeMovement(std::uint16_t sequenceNumber, std::uint16_t x, std::uint16_t y,
                                             bool requiresAck) {
    std::vector<std::uint8_t> out;
    out.reserve(kMovementPacketSize);
    WriteHeader(out, PacketType::Movement, sequenceNumber, static_cast<std::uint16_t>(kMovementPayloadSize),
                requiresAck);
    WriteU16(out, x);
    WriteU16(out, y);
    return out;
}

std::vector<std::uint8_t> SerializeShoot(std::uint16_t sequenceNumber, std::uint16_t aimAngleDeg,
                                          std::uint8_t weaponId, bool requiresAck) {
    std::vector<std::uint8_t> out;
    out.reserve(kShootPacketSize);
    WriteHeader(out, PacketType::Shoot, sequenceNumber, static_cast<std::uint16_t>(kShootPayloadSize),
                requiresAck);
    WriteU16(out, aimAngleDeg);
    WriteU8(out, weaponId);
    return out;
}

std::vector<std::uint8_t> SerializeAck(std::uint16_t sequenceNumber, std::uint16_t acknowledgedSequence) {
    std::vector<std::uint8_t> out;
    out.reserve(kAckPacketSize);
    // ACK никогда не требует собственного подтверждения -> requiresAck = 0.
    WriteHeader(out, PacketType::Ack, sequenceNumber, static_cast<std::uint16_t>(kAckPayloadSize), false);
    WriteU16(out, acknowledgedSequence);
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
    auto rawRequiresAck = ReadU8(p, end);
    if (!rawType || !seq || !payloadSize || !version || !rawRequiresAck) return std::nullopt;

    const bool knownGameType = *rawType >= static_cast<std::uint8_t>(PacketType::Ping) &&
                               *rawType <= static_cast<std::uint8_t>(PacketType::Roster);
    const bool knownSecurityType = *rawType == static_cast<std::uint8_t>(PacketType::KeyExchange) ||
                                   *rawType == static_cast<std::uint8_t>(PacketType::Encrypted);
    if (!knownGameType && !knownSecurityType) {
        return std::nullopt; // неизвестный тип пакета (13 и 14 — только Godot, C++ их не принимает)
    }
    if (*version != kProtocolVersion) {
        return std::nullopt; // несовместимая версия протокола
    }
    if (*rawRequiresAck > 1) {
        return std::nullopt; // requiresAck — флаг, допустимы только 0 и 1
    }

    Header h;
    h.packetType = static_cast<PacketType>(*rawType);
    h.sequenceNumber = *seq;
    h.payloadSize = *payloadSize;
    h.protocolVersion = *version;
    h.requiresAck = (*rawRequiresAck == 1);
    return h;
}

std::optional<PingPacket> ParsePing(const std::uint8_t* data, std::size_t size) {
    auto header = ReadHeader(data, size);
    if (!header || header->packetType != PacketType::Ping) return std::nullopt;
    if (header->requiresAck) return std::nullopt; // PING/PONG подтверждений не требуют

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
    if (header->requiresAck) return std::nullopt; // PING/PONG подтверждений не требуют

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

std::optional<MovementPacket> ParseMovement(const std::uint8_t* data, std::size_t size) {
    auto header = ReadHeader(data, size);
    if (!header || header->packetType != PacketType::Movement) return std::nullopt;
    if (header->payloadSize != kMovementPayloadSize) return std::nullopt;
    if (size != kHeaderSize + kMovementPayloadSize) return std::nullopt;

    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    auto x = ReadU16(p, end);
    auto y = ReadU16(p, end);
    if (!x || !y || p != end) return std::nullopt;

    MovementPacket pkt;
    pkt.sequenceNumber = header->sequenceNumber;
    pkt.requiresAck = header->requiresAck;
    pkt.x = *x;
    pkt.y = *y;
    return pkt;
}

std::optional<ShootPacket> ParseShoot(const std::uint8_t* data, std::size_t size) {
    auto header = ReadHeader(data, size);
    if (!header || header->packetType != PacketType::Shoot) return std::nullopt;
    if (header->payloadSize != kShootPayloadSize) return std::nullopt;
    if (size != kHeaderSize + kShootPayloadSize) return std::nullopt;

    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    auto angle = ReadU16(p, end);
    auto weapon = ReadU8(p, end);
    if (!angle || !weapon || p != end) return std::nullopt;

    ShootPacket pkt;
    pkt.sequenceNumber = header->sequenceNumber;
    pkt.requiresAck = header->requiresAck;
    pkt.aimAngleDeg = *angle;
    pkt.weaponId = *weapon;
    return pkt;
}

std::optional<AckPacket> ParseAck(const std::uint8_t* data, std::size_t size) {
    auto header = ReadHeader(data, size);
    if (!header || header->packetType != PacketType::Ack) return std::nullopt;
    if (header->requiresAck) return std::nullopt; // ACK на ACK не бывает
    if (header->payloadSize != kAckPayloadSize) return std::nullopt;
    if (size != kHeaderSize + kAckPayloadSize) return std::nullopt;

    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    auto acked = ReadU16(p, end);
    if (!acked || p != end) return std::nullopt;

    AckPacket pkt;
    pkt.sequenceNumber = header->sequenceNumber;
    pkt.payload.acknowledgedSequence = *acked;
    return pkt;
}


// ====================== Игровые пакеты ======================

static void WriteHeaderFull(std::vector<std::uint8_t>& out, PacketType type, std::uint16_t seq,
                             std::size_t payloadSize, bool requiresAck) {
    WriteHeader(out, type, seq, static_cast<std::uint16_t>(payloadSize), requiresAck);
}

// Общая проверка: тип, requiresAck строго как у типа, payloadSize == фактический хвост.
static std::optional<Header> CheckGameHeader(const std::uint8_t* data, std::size_t size,
                                              PacketType type, bool requiresAck) {
    auto header = ReadHeader(data, size);
    if (!header || header->packetType != type) return std::nullopt;
    if (header->requiresAck != requiresAck) return std::nullopt;
    if (size != kHeaderSize + header->payloadSize) return std::nullopt;
    return header;
}

std::vector<std::uint8_t> SerializeHello(std::uint16_t seq, std::uint8_t gameProto, std::uint8_t colorIdx,
                                          const std::vector<std::uint8_t>& name) {
    const std::size_t nameLen = name.size() > kMaxNameBytes ? kMaxNameBytes : name.size();
    std::vector<std::uint8_t> out;
    WriteHeaderFull(out, PacketType::Hello, seq, 3 + nameLen, true);
    WriteU8(out, gameProto);
    WriteU8(out, colorIdx);
    WriteU8(out, static_cast<std::uint8_t>(nameLen));
    out.insert(out.end(), name.begin(), name.begin() + static_cast<std::ptrdiff_t>(nameLen));
    return out;
}

std::vector<std::uint8_t> SerializeWelcome(std::uint16_t seq, const WelcomePacket& w) {
    std::vector<std::uint8_t> out;
    WriteHeaderFull(out, PacketType::Welcome, seq, 1 + 1 + 1 + 2 + 1 + 4, true);
    WriteU8(out, w.status);
    WriteU8(out, w.gameProto);
    WriteU8(out, w.playerId);
    WriteU16(out, w.serverTick);
    WriteU8(out, w.tickRateHz);
    WriteU32(out, w.seed);
    return out;
}

std::vector<std::uint8_t> SerializeInput(std::uint16_t seq, std::uint16_t firstCmdSeq,
                                          const std::vector<InputCmd>& cmds) {
    const std::size_t n = cmds.size() > kMaxInputCmds ? kMaxInputCmds : cmds.size();
    std::vector<std::uint8_t> out;
    WriteHeaderFull(out, PacketType::Input, seq, 2 + 1 + 2 * n, false);
    WriteU16(out, firstCmdSeq);
    WriteU8(out, static_cast<std::uint8_t>(n));
    for (std::size_t i = 0; i < n; ++i) {
        WriteU8(out, static_cast<std::uint8_t>(cmds[i].axis));
        WriteU8(out, cmds[i].buttons);
    }
    return out;
}

std::vector<std::uint8_t> SerializeSnapshot(std::uint16_t seq, const SnapshotPacket& s) {
    const std::size_t np = s.players.size() > kMaxSnapshotPlayers ? kMaxSnapshotPlayers : s.players.size();
    const std::size_t no = s.ownerState.size() > kMaxOwnerStateBytes ? kMaxOwnerStateBytes : s.ownerState.size();
    const std::size_t nr = s.runes.size() > kMaxSnapshotRunes ? kMaxSnapshotRunes : s.runes.size();
    std::vector<std::uint8_t> out;
    WriteHeaderFull(out, PacketType::Snapshot, seq, 2 + 2 + 1 + 13 * np + 1 + no + 1 + 6 * nr, false);
    WriteU16(out, s.tick);
    WriteU16(out, s.ackCmdSeq);
    WriteU8(out, static_cast<std::uint8_t>(np));
    for (std::size_t i = 0; i < np; ++i) {
        const PlayerEntry& e = s.players[i];
        WriteU8(out, e.id);
        WriteI16(out, e.x);
        WriteI16(out, e.y);
        WriteI16(out, e.vx);
        WriteI16(out, e.vy);
        WriteU8(out, e.hp);
        WriteU8(out, e.flags);
        WriteU16(out, e.buffs);
    }
    WriteU8(out, static_cast<std::uint8_t>(no));
    out.insert(out.end(), s.ownerState.begin(), s.ownerState.begin() + static_cast<std::ptrdiff_t>(no));
    WriteU8(out, static_cast<std::uint8_t>(nr));
    for (std::size_t i = 0; i < nr; ++i) {
        const RuneEntry& r = s.runes[i];
        WriteU8(out, r.id);
        WriteU8(out, r.type);
        WriteI16(out, r.x);
        WriteI16(out, r.y);
    }
    return out;
}

std::vector<std::uint8_t> SerializeGameEvent(std::uint16_t seq, const GameEventPacket& e) {
    std::vector<std::uint8_t> out;
    WriteHeaderFull(out, PacketType::GameEvent, seq, kGameEventPayloadSize, true);
    WriteU16(out, e.eventId);
    WriteU8(out, e.kind);
    WriteU16(out, e.tick);
    WriteU8(out, e.a);
    WriteU8(out, e.b);
    WriteI16(out, e.x);
    WriteI16(out, e.y);
    WriteI16(out, e.v);
    return out;
}

std::vector<std::uint8_t> SerializeLeave(std::uint16_t seq, std::uint8_t reason) {
    std::vector<std::uint8_t> out;
    WriteHeaderFull(out, PacketType::Leave, seq, 1, true);
    WriteU8(out, reason);
    return out;
}

std::optional<HelloPacket> ParseHello(const std::uint8_t* data, std::size_t size) {
    auto h = CheckGameHeader(data, size, PacketType::Hello, true);
    if (!h) return std::nullopt;
    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    auto proto = ReadU8(p, end);
    auto color = ReadU8(p, end);
    auto nameLen = ReadU8(p, end);
    if (!proto || !color || !nameLen) return std::nullopt;
    if (*nameLen > kMaxNameBytes || end - p != *nameLen) return std::nullopt;
    HelloPacket pkt;
    pkt.sequenceNumber = h->sequenceNumber;
    pkt.gameProto = *proto;
    pkt.colorIdx = *color;
    pkt.name.assign(p, end);
    return pkt;
}

std::optional<WelcomePacket> ParseWelcome(const std::uint8_t* data, std::size_t size) {
    auto h = CheckGameHeader(data, size, PacketType::Welcome, true);
    if (!h) return std::nullopt;
    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    auto status = ReadU8(p, end);
    auto proto = ReadU8(p, end);
    auto id = ReadU8(p, end);
    auto tick = ReadU16(p, end);
    auto rate = ReadU8(p, end);
    auto seed = ReadU32(p, end);
    if (!status || !proto || !id || !tick || !rate || !seed || p != end) return std::nullopt;
    WelcomePacket pkt;
    pkt.sequenceNumber = h->sequenceNumber;
    pkt.status = *status;
    pkt.gameProto = *proto;
    pkt.playerId = *id;
    pkt.serverTick = *tick;
    pkt.tickRateHz = *rate;
    pkt.seed = *seed;
    return pkt;
}

std::optional<InputPacket> ParseInput(const std::uint8_t* data, std::size_t size) {
    auto h = CheckGameHeader(data, size, PacketType::Input, false);
    if (!h) return std::nullopt;
    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    auto first = ReadU16(p, end);
    auto count = ReadU8(p, end);
    if (!first || !count) return std::nullopt;
    if (*count < 1 || *count > kMaxInputCmds || end - p != 2 * static_cast<std::ptrdiff_t>(*count)) return std::nullopt;
    InputPacket pkt;
    pkt.sequenceNumber = h->sequenceNumber;
    pkt.firstCmdSeq = *first;
    for (std::uint8_t i = 0; i < *count; ++i) {
        InputCmd c;
        c.axis = static_cast<std::int8_t>(*ReadU8(p, end));
        c.buttons = *ReadU8(p, end);
        pkt.cmds.push_back(c);
    }
    return pkt;
}

std::optional<SnapshotPacket> ParseSnapshot(const std::uint8_t* data, std::size_t size) {
    auto h = CheckGameHeader(data, size, PacketType::Snapshot, false);
    if (!h) return std::nullopt;
    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    SnapshotPacket pkt;
    pkt.sequenceNumber = h->sequenceNumber;
    auto tick = ReadU16(p, end);
    auto ack = ReadU16(p, end);
    auto np = ReadU8(p, end);
    if (!tick || !ack || !np || *np > kMaxSnapshotPlayers) return std::nullopt;
    pkt.tick = *tick;
    pkt.ackCmdSeq = *ack;
    for (std::uint8_t i = 0; i < *np; ++i) {
        if (end - p < 13) return std::nullopt;
        PlayerEntry e;
        e.id = *ReadU8(p, end);
        e.x = *ReadI16(p, end);
        e.y = *ReadI16(p, end);
        e.vx = *ReadI16(p, end);
        e.vy = *ReadI16(p, end);
        e.hp = *ReadU8(p, end);
        e.flags = *ReadU8(p, end);
        e.buffs = *ReadU16(p, end);
        pkt.players.push_back(e);
    }
    auto no = ReadU8(p, end);
    if (!no || *no > kMaxOwnerStateBytes || end - p < static_cast<std::ptrdiff_t>(*no)) return std::nullopt;
    pkt.ownerState.assign(p, p + *no);
    p += *no;
    auto nr = ReadU8(p, end);
    if (!nr || *nr > kMaxSnapshotRunes || end - p != 6 * static_cast<std::ptrdiff_t>(*nr)) return std::nullopt;
    for (std::uint8_t i = 0; i < *nr; ++i) {
        RuneEntry r;
        r.id = *ReadU8(p, end);
        r.type = *ReadU8(p, end);
        r.x = *ReadI16(p, end);
        r.y = *ReadI16(p, end);
        pkt.runes.push_back(r);
    }
    return pkt;
}

std::optional<GameEventPacket> ParseGameEvent(const std::uint8_t* data, std::size_t size) {
    auto h = CheckGameHeader(data, size, PacketType::GameEvent, true);
    if (!h || h->payloadSize != kGameEventPayloadSize) return std::nullopt;
    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    auto id = ReadU16(p, end);
    auto kind = ReadU8(p, end);
    auto tick = ReadU16(p, end);
    auto a = ReadU8(p, end);
    auto b = ReadU8(p, end);
    auto x = ReadI16(p, end);
    auto y = ReadI16(p, end);
    auto v = ReadI16(p, end);
    if (!id || !kind || !tick || !a || !b || !x || !y || !v || p != end) return std::nullopt;
    GameEventPacket pkt;
    pkt.sequenceNumber = h->sequenceNumber;
    pkt.eventId = *id;
    pkt.kind = *kind;
    pkt.tick = *tick;
    pkt.a = *a;
    pkt.b = *b;
    pkt.x = *x;
    pkt.y = *y;
    pkt.v = *v;
    return pkt;
}

std::optional<LeavePacket> ParseLeave(const std::uint8_t* data, std::size_t size) {
    auto h = CheckGameHeader(data, size, PacketType::Leave, true);
    if (!h || h->payloadSize != 1) return std::nullopt;
    LeavePacket pkt;
    pkt.sequenceNumber = h->sequenceNumber;
    pkt.reason = data[kHeaderSize];
    return pkt;
}


std::vector<std::uint8_t> SerializeRoster(std::uint16_t seq, const std::vector<RosterEntry>& entries) {
    const std::size_t n = entries.size() > kMaxRoster ? kMaxRoster : entries.size();
    std::size_t payload = 1;
    for (std::size_t i = 0; i < n; ++i) {
        payload += 4 + (entries[i].name.size() > kMaxNameBytes ? kMaxNameBytes : entries[i].name.size());
    }
    std::vector<std::uint8_t> out;
    WriteHeaderFull(out, PacketType::Roster, seq, payload, true);
    WriteU8(out, static_cast<std::uint8_t>(n));
    for (std::size_t i = 0; i < n; ++i) {
        const RosterEntry& e = entries[i];
        const std::size_t len = e.name.size() > kMaxNameBytes ? kMaxNameBytes : e.name.size();
        WriteU8(out, e.id);
        WriteU8(out, e.color);
        WriteU8(out, e.flags);
        WriteU8(out, static_cast<std::uint8_t>(len));
        out.insert(out.end(), e.name.begin(), e.name.begin() + static_cast<std::ptrdiff_t>(len));
    }
    return out;
}

std::optional<RosterPacket> ParseRoster(const std::uint8_t* data, std::size_t size) {
    auto h = CheckGameHeader(data, size, PacketType::Roster, true);
    if (!h) return std::nullopt;
    const std::uint8_t* p = data + kHeaderSize;
    const std::uint8_t* end = data + size;
    auto n = ReadU8(p, end);
    if (!n || *n > kMaxRoster) return std::nullopt;
    RosterPacket pkt;
    pkt.sequenceNumber = h->sequenceNumber;
    for (std::uint8_t i = 0; i < *n; ++i) {
        auto id = ReadU8(p, end);
        auto color = ReadU8(p, end);
        auto flags = ReadU8(p, end);
        auto len = ReadU8(p, end);
        if (!id || !color || !flags || !len || *len > kMaxNameBytes || end - p < *len) return std::nullopt;
        RosterEntry e;
        e.id = *id; e.color = *color; e.flags = *flags;
        e.name.assign(p, p + *len);
        p += *len;
        pkt.entries.push_back(e);
    }
    if (p != end) return std::nullopt;
    return pkt;
}

// ====================== ПР №6: KEY_EXCHANGE / ENCRYPTED ======================

std::vector<std::uint8_t> SerializeKeyExchange(std::uint16_t seq, const std::uint8_t publicKey[32]) {
    std::vector<std::uint8_t> out;
    out.reserve(kHeaderSize + kKeyExchangePayloadSize);
    WriteHeaderFull(out, PacketType::KeyExchange, seq, kKeyExchangePayloadSize, false);
    out.insert(out.end(), publicKey, publicKey + kKeyExchangePayloadSize);
    return out;
}

std::optional<KeyExchangePacket> ParseKeyExchange(const std::uint8_t* data, std::size_t size) {
    auto h = CheckGameHeader(data, size, PacketType::KeyExchange, false);
    if (!h || h->payloadSize != kKeyExchangePayloadSize) return std::nullopt;
    KeyExchangePacket pkt{};
    pkt.sequenceNumber = h->sequenceNumber;
    std::copy(data + kHeaderSize, data + kHeaderSize + kKeyExchangePayloadSize, pkt.publicKey);
    return pkt;
}

std::vector<std::uint8_t> SerializeEncryptedHeader(std::uint16_t seq, bool requiresAck, std::size_t sealedSize) {
    std::vector<std::uint8_t> out;
    out.reserve(kHeaderSize);
    WriteHeaderFull(out, PacketType::Encrypted, seq, sealedSize, requiresAck);
    return out;
}

std::optional<Header> CheckEncryptedHeader(const std::uint8_t* data, std::size_t size) {
    auto h = ReadHeader(data, size);
    if (!h || h->packetType != PacketType::Encrypted) return std::nullopt;
    if (size != kHeaderSize + h->payloadSize) return std::nullopt;
    if (h->payloadSize < kEncryptedOverhead) return std::nullopt;
    return h;
}

} // namespace telemetry
