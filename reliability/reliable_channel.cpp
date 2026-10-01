// reliability/reliable_channel.cpp
#include "reliable_channel.hpp"

#include <algorithm>
#include <utility>

namespace reliability {

void ReliableChannel::OnSent(std::uint16_t sequence, std::vector<std::uint8_t> rawBytes, std::uint64_t nowUs) {
    PendingPacket p;
    p.rawBytes = std::move(rawBytes);
    p.lastSentAtUs = nowUs;
    p.firstSentAtUs = nowUs;
    p.attempts = 1;
    pending_[sequence] = std::move(p);
}

bool ReliableChannel::OnAckReceived(std::uint16_t sequence) {
    return pending_.erase(sequence) > 0;
}

bool ReliableChannel::OnAckReceived(std::uint16_t sequence, std::uint64_t nowUs, AckInfo& info) {
    auto it = pending_.find(sequence);
    if (it == pending_.end()) return false; // дубликат ACK / неизвестный пакет / уже failed

    info.attempts = it->second.attempts;
    info.timeToAckUs = nowUs >= it->second.firstSentAtUs ? nowUs - it->second.firstSentAtUs : 0;
    pending_.erase(it);
    return true;
}

std::vector<PendingPacket*> ReliableChannel::CollectForRetransmission(
        std::uint64_t nowUs, std::uint64_t adaptiveTimeoutUs, std::vector<std::uint16_t>* newlyFailed) {
    std::vector<std::pair<std::uint16_t, PendingPacket*>> due;
    std::vector<std::uint16_t> exhausted;

    for (auto& [sequence, packet] : pending_) {
        if (nowUs < packet.lastSentAtUs || nowUs - packet.lastSentAtUs < adaptiveTimeoutUs) continue;

        if (packet.attempts >= maxAttempts_) {
            exhausted.push_back(sequence); // все попытки использованы, и ACK так и не пришёл
        } else {
            due.emplace_back(sequence, &packet);
        }
    }

    // Порядок обхода unordered_map не определён — для воспроизводимости сортируем.
    std::sort(exhausted.begin(), exhausted.end());
    for (std::uint16_t sequence : exhausted) {
        pending_.erase(sequence);
        failed_.push_back(sequence);
        if (newlyFailed) newlyFailed->push_back(sequence);
    }

    std::sort(due.begin(), due.end(), [](const auto& a, const auto& b) {
        if (a.second->firstSentAtUs != b.second->firstSentAtUs) {
            return a.second->firstSentAtUs < b.second->firstSentAtUs;
        }
        return a.first < b.first;
    });

    std::vector<PendingPacket*> result;
    result.reserve(due.size());
    for (auto& [sequence, packet] : due) {
        ++packet->attempts;
        packet->lastSentAtUs = nowUs;
        result.push_back(packet);
    }
    return result;
}

} // namespace reliability
