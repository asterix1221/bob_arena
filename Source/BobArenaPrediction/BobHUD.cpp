#include "BobHUD.h"
#include "BobCharacter.h"
#include "BobMovementComponent.h"
#include "Engine/Canvas.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "GameFramework/PlayerState.h"

static const TCHAR* NetModeName(ENetMode Mode)
{
	switch (Mode)
	{
	case NM_Standalone:       return TEXT("Standalone");
	case NM_DedicatedServer:  return TEXT("Dedicated Server");
	case NM_ListenServer:     return TEXT("Listen Server (host)");
	case NM_Client:           return TEXT("Client");
	default:                  return TEXT("?");
	}
}

void ABobHUD::DrawHUD()
{
	Super::DrawHUD();

	const ABobCharacter* Bob = Cast<ABobCharacter>(GetOwningPawn());
	if (Bob == nullptr || GetWorld() == nullptr)
	{
		return;
	}
	const UBobMovementComponent* Move = Bob->GetBobMovement();
	const APlayerController* PC = GetOwningPlayerController();
	const float Ping = (PC && PC->PlayerState) ? PC->PlayerState->GetPingInMilliseconds() : 0.f;

	TArray<FString> Lines;
	Lines.Add(FString::Printf(TEXT("Net mode: %s   Ping: %.0f ms"), NetModeName(GetWorld()->GetNetMode()), Ping));
	Lines.Add(FString::Printf(TEXT("Dash mode: %s   (console: bob.PredictDash 0|1)"),
		ABobCharacter::IsDashPredictionEnabled() ? TEXT("CLIENT-SIDE PREDICTION") : TEXT("NO PREDICTION (wait for server)")));
	Lines.Add(FString::Printf(TEXT("Stamina: %.0f / %.0f   Cooldown: %.2f s%s"),
		Move->DashState.Stamina, Move->StaminaMax, Move->DashState.CooldownRemaining,
		Move->DashState.IsDashing() ? TEXT("   [DASHING]") : TEXT("")));
	Lines.Add(FString::Printf(TEXT("Last response (%s): %.0f ms"), *Bob->LastResponseKind, Bob->LastResponseMs));
	Lines.Add(FString::Printf(TEXT("Corrections: %d   last error: %.1f uu"), Move->CorrectionCount, Move->LastCorrectionErrorUU));
	Lines.Add(FString::Printf(TEXT("Last server rejection: %s"), *Bob->LastRejectReason));
	if (Move->bCheatIgnoreDashRules)
	{
		Lines.Add(FString::Printf(TEXT("CHEAT ON: client ignores dash rules, speed x%.1f"), Move->CheatDashSpeedScale));
	}
	Lines.Add(TEXT("Keys: WASD move, Mouse look, Space jump, Left Shift dash"));

	float Y = 40.f;
	for (const FString& Line : Lines)
	{
		DrawText(Line, FLinearColor::White, 30.f, Y);
		Y += 22.f;
	}
}
