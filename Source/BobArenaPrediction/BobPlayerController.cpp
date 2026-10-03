#include "BobPlayerController.h"
#include "BobArenaPrediction.h"
#include "BobCharacter.h"
#include "BobMovementComponent.h"

void ABobPlayerController::ServerRequestDashNoPrediction_Implementation()
{
	// Выполняется на сервере. Решение принимает CMC при ближайшем ходе — с теми же проверками.
	if (const ABobCharacter* Bob = GetPawn<ABobCharacter>())
	{
		Bob->GetBobMovement()->bServerDashRequested = true;
	}
}

void ABobPlayerController::BobCheatNoDashRules(int32 Enable)
{
	if (const ABobCharacter* Bob = GetPawn<ABobCharacter>())
	{
		Bob->GetBobMovement()->bCheatIgnoreDashRules = (Enable != 0);
		UE_LOG(LogBobPrediction, Warning, TEXT("[CHEAT] client ignores dash cooldown/stamina: %s"), Enable ? TEXT("ON") : TEXT("OFF"));
	}
}

void ABobPlayerController::BobCheatDashSpeed(float Scale)
{
	if (const ABobCharacter* Bob = GetPawn<ABobCharacter>())
	{
		Bob->GetBobMovement()->CheatDashSpeedScale = FMath::Max(0.1f, Scale);
		UE_LOG(LogBobPrediction, Warning, TEXT("[CHEAT] client dash speed scale = %.2f (applies only while BobCheatNoDashRules is ON)"), Scale);
	}
}
