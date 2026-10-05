#include "BobMovementComponent.h"
#include "BobArenaPrediction.h"
#include "BobCharacter.h"
#include "GameFramework/Character.h"
#include "Components/CapsuleComponent.h"

UBobMovementComponent::UBobMovementComponent()
{
	// Стандартные значения шаблона Third Person.
	MaxWalkSpeed = 500.f;
	JumpZVelocity = 700.f;
	AirControl = 0.35f;
	BrakingDecelerationWalking = 2000.f;
	bOrientRotationToMovement = true;
	RotationRate = FRotator(0.f, 540.f, 0.f);
	DashState.Stamina = StaminaMax;
}

BobDash::Config UBobMovementComponent::MakeDashConfig() const
{
	BobDash::Config C;
	C.Cooldown = DashCooldown;
	C.Duration = DashDuration;
	C.Speed = DashSpeed;
	C.StaminaMax = StaminaMax;
	C.StaminaCost = DashStaminaCost;
	C.StaminaRegenPerSec = StaminaRegenPerSec;
	return C;
}

bool UBobMovementComponent::IsAutonomousClient() const
{
	return CharacterOwner && CharacterOwner->GetLocalRole() == ROLE_AutonomousProxy;
}

void UBobMovementComponent::QueueServerStateSync(float Cooldown, float Stamina)
{
	bHasPendingSync = true;
	PendingSyncCooldown = Cooldown;
	PendingSyncStamina = Stamina;
}

// ------------------------------------------------------------------ сеть: флаги

void UBobMovementComponent::UpdateFromCompressedFlags(uint8 Flags)
{
	Super::UpdateFromCompressedFlags(Flags);
	// Сервер (и повтор хода на клиенте) получают ТОЛЬКО намерение, а не результат.
	bWantsToDash = (Flags & FSavedMove_Character::FLAG_Custom_0) != 0;
}

FNetworkPredictionData_Client* UBobMovementComponent::GetPredictionData_Client() const
{
	if (ClientPredictionData == nullptr)
	{
		UBobMovementComponent* MutableThis = const_cast<UBobMovementComponent*>(this);
		MutableThis->ClientPredictionData = new FNetworkPredictionData_Client_Bob(*this);
	}
	return ClientPredictionData;
}

// ------------------------------------------------------------------ рывок

void UBobMovementComponent::TryStartDash(bool bFromServerRequest)
{
	const BobDash::Config Cfg = MakeDashConfig();

	// Читерский клиент «считает», что кулдауна и расхода нет. Сервер этого не знает и проверит сам.
	BobDash::State Probe = DashState;
	if (bCheatIgnoreDashRules && IsAutonomousClient())
	{
		Probe.CooldownRemaining = 0.f;
		Probe.Stamina = Cfg.StaminaMax;
	}

	const BobDash::Reject Why = BobDash::Validate(Probe, Cfg, IsMovingOnGround());
	if (Why != BobDash::Reject::None)
	{
		if (CharacterOwner->HasAuthority())
		{
			UE_LOG(LogBobPrediction, Warning,
				TEXT("[DASH] SERVER REJECTED dash of %s: reason=%s cooldown=%.2f stamina=%.1f source=%s"),
				*GetNameSafe(CharacterOwner), ANSI_TO_TCHAR(BobDash::ToString(Why)),
				DashState.CooldownRemaining, DashState.Stamina, bFromServerRequest ? TEXT("rpc") : TEXT("move-flag"));
			if (ABobCharacter* Bob = Cast<ABobCharacter>(CharacterOwner))
			{
				Bob->ServerOnDashRejected(static_cast<uint8>(Why), DashState.CooldownRemaining, DashState.Stamina);
			}
		}
		return;
	}

	// Направление: из ускорения (ввода) этого хода; без ввода — вперёд. Клиент его не присылает.
	FVector Dir = Acceleration.GetSafeNormal2D();
	if (Dir.IsNearlyZero())
	{
		Dir = UpdatedComponent->GetForwardVector().GetSafeNormal2D();
	}
	DashDirection = Dir;
	BobDash::Begin(DashState, Cfg);

	if (CharacterOwner->HasAuthority())
	{
		UE_LOG(LogBobPrediction, Log, TEXT("[DASH] SERVER ACCEPTED dash of %s: stamina_left=%.1f"),
			*GetNameSafe(CharacterOwner), DashState.Stamina);
		if (ABobCharacter* Bob = Cast<ABobCharacter>(CharacterOwner))
		{
			Bob->ServerOnDashAccepted();
		}
	}
	else if (IsAutonomousClient() && !bReplayingMoves)
	{
		if (ABobCharacter* Bob = Cast<ABobCharacter>(CharacterOwner))
		{
			Bob->OnLocalDashPredicted();
		}
	}
}

