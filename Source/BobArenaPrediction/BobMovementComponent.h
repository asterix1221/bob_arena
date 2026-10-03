#pragma once

#include "CoreMinimal.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "DashRules.h"
#include "BobMovementComponent.generated.h"

class FSavedMove_Bob;

/**
 * CharacterMovementComponent с рывком (dash), встроенным в штатный механизм
 * SavedMove / ServerMove / ClientAdjustPosition:
 *  - клиент отправляет не координаты, а ФЛАГ намерения (FLAG_Custom_0 в compressed flags);
 *  - сервер сам проверяет правила (земля, кулдаун, выносливость) и сам считает результат;
 *  - состояние рывка (таймеры, направление) сохраняется в SavedMove и восстанавливается
 *    в PrepMoveFor перед повторным проигрыванием хода после серверной коррекции.
 */
UCLASS()
class BOBARENAPREDICTION_API UBobMovementComponent : public UCharacterMovementComponent
{
	GENERATED_BODY()

public:
	UBobMovementComponent();

	// ---- настройки рывка (Config в DashRules.h) ----
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Dash") float DashCooldown = 1.5f;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Dash") float DashDuration = 0.20f;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Dash") float DashSpeed = 1800.f;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Dash") float StaminaMax = 100.f;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Dash") float DashStaminaCost = 35.f;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Dash") float StaminaRegenPerSec = 20.f;

	// ---- вход (клиент): «хочу рывок» ----
	bool bWantsToDash = false;
	// ---- вход (сервер, вариант БЕЗ предсказания): запрос пришёл по RPC ----
	bool bServerDashRequested = false;

	// ---- состояние рывка (одинаково считается клиентом и сервером) ----
	BobDash::State DashState;
	FVector DashDirection = FVector::ForwardVector;

	// ---- ЧИТЫ для демонстрации расхождения (действуют ТОЛЬКО на клиенте-владельце) ----
	bool bCheatIgnoreDashRules = false;   // клиент игнорирует кулдаун/выносливость
	float CheatDashSpeedScale = 1.f;      // клиент считает рывок быстрее, чем сервер

	// ---- статистика коррекций (клиент-владелец) ----
	int32 CorrectionCount = 0;
	float LastCorrectionErrorUU = 0.f;

	BobDash::Config MakeDashConfig() const;

	// Авторитетное состояние сервера для клиента (после отказа сервера).
	void QueueServerStateSync(float Cooldown, float Stamina);

	// UCharacterMovementComponent
	virtual FNetworkPredictionData_Client* GetPredictionData_Client() const override;
	virtual void UpdateFromCompressedFlags(uint8 Flags) override;
	virtual bool ClientUpdatePositionAfterServerUpdate() override;

protected:
	virtual void UpdateCharacterStateBeforeMovement(float DeltaSeconds) override;
	virtual void UpdateCharacterStateAfterMovement(float DeltaSeconds) override;
	virtual void CalcVelocity(float DeltaTime, float Friction, bool bFluid, float BrakingDeceleration) override;

private:
	bool IsAutonomousClient() const;
	void TryStartDash(bool bFromServerRequest);

	bool bReplayingMoves = false;     // идёт повторное проигрывание после коррекции
	FVector LastPredictedLocation = FVector::ZeroVector;
	bool bHasPendingSync = false;
	float PendingSyncCooldown = 0.f;
	float PendingSyncStamina = 0.f;
};

/** Сохранённый ход с данными рывка. */
class FSavedMove_Bob : public FSavedMove_Character
{
public:
	typedef FSavedMove_Character Super;

	bool bSavedWantsToDash = false;
	bool bSavedDashActive = false;          // рывок в этом ходе (флаг или уже идёт) — такие ходы не объединяем
	BobDash::State SavedStartState;         // состояние рывка ДО хода
	FVector SavedDashDirection = FVector::ForwardVector;

	virtual void Clear() override;
	virtual uint8 GetCompressedFlags() const override;
	virtual bool CanCombineWith(const FSavedMovePtr& NewMove, ACharacter* InCharacter, float MaxDelta) const override;
	virtual void SetMoveFor(ACharacter* C, float InDeltaTime, FVector const& NewAccel, FNetworkPredictionData_Client_Character& ClientData) override;
	virtual void PrepMoveFor(ACharacter* C) override;
};

class FNetworkPredictionData_Client_Bob : public FNetworkPredictionData_Client_Character
{
public:
	typedef FNetworkPredictionData_Client_Character Super;
	FNetworkPredictionData_Client_Bob(const UCharacterMovementComponent& ClientMovement) : Super(ClientMovement) {}
	virtual FSavedMovePtr AllocateNewMove() override;
};
