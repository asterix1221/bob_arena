#pragma once

#include "CoreMinimal.h"
#include "GameFramework/HUD.h"
#include "BobHUD.generated.h"

/** Экранная диагностика для демонстрации: режим, пинг, выносливость/кулдаун, коррекции, отклик. */
UCLASS()
class BOBARENAPREDICTION_API ABobHUD : public AHUD
{
	GENERATED_BODY()

public:
	virtual void DrawHUD() override;
};