void UBobMovementComponent::UpdateCharacterStateBeforeMovement(float DeltaSeconds)
{
	Super::UpdateCharacterStateBeforeMovement(DeltaSeconds);

	// Авторитетное состояние после отказа применяем к НОВОМУ ходу (после повторного проигрывания).
	if (bHasPendingSync && !bReplayingMoves)
	{
		DashState.CooldownRemaining = PendingSyncCooldown;
		DashState.Stamina = PendingSyncStamina;
		bHasPendingSync = false;
	}

	const bool bServerRequest = bServerDashRequested && CharacterOwner->HasAuthority();
	bServerDashRequested = false;

	if (bWantsToDash || bServerRequest)
	{
		TryStartDash(bServerRequest && !bWantsToDash);
	}
}

void UBobMovementComponent::UpdateCharacterStateAfterMovement(float DeltaSeconds)
{
	Super::UpdateCharacterStateAfterMovement(DeltaSeconds);

	BobDash::Tick(DashState, MakeDashConfig(), DeltaSeconds);
	bWantsToDash = false;   // одноразовый триггер: расход флага после хода

	if (IsAutonomousClient() && !bReplayingMoves && UpdatedComponent)
	{
		LastPredictedLocation = UpdatedComponent->GetComponentLocation();
	}
}

void UBobMovementComponent::CalcVelocity(float DeltaTime, float Friction, bool bFluid, float BrakingDeceleration)
{
	if (DashState.IsDashing())
	{
		float Speed = DashSpeed;
		if (bCheatIgnoreDashRules && IsAutonomousClient())
		{
			Speed *= CheatDashSpeedScale;   // клиентский чит: сервер посчитает со своей скоростью
		}
		Velocity = DashDirection * Speed;   // Z = 0; гравитацию/пол обрабатывает режим движения
		return;
	}
	Super::CalcVelocity(DeltaTime, Friction, bFluid, BrakingDeceleration);
}

// ------------------------------------------------------------------ коррекции

bool UBobMovementComponent::ClientUpdatePositionAfterServerUpdate()
{
	FNetworkPredictionData_Client_Character* Data = GetPredictionData_Client_Character();
	const bool bCorrecting = Data && Data->bUpdatePosition;
	// В момент вызова компонент уже стоит в авторитетной позиции сервера.
	const FVector ServerLocation = UpdatedComponent ? UpdatedComponent->GetComponentLocation() : FVector::ZeroVector;

	bReplayingMoves = true;
	const bool bResult = Super::ClientUpdatePositionAfterServerUpdate();
	bReplayingMoves = false;

	if (bCorrecting)
	{
		++CorrectionCount;
		LastCorrectionErrorUU = FVector::Dist(LastPredictedLocation, ServerLocation);
		UE_LOG(LogBobPrediction, Warning,
			TEXT("[CORRECTION] #%d server correction applied, predicted-vs-server error=%.1f uu, moves replayed"),
			CorrectionCount, LastCorrectionErrorUU);
	}
	return bResult;
}

// ------------------------------------------------------------------ SavedMove

void FSavedMove_Bob::Clear()
{
	Super::Clear();
	bSavedWantsToDash = false;
	bSavedDashActive = false;
	SavedStartState = BobDash::State();
	SavedDashDirection = FVector::ForwardVector;
}

uint8 FSavedMove_Bob::GetCompressedFlags() const
{
	uint8 Result = Super::GetCompressedFlags();
	if (bSavedWantsToDash)
	{
		Result |= FLAG_Custom_0;
	}
	return Result;
}

bool FSavedMove_Bob::CanCombineWith(const FSavedMovePtr& NewMove, ACharacter* InCharacter, float MaxDelta) const
{
	// Ходы с рывком не объединяем: иначе шаг интегрирования на сервере отличался бы от клиентского
	// на границе конца рывка и давал бы ложные коррекции.
	const FSavedMove_Bob* Other = static_cast<const FSavedMove_Bob*>(NewMove.Get());
	if (bSavedDashActive || Other->bSavedDashActive || bSavedWantsToDash != Other->bSavedWantsToDash)
	{
		return false;
	}
	return Super::CanCombineWith(NewMove, InCharacter, MaxDelta);
}

void FSavedMove_Bob::SetMoveFor(ACharacter* C, float InDeltaTime, FVector const& NewAccel, FNetworkPredictionData_Client_Character& ClientData)
{
	Super::SetMoveFor(C, InDeltaTime, NewAccel, ClientData);

	if (const UBobMovementComponent* Move = Cast<UBobMovementComponent>(C->GetCharacterMovement()))
	{
		bSavedWantsToDash = Move->bWantsToDash;
		SavedStartState = Move->DashState;
		SavedDashDirection = Move->DashDirection;
		bSavedDashActive = Move->bWantsToDash || Move->DashState.IsDashing();
	}
}

void FSavedMove_Bob::PrepMoveFor(ACharacter* C)
{
	Super::PrepMoveFor(C);

	// Перед повтором хода возвращаем состояние рывка к тому, каким оно было ДО этого хода.
	if (UBobMovementComponent* Move = Cast<UBobMovementComponent>(C->GetCharacterMovement()))
	{
		Move->DashState = SavedStartState;
		Move->DashDirection = SavedDashDirection;
	}
}

FSavedMovePtr FNetworkPredictionData_Client_Bob::AllocateNewMove()
{
	return FSavedMovePtr(new FSavedMove_Bob());
}
