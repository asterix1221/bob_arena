// reliability/adaptive_timeout.cpp
#include "adaptive_timeout.hpp"

#include <algorithm>
#include <cmath>

namespace reliability {

void AdaptiveTimeout::OnSample(double rttMs) {
    if (!(rttMs >= 0.0)) return; // отрицательные значения и NaN

    if (!initialized_) {
        srttMs_ = rttMs;
        rttVarMs_ = rttMs / 2.0;
        initialized_ = true;
        return;
    }
    rttVarMs_ = (1.0 - kBeta) * rttVarMs_ + kBeta * std::abs(srttMs_ - rttMs);
    srttMs_ = (1.0 - kAlpha) * srttMs_ + kAlpha * rttMs;
}

double AdaptiveTimeout::RtoMs() const {
    const double raw = initialized_ ? (srttMs_ + 4.0 * rttVarMs_) : kInitialRtoMs;
    return std::clamp(raw, kMinRtoMs, kMaxRtoMs);
}

std::uint64_t AdaptiveTimeout::RtoUs() const {
    return static_cast<std::uint64_t>(RtoMs() * 1000.0);
}

} // namespace reliability
