#pragma once

#include "CoreMinimal.h"
#include "GameFramework/PlayerController.h"
#include "BobPlayerController.generated.h"

/**
 * PlayerController: владеет Pawn'ом, пересылает ДИСКРЕТНОЕ действие на сервер (вариант без
 * предсказания) и даёт консольные команды для демонстрации расхождения.
 */
UCLASS()
class BOBARENAPREDICTION_API ABobPlayerController : public APlayerController
{
	GENERATED_BODY()

public:
	// Вариант БЕЗ предсказания: клиент не двигается сам, только просит сервер.
	UFUNCTION(Server, Reliable)
	void ServerRequestDashNoPrediction();

	// Консоль: BobCheatNoDashRules 1 — клиент игнорирует кулдаун/выносливость (сервер — нет).
	UFUNCTION(Exec)
	void BobCheatNoDashRules(int32 Enable);

	// Консоль: BobCheatDashSpeed 3 — клиент считает рывок в 3 раза быстрее (работает вместе с чит-режимом выше).
	UFUNCTION(Exec)
	void BobCheatDashSpeed(float Scale);
};
