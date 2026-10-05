#pragma once

#include "CoreMinimal.h"
#include "GameFramework/Character.h"
#include "BobCharacter.generated.h"

class UBobMovementComponent;
class USpringArmComponent;
class UCameraComponent;
class UStaticMeshComponent;

/**
 * Персонаж: камера «от третьего лица», визуал из примитивов движка (без ассетов),
 * ввод, игровое действие «рывок» и обратная связь сервера (принято/отклонено).
 */
UCLASS()
class BOBARENAPREDICTION_API ABobCharacter : public ACharacter
{
	GENERATED_BODY()

public:
	ABobCharacter(const FObjectInitializer& ObjectInitializer);

	UBobMovementComponent* GetBobMovement() const;

	// Режим клиента: bob.PredictDash 1 = с предсказанием, 0 = рывок только после ответа сервера.
	static bool IsDashPredictionEnabled();

	// Вызывается из CMC на сервере.
	void ServerOnDashAccepted();
	void ServerOnDashRejected(uint8 Reason, float Cooldown, float Stamina);
	// Вызывается из CMC на клиенте-владельце в момент ЛОКАЛЬНОГО (предсказанного) старта рывка.
	void OnLocalDashPredicted();

	// Для HUD.
	double LastResponseMs = -1.0;
	FString LastResponseKind = TEXT("-");
	FString LastRejectReason = TEXT("-");

	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

protected:
	virtual void SetupPlayerInputComponent(UInputComponent* PlayerInputComponent) override;
	virtual void Tick(float DeltaSeconds) override;

	UFUNCTION(Client, Unreliable)
	void ClientDashRejected(uint8 Reason, float Cooldown, float Stamina);

	// Увеличивается на сервере при КАЖДОМ принятом рывке (реплицируется всем).
	UPROPERTY(ReplicatedUsing = OnRep_AcceptedDashCount)
	uint8 AcceptedDashCount = 0;

	UFUNCTION()
	void OnRep_AcceptedDashCount();

private:
	UPROPERTY(VisibleAnywhere) TObjectPtr<USpringArmComponent> CameraBoom;
	UPROPERTY(VisibleAnywhere) TObjectPtr<UCameraComponent> FollowCamera;
	UPROPERTY(VisibleAnywhere) TObjectPtr<UStaticMeshComponent> Body;
	UPROPERTY(VisibleAnywhere) TObjectPtr<UStaticMeshComponent> Nose;

	void ApplyMoveInput(EAxis::Type Axis, float Value);
	void MoveForwardPos(float V) { ApplyMoveInput(EAxis::X, V); }
	void MoveForwardNeg(float V) { ApplyMoveInput(EAxis::X, -V); }
	void MoveRightPos(float V) { ApplyMoveInput(EAxis::Y, V); }
	void MoveRightNeg(float V) { ApplyMoveInput(EAxis::Y, -V); }
	void LookYaw(float V) { AddControllerYawInput(V); }
	void LookPitch(float V) { AddControllerPitchInput(-V); }
	void RequestDash();

	double LastDashKeyTime = 0.0;
	bool bAwaitingDashResponse = false;
	double VisualDashUntil = 0.0;   // косметика: «сплющивание» корпуса во время рывка
};
