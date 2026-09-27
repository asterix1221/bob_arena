# run_experiments.ps1 — то же самое, что run_experiments.sh, но нативным
# PowerShell (без зависимости от Git Bash/WSL/bash). Прогоняет все 6 серий
# эксперимента ПР №2 локально (127.0.0.1) и дописывает результаты в
# docs/latency_samples.csv. См. docs/Experiment_Config.md для параметров
# и обоснования эмуляции задержки/джиттера/потерь на сервере вместо
# Clumsy (Windows-only, но недоступен в среде, где собиралась эта работа).
#
# Использование (из корня репозитория, после сборки .exe — см. README.md):
#   .\run_experiments.ps1
#
# Параметры настраиваются так же, как переменные окружения в bash-версии,
# только как параметры PowerShell, например:
#   .\run_experiments.ps1 -Count 100 -IntervalMs 500

param(
    [string]$Client = ".\ping_client_app.exe",
    [string]$Server = ".\pong_server_app.exe",
    [int]$Port = 27016,
    [int]$Count = 60,
    [int]$IntervalMs = 300,
    [string]$Csv = "docs/latency_samples.csv",
    [int]$SeedBase = 100000
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Client)) {
    Write-Error "Не найден клиент '$Client' — сначала соберите его (см. README.md, раздел 'Сборка и запуск')."
    exit 1
}
if (-not (Test-Path $Server)) {
    Write-Error "Не найден сервер '$Server' — сначала соберите его (см. README.md, раздел 'Сборка и запуск')."
    exit 1
}

if (Test-Path $Csv) {
    Remove-Item $Csv -Force
}

function Run-Series {
    param(
        [string]$Name,
        [int]$Seed,
        [string[]]$ExtraArgs
    )

    Write-Host "=== Серия: $Name (seed=$Seed) ==="

    $logPath = "docs/server_$Name.log"
    $serverArgs = @("$Port", "--seed=$Seed") + $ExtraArgs
    $proc = Start-Process -FilePath $Server -ArgumentList $serverArgs `
        -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err" `
        -NoNewWindow -PassThru

    Start-Sleep -Milliseconds 400
    try {
        & $Client 127.0.0.1 $Port $Name $Count $IntervalMs $Csv
    } finally {
        Start-Sleep -Milliseconds 200
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Run-Series -Name "baseline"  -Seed ($SeedBase + 1) -ExtraArgs @()
Run-Series -Name "delay_50"  -Seed ($SeedBase + 2) -ExtraArgs @("--delay-ms=50")
Run-Series -Name "delay_100" -Seed ($SeedBase + 3) -ExtraArgs @("--delay-ms=100")
Run-Series -Name "jitter"    -Seed ($SeedBase + 4) -ExtraArgs @("--jitter-min-ms=50", "--jitter-max-ms=150")
Run-Series -Name "loss_5"    -Seed ($SeedBase + 5) -ExtraArgs @("--loss-percent=5")
Run-Series -Name "combined"  -Seed ($SeedBase + 6) -ExtraArgs @("--delay-ms=100", "--jitter-min-ms=50", "--jitter-max-ms=150", "--loss-percent=5")

Write-Host "Готово: $Csv"
