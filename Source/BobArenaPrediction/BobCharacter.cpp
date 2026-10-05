#include "BobCharacter.h"
#include "BobArenaPrediction.h"
#include "BobMovementComponent.h"
#include "BobPlayerController.h"
#include "Camera/CameraComponent.h"
#include "Components/CapsuleComponent.h"
#include "Components/InputComponent.h"
#include "Components/StaticMeshComponent.h"
#include "Engine/StaticMesh.h"
#include "GameFramework/SpringArmComponent.h"
#include "InputCoreTypes.h"
#include "Math/RotationMatrix.h"
#include "Net/UnrealNetwork.h"
#include "UObject/ConstructorHelpers.h"
#include "HAL/PlatformTime.h"
#include "HAL/IConsoleManager.h"

static TAutoConsoleVariable<int32> CVarBobPredictDash(
	TEXT("bob.PredictDash"), 1,
	TEXT("1 = dash is predicted locally by the owning client (CSP). 0 = dash starts only after the server's response (baseline)."),
	ECVF_Default);

ABobCharacter::ABobCharacter(const FObjectInitializer& ObjectInitializer)
	: Super(ObjectInitializer.SetDefaultSubobjectClass<UBobMovementComponent>(ACharacter::CharacterMovementComponentName))
{
	PrimaryActorTick.bCanEverTick = true;

	GetCapsuleComponent()->InitCapsuleSize(35.f, 88.f);
	bUseControllerRotationPitch = false;
	bUseControllerRotationYaw = false;
	bUseControllerRotationRoll = false;

	CameraBoom = CreateDefaultSubobject<USpringArmComponent>(TEXT("CameraBoom"));
	CameraBoom->SetupAttachment(RootComponent);
	CameraBoom->TargetArmLength = 450.f;
	CameraBoom->bUsePawnControlRotation = true;

	FollowCamera = CreateDefaultSubobject<UCameraComponent>(TEXT("FollowCamera"));
	FollowCamera->SetupAttachment(CameraBoom, USpringArmComponent::SocketName);
	FollowCamera->bUsePawnControlRotation = false;

	// Визуал из примитивов движка, чтобы проекту не требовались ассеты в Content/.
	static ConstructorHelpers::FObjectFinder<UStaticMesh> CylinderMesh(TEXT("/Engine/BasicShapes/Cylinder.Cylinder"));
	static ConstructorHelpers::FObjectFinder<UStaticMesh> CubeMesh(TEXT("/Engine/BasicShapes/Cube.Cube"));

	Body = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("Body"));
	Body->SetupAttachment(GetCapsuleComponent());
	Body->SetMobility(EComponentMobility::Movable);
	Body->SetCollisionEnabled(ECollisionEnabled::NoCollision);
	Body->SetRelativeScale3D(FVector(0.7f, 0.7f, 1.76f));
	if (CylinderMesh.Succeeded()) { Body->SetStaticMesh(CylinderMesh.Object); }

	Nose = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("Nose"));   // указывает, куда «смотрит» персонаж
	Nose->SetupAttachment(GetCapsuleComponent());
	Nose->SetMobility(EComponentMobility::Movable);
	Nose->SetCollisionEnabled(ECollisionEnabled::NoCollision);
	Nose->SetRelativeLocation(FVector(40.f, 0.f, 50.f));
	Nose->SetRelativeScale3D(FVector(0.3f, 0.3f, 0.3f));
	if (CubeMesh.Succeeded()) { Nose->SetStaticMesh(CubeMesh.Object); }
}

UBobMovementComponent* ABobCharacter::GetBobMovement() const
{
	return Cast<UBobMovementComponent>(GetCharacterMovement());
}

bool ABobCharacter::IsDashPredictionEnabled()
{
	return CVarBobPredictDash.GetValueOnGameThread() != 0;
}

void ABobCharacter::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);
	DOREPLIFETIME(ABobCharacter, AcceptedDashCount);
}

// ------------------------------------------------------------------ ввод

void ABobCharacter::SetupPlayerInputComponent(UInputComponent* PlayerInputComponent)
{
	Super::SetupPlayerInputComponent(PlayerInputComponent);

	PlayerInputComponent->BindAxisKey(EKeys::W, this, &ABobCharacter::MoveForwardPos);
	PlayerInputComponent->BindAxisKey(EKeys::S, this, &ABobCharacter::MoveForwardNeg);
	PlayerInputComponent->BindAxisKey(EKeys::D, this, &ABobCharacter::MoveRightPos);
	PlayerInputComponent->BindAxisKey(EKeys::A, this, &ABobCharacter::MoveRightNeg);
	PlayerInputComponent->BindAxisKey(EKeys::MouseX, this, &ABobCharacter::LookYaw);
	PlayerInputComponent->BindAxisKey(EKeys::MouseY, this, &ABobCharacter::LookPitch);

	PlayerInputComponent->BindKey(EKeys::SpaceBar, IE_Pressed, this, &ACharacter::Jump);
	PlayerInputComponent->BindKey(EKeys::SpaceBar, IE_Released, this, &ACharacter::StopJumping);
	PlayerInputComponent->BindKey(EKeys::LeftShift, IE_Pressed, this, &ABobCharacter::RequestDash);
}

