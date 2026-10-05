#include "BobGameState.h"
#include "BobArenaPrediction.h"
#include "Components/StaticMeshComponent.h"
#include "Engine/DirectionalLight.h"
#include "Engine/StaticMesh.h"
#include "Engine/StaticMeshActor.h"
#include "Engine/World.h"

void ABobGameState::BeginPlay()
{
	Super::BeginPlay();
	BuildArena();
}

void ABobGameState::BuildArena()
{
	UWorld* World = GetWorld();
	UStaticMesh* Cube = LoadObject<UStaticMesh>(nullptr, TEXT("/Engine/BasicShapes/Cube.Cube"));
	if (World == nullptr || Cube == nullptr)
	{
		UE_LOG(LogBobPrediction, Error, TEXT("[ARENA] cannot build arena (no world or /Engine/BasicShapes/Cube)"));
		return;
	}

	auto SpawnBox = [World, Cube](const FVector& Location, const FVector& Scale)
	{
		FActorSpawnParameters Params;
		Params.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
		if (AStaticMeshActor* Box = World->SpawnActor<AStaticMeshActor>(Location, FRotator::ZeroRotator, Params))
		{
			Box->GetStaticMeshComponent()->SetMobility(EComponentMobility::Movable);
			Box->GetStaticMeshComponent()->SetStaticMesh(Cube);
			Box->SetActorScale3D(Scale);
		}
	};

	// Куб в движке 100x100x100 uu.
	SpawnBox(FVector(0.f, 0.f, -50.f), FVector(40.f, 40.f, 1.f));          // пол 4000x4000, верх на z = 0
	SpawnBox(FVector(2000.f, 0.f, 200.f), FVector(1.f, 40.f, 4.f));        // периметр
	SpawnBox(FVector(-2000.f, 0.f, 200.f), FVector(1.f, 40.f, 4.f));
	SpawnBox(FVector(0.f, 2000.f, 200.f), FVector(40.f, 1.f, 4.f));
	SpawnBox(FVector(0.f, -2000.f, 200.f), FVector(40.f, 1.f, 4.f));
	SpawnBox(FVector(600.f, 0.f, 100.f), FVector(1.f, 8.f, 2.f));          // стена: рывок «в препятствие»
	SpawnBox(FVector(-600.f, 500.f, 25.f), FVector(4.f, 4.f, 0.5f));       // низкая платформа

	if (ADirectionalLight* Sun = World->SpawnActor<ADirectionalLight>(FVector(0.f, 0.f, 1000.f), FRotator(-50.f, 30.f, 0.f)))
	{
		Sun->GetRootComponent()->SetMobility(EComponentMobility::Movable);
	}
}
