#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "BobGameMode.generated.h"

/**
 * GameMode существует ТОЛЬКО на сервере: задаёт классы игроков и создаёт точки появления.
 * Позиции игроков после этого определяет только сервер (CMC), клиент их не назначает.
 */
UCLASS()
class BOBARENAPREDICTION_API ABobGameMode : public AGameModeBase
{
	GENERATED_BODY()

public:
	ABobGameMode();

protected:
	virtual AActor* ChoosePlayerStart_Implementation(AController* Player) override;

private:
	UPROPERTY()
	TArray<TObjectPtr<AActor>> SpawnPoints;
	int32 NextSpawn = 0;
};
