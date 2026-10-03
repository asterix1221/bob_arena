#include "BobGameMode.h"
#include "BobCharacter.h"
#include "BobGameState.h"
#include "BobHUD.h"
#include "BobPlayerController.h"
#include "Engine/World.h"
#include "GameFramework/PlayerStart.h"

ABobGameMode::ABobGameMode()
{
	DefaultPawnClass = ABobCharacter::StaticClass();
	PlayerControllerClass = ABobPlayerController::StaticClass();
	HUDClass = ABobHUD::StaticClass();
	GameStateClass = ABobGameState::StaticClass();
}

AActor* ABobGameMode::ChoosePlayerStart_Implementation(AController* Player)
{
	// В карте нет PlayerStart (арена строится кодом) — создаём две точки при первом обращении.
	if (SpawnPoints.Num() == 0 && GetWorld())
	{
		FActorSpawnParameters Params;
		Params.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
		const FVector Locations[] = { FVector(-300.f, -200.f, 120.f), FVector(-300.f, 200.f, 120.f) };
		for (const FVector& Location : Locations)
		{
			if (APlayerStart* Start = GetWorld()->SpawnActor<APlayerStart>(Location, FRotator::ZeroRotator, Params))
			{
				SpawnPoints.Add(Start);
			}
		}
	}
	if (SpawnPoints.Num() == 0)
	{
		return Super::ChoosePlayerStart_Implementation(Player);
	}
	return SpawnPoints[NextSpawn++ % SpawnPoints.Num()];
}
