# run_prediction_demo.ps1 — ПР №4: сборка и запуск демонстрации Client-Side Prediction.
# Запускает Listen Server и/или клиент как отдельные процессы UnrealEditor.exe (-game),
# чтобы у каждого был свой экран, своя консоль и своя эмуляция сети.
#
# Примеры (из корня репозитория, PowerShell 7):
#   .\run_prediction_demo.ps1 -Role Build
#   .\run_prediction_demo.ps1 -Role Both -Profile lag100 -Predict 1
#   .\run_prediction_demo.ps1 -Role Both -Profile lag150loss5 -Predict 0
#   .\run_prediction_demo.ps1 -Role Client -Profile none            # только второй клиент
#
# Профили эмуляции (команды NetEmulation.* из задания; задаются клиенту):
#   none        — без эмуляции (T1)
#   lag100      — NetEmulation.PktLag 100, PktLoss 0 (T2, T3)
#   lag150loss5 — PktLag 150, PktLagVariance 25, PktLoss 5 (T4, T5)
# Если эмуляция не применилась при старте — введите те же команды в консоль клиента (клавиша ~)
# и убедитесь по Ping в HUD.

param(
    [ValidateSet("Build", "Server", "Client", "Both")][string]$Role = "Both",
    [ValidateSet("none", "lag100", "lag150loss5")][string]$Profile = "none",
    [ValidateSet(0, 1)][int]$Predict = 1,
    [string]$EngineRoot = "C:\Program Files\Epic Games\UE_5.8",
    [int]$Port = 7777
)

$ErrorActionPreference = "Stop"

# Кириллица в выводе PowerShell: консоль и .NET в UTF-8 (иначе возможны «кракозябры»).
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Project = Join-Path $PSScriptRoot "BobArenaPrediction.uproject"
$Editor = Join-Path $EngineRoot "Engine\Binaries\Win64\UnrealEditor.exe"
$BuildBat = Join-Path $EngineRoot "Engine\Build\BatchFiles\Build.bat"

if (-not (Test-Path $Project)) { Write-Error "Не найден $Project (запускайте скрипт из корня репозитория)."; exit 1 }
if (-not (Test-Path $BuildBat)) { Write-Error "Не найден Unreal Engine: $EngineRoot (параметр -EngineRoot)."; exit 1 }

if ($Role -eq "Build") {
    & $BuildBat BobArenaPredictionEditor Win64 Development "-Project=$Project" -WaitMutex
    exit $LASTEXITCODE
}

if (-not (Test-Path $Editor)) { Write-Error "Не найден $Editor"; exit 1 }

$emulation = switch ($Profile) {
    "none"        { "NetEmulation.PktLag 0,NetEmulation.PktLoss 0" }
    "lag100"      { "NetEmulation.PktLag 100,NetEmulation.PktLoss 0" }
    "lag150loss5" { "NetEmulation.PktLag 150,NetEmulation.PktLagVariance 25,NetEmulation.PktLoss 5" }
}
$predictCmd = "bob.PredictDash $Predict"

# Строку аргументов собираем вручную и отдаём Start-Process целиком: UE ждёт кавычки вокруг
# -ExecCmds="a,b" именно в такой форме, а при передаче массива PowerShell экранирует их иначе.
$common = "-game -log -windowed -ResX=960 -ResY=540"

if ($Role -in @("Server", "Both")) {
    $cmdLine = "`"$Project`" /Engine/Maps/Entry?listen $common -WinX=0 -WinY=40 -ExecCmds=`"$predictCmd`""
    Start-Process -FilePath $Editor -ArgumentList $cmdLine
    Write-Host "Listen Server запущен (порт по умолчанию 7777)."
    if ($Role -eq "Both") { Start-Sleep -Seconds 8 }
}
if ($Role -in @("Client", "Both")) {
    $cmdLine = "`"$Project`" 127.0.0.1:$Port $common -WinX=980 -WinY=40 -ExecCmds=`"$predictCmd,$emulation`""
    Start-Process -FilePath $Editor -ArgumentList $cmdLine
    Write-Host "Клиент запущен: профиль=$Profile, предсказание=$Predict."
}
