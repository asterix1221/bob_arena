// reliability/dedup_window.cpp
#include "dedup_window.hpp"

namespace reliability {

bool DedupWindow::MarkProcessed(std::uint16_t sequence) {
    if (seen_.count(sequence) > 0) return false;

    if (order_.size() >= capacity_) {
        seen_.erase(order_.front());
        order_.pop_front();
    }
    order_.push_back(sequence);
    seen_.insert(sequence);
    return true;
}

} // namespace reliability