void ABobCharacter::ApplyMoveInput(EAxis::Type Axis, float Value)
{
	if (Controller == nullptr || Value == 0.f)
	{
		return;
	}
	const FRotator YawRotation(0.f, Controller->GetControlRotation().Yaw, 0.f);
	AddMovementInput(FRotationMatrix(YawRotation).GetUnitAxis(Axis), Value);
}

// ------------------------------------------------------------------ рывок: клиент

void ABobCharacter::RequestDash()
{
	if (!IsLocallyControlled())
	{
		return;
	}
	LastDashKeyTime = FPlatformTime::Seconds();
	bAwaitingDashResponse = true;

	UBobMovementComponent* Move = GetBobMovement();
	if (HasAuthority() || IsDashPredictionEnabled())
	{
		// С предсказанием: просто поднимаем флаг намерения. Он попадёт в SavedMove, будет
		// выполнен локально СРАЗУ и отправлен серверу в составе ServerMove (compressed flags).
		Move->bWantsToDash = true;
	}
	else if (ABobPlayerController* PC = Cast<ABobPlayerController>(GetController()))
	{
		// Без предсказания: локально ничего не делаем, ждём решения сервера.
		PC->ServerRequestDashNoPrediction();
	}
}

void ABobCharacter::OnLocalDashPredicted()
{
	if (bAwaitingDashResponse)
	{
		LastResponseMs = (FPlatformTime::Seconds() - LastDashKeyTime) * 1000.0;
		LastResponseKind = TEXT("PREDICTED (local)");
		UE_LOG(LogBobPrediction, Log, TEXT("[DASH] mode=PREDICTION key->local response=%.1f ms (server confirmation follows)"), LastResponseMs);
	}
}

// ------------------------------------------------------------------ рывок: сервер -> клиенты

void ABobCharacter::ServerOnDashAccepted()
{
	++AcceptedDashCount;   // реплицируется; на хосте OnRep не вызывается — это нормально
}

void ABobCharacter::ServerOnDashRejected(uint8 Reason, float Cooldown, float Stamina)
{
	ClientDashRejected(Reason, Cooldown, Stamina);
}

void ABobCharacter::ClientDashRejected_Implementation(uint8 Reason, float Cooldown, float Stamina)
{
	LastRejectReason = ANSI_TO_TCHAR(BobDash::ToString(static_cast<BobDash::Reject>(Reason)));
	const double Ms = bAwaitingDashResponse ? (FPlatformTime::Seconds() - LastDashKeyTime) * 1000.0 : -1.0;
	UE_LOG(LogBobPrediction, Warning, TEXT("[DASH] REJECTED by server: reason=%s, %.1f ms after key press. Client will be corrected."),
		*LastRejectReason, Ms);
	bAwaitingDashResponse = false;

	// Подтягиваем клиентский счётчик к авторитетному состоянию сервера.
	if (UBobMovementComponent* Move = GetBobMovement())
	{
		Move->QueueServerStateSync(Cooldown, Stamina);
	}
}

void ABobCharacter::OnRep_AcceptedDashCount()
{
	VisualDashUntil = FPlatformTime::Seconds() + 0.25;   // всем клиентам — визуальный отклик

	if (GetLocalRole() == ROLE_AutonomousProxy && bAwaitingDashResponse)
	{
		LastResponseMs = (FPlatformTime::Seconds() - LastDashKeyTime) * 1000.0;
		LastResponseKind = IsDashPredictionEnabled() ? TEXT("SERVER CONFIRMED") : TEXT("SERVER RESPONSE (no prediction)");
		UE_LOG(LogBobPrediction, Log, TEXT("[DASH] mode=%s key->server-confirmed/visible response=%.1f ms"),
			IsDashPredictionEnabled() ? TEXT("PREDICTION") : TEXT("NO_PREDICTION"), LastResponseMs);
		bAwaitingDashResponse = false;
	}
}

void ABobCharacter::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);

	// Косметика: корпус сплющивается во время рывка (для клиента-владельца и сервера — по состоянию CMC,
	// для чужих персонажей — по реплицированному счётчику).
	const UBobMovementComponent* Move = GetBobMovement();
	const bool bDashVisual = (Move && Move->DashState.IsDashing()) || FPlatformTime::Seconds() < VisualDashUntil;
	Body->SetRelativeScale3D(bDashVisual ? FVector(1.1f, 1.1f, 1.0f) : FVector(0.7f, 0.7f, 1.76f));
}
