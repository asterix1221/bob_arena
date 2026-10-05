// DashRules.h
//
// Правила рывка (dash) в виде чистого C++ БЕЗ зависимостей от Unreal Engine.
// Это сознательное решение: одни и те же функции вызываются и клиентом (предсказание),
// и сервером (авторитетная проверка) из UBobMovementComponent, а ещё их можно собрать
// обычным g++ и покрыть юнит-тестами (tests/test_dash_rules.cpp) без запуска движка.
//
// Все таймеры продвигаются ТОЛЬКО на DeltaTime хода (а не по часам мира) — поэтому
// повторное проигрывание сохранённых ходов на клиенте после коррекции даёт тот же
// результат, что и серверная симуляция тех же ходов.
#pragma once

#include <algorithm>

namespace BobDash
{
struct Config
{
    float Cooldown = 1.5f;            // сек между стартами рывков
    float Duration = 0.20f;           // сек длительности рывка
    float Speed = 1800.f;             // см/с (uu/s) во время рывка
    float StaminaMax = 100.f;
    float StaminaCost = 35.f;         // цена одного рывка
    float StaminaRegenPerSec = 20.f;  // восстановление, пока рывок не идёт
    float CooldownTolerance = 0.03f;  // допуск на дрожание dt клиент/сервер (одинаков на обеих сторонах)
};

struct State
{
    float CooldownRemaining = 0.f;
    float Stamina = 100.f;
    float DashTimeRemaining = 0.f;

    bool IsDashing() const { return DashTimeRemaining > 0.f; }
};

enum class Reject : unsigned char
{
    None = 0,
    NotGrounded,
    AlreadyDashing,
    OnCooldown,
    NoStamina
};

inline const char* ToString(Reject R)
{
    switch (R)
    {
    case Reject::None:           return "none";
    case Reject::NotGrounded:    return "not_grounded";
    case Reject::AlreadyDashing: return "already_dashing";
    case Reject::OnCooldown:     return "cooldown";
    case Reject::NoStamina:      return "no_stamina";
    }
    return "unknown";
}

// Проверка допустимости рывка. Ничего не меняет.
inline Reject Validate(const State& S, const Config& C, bool bGrounded)
{
    if (!bGrounded)                                   return Reject::NotGrounded;
    if (S.IsDashing())                                return Reject::AlreadyDashing;
    if (S.CooldownRemaining > C.CooldownTolerance)    return Reject::OnCooldown;
    if (S.Stamina < C.StaminaCost)                    return Reject::NoStamina;
    return Reject::None;
}

// Старт рывка: вызывать только после успешной Validate.
inline void Begin(State& S, const Config& C)
{
    S.Stamina = std::max(0.f, S.Stamina - C.StaminaCost);
    S.CooldownRemaining = C.Cooldown;
    S.DashTimeRemaining = C.Duration;
}

// Продвинуть таймеры на dt хода (после движения).
inline void Tick(State& S, const Config& C, float Dt)
{
    const bool bWasDashing = S.IsDashing();
    S.DashTimeRemaining = std::max(0.f, S.DashTimeRemaining - Dt);
    S.CooldownRemaining = std::max(0.f, S.CooldownRemaining - Dt);
    if (!bWasDashing)
    {
        S.Stamina = std::min(C.StaminaMax, S.Stamina + C.StaminaRegenPerSec * Dt);
    }
}
} // namespace BobDash
