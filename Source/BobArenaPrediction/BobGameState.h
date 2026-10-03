#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameStateBase.h"
#include "BobGameState.generated.h"

/**
 * GameState реплицируется на все машины, и его BeginPlay выполняется и на сервере, и на клиентах.
 * Поэтому арена (пол, стены-препятствия, свет) строится здесь ОДИНАКОВО на каждой машине из
 * примитивов движка — проекту не нужны ассеты карты, а коллизии у сервера и клиента совпадают
 * (иначе предсказание клиента расходилось бы с сервером у препятствий).
 */
UCLASS()
class BOBARENAPREDICTION_API ABobGameState : public AGameStateBase
{
	GENERATED_BODY()

protected:
	virtual void BeginPlay() override;

private:
	void BuildArena();
};
