// tests/test_dash_rules.cpp — ПР №4: правила рывка (Source/BobArenaPrediction/DashRules.h).
// Чистая логика без Unreal Engine: проверяем то, на чём держится серверная валидация и
// детерминизм предсказания (одинаковая последовательность dt => одинаковое состояние).
#include "mini_test.h"
#include "../Source/BobArenaPrediction/DashRules.h"

using namespace BobDash;

TEST_CASE("ПР4 Dash: свежее состояние допускает рывок на земле") {
    Config C; State S;
    REQUIRE(Validate(S, C, true) == Reject::None);
}

TEST_CASE("ПР4 Dash: в воздухе рывок отклоняется (NotGrounded)") {
    Config C; State S;
    REQUIRE(Validate(S, C, false) == Reject::NotGrounded);
}

TEST_CASE("ПР4 Dash: Begin тратит выносливость, ставит кулдаун и длительность") {
    Config C; State S;
    Begin(S, C);
    REQUIRE_APPROX(S.Stamina, C.StaminaMax - C.StaminaCost, 1e-6);
    REQUIRE_APPROX(S.CooldownRemaining, C.Cooldown, 1e-6);
    REQUIRE_APPROX(S.DashTimeRemaining, C.Duration, 1e-6);
    REQUIRE(S.IsDashing());
}

TEST_CASE("ПР4 Dash: во время рывка повторный рывок — AlreadyDashing") {
    Config C; State S;
    Begin(S, C);
    REQUIRE(Validate(S, C, true) == Reject::AlreadyDashing);
}

TEST_CASE("ПР4 Dash: после рывка, но до конца кулдауна — OnCooldown") {
    Config C; State S;
    Begin(S, C);
    Tick(S, C, C.Duration + 0.01f);   // рывок закончился
    REQUIRE_FALSE(S.IsDashing());
    REQUIRE(Validate(S, C, true) == Reject::OnCooldown);
}

TEST_CASE("ПР4 Dash: после кулдауна рывок снова допустим") {
    Config C; State S;
    Begin(S, C);
    Tick(S, C, C.Cooldown + 0.01f);
    REQUIRE(Validate(S, C, true) == Reject::None);
}

TEST_CASE("ПР4 Dash: допуск кулдауна не пропускает рывок заметно раньше срока") {
    Config C; State S;
    Begin(S, C);
    Tick(S, C, C.Cooldown - 0.2f);    // осталось 0.2 с >> допуска 0.03 с
    REQUIRE(Validate(S, C, true) == Reject::OnCooldown);
    Tick(S, C, 0.18f);                // осталось 0.02 с <= допуска
    REQUIRE(Validate(S, C, true) == Reject::None);
}

TEST_CASE("ПР4 Dash: без выносливости рывок отклоняется (NoStamina)") {
    Config C; State S;
    S.Stamina = C.StaminaCost - 1.f;
    REQUIRE(Validate(S, C, true) == Reject::NoStamina);
}

TEST_CASE("ПР4 Dash: выносливость восстанавливается и не превышает максимум") {
    Config C; State S;
    S.Stamina = 0.f;
    Tick(S, C, 1.f);
    REQUIRE_APPROX(S.Stamina, C.StaminaRegenPerSec, 1e-4);
    Tick(S, C, 100.f);
    REQUIRE_APPROX(S.Stamina, C.StaminaMax, 1e-6);
}

TEST_CASE("ПР4 Dash: выносливость не растёт на ходе, начатом во время рывка") {
    Config C; State S;
    Begin(S, C);
    const float Before = S.Stamina;
    Tick(S, C, 0.05f);                // рывок ещё идёт
    REQUIRE_APPROX(S.Stamina, Before, 1e-6);
}

TEST_CASE("ПР4 Dash: серия Begin ограничена выносливостью (2 рывка при запасе 100 и цене 35)") {
    Config C; C.Cooldown = 0.f; C.StaminaRegenPerSec = 0.f;
    State S; int Accepted = 0;
    for (int i = 0; i < 10; ++i)
    {
        if (Validate(S, C, true) == Reject::None) { Begin(S, C); ++Accepted; }
        Tick(S, C, C.Duration + 0.01f);
    }
    REQUIRE(Accepted == 2);           // 100 -> 65 -> 30 -> (30 < 35, отказ)
}

TEST_CASE("ПР4 Dash: детерминизм — одинаковые dt дают одинаковое состояние (основа reconciliation)") {
    Config C; State A, B;
    const float Dts[] = {0.016f, 0.017f, 0.033f, 0.016f, 0.05f, 0.016f, 0.016f, 0.2f, 0.016f, 1.4f};
    Begin(A, C); Begin(B, C);
    for (float Dt : Dts) { Tick(A, C, Dt); Tick(B, C, Dt); }
    REQUIRE(A.CooldownRemaining == B.CooldownRemaining);
    REQUIRE(A.Stamina == B.Stamina);
    REQUIRE(A.DashTimeRemaining == B.DashTimeRemaining);
}

TEST_CASE("ПР4 Dash: снимок состояния (как в SavedMove) восстанавливает прошлый результат") {
    Config C; State S;
    Begin(S, C);
    Tick(S, C, 0.05f);
    const State Snapshot = S;         // SetMoveFor: состояние ДО хода
    Tick(S, C, 0.1f); Tick(S, C, 0.1f);
    State Replay = Snapshot;          // PrepMoveFor: возврат к состоянию до хода
    Tick(Replay, C, 0.1f); Tick(Replay, C, 0.1f);
    REQUIRE(Replay.CooldownRemaining == S.CooldownRemaining);
    REQUIRE(Replay.Stamina == S.Stamina);
    REQUIRE(Replay.DashTimeRemaining == S.DashTimeRemaining);
}

TEST_CASE("ПР4 Dash: клиент с «читом» (кулдаун обнулён) расходится с сервером — сервер отклоняет") {
    Config C;
    State Server, Client;
    Begin(Server, C); Begin(Client, C);
    Tick(Server, C, 0.3f); Tick(Client, C, 0.3f);
    Client.CooldownRemaining = 0.f; Client.Stamina = C.StaminaMax;   // читерская правка на клиенте
    REQUIRE(Validate(Client, C, true) == Reject::None);              // клиент предсказал бы рывок
    REQUIRE(Validate(Server, C, true) == Reject::OnCooldown);        // сервер авторитетно отказывает
}

TEST_CASE("ПР4 Dash: ToString покрывает все причины отказа") {
    REQUIRE(std::string(ToString(Reject::OnCooldown)) == "cooldown");
    REQUIRE(std::string(ToString(Reject::NoStamina)) == "no_stamina");
    REQUIRE(std::string(ToString(Reject::NotGrounded)) == "not_grounded");
    REQUIRE(std::string(ToString(Reject::AlreadyDashing)) == "already_dashing");
    REQUIRE(std::string(ToString(Reject::None)) == "none");
}
