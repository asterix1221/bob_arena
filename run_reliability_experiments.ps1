# run_reliability_experiments.ps1 — то же самое, что run_reliability_experiments.sh,
# но нативным PowerShell (без Git Bash/WSL). Прогоняет 6 обязательных серий
# эксперимента ПР №3 + 3 вспомогательные серии (сравнение с фиксированным RTO и демонстрация failed)
# локально (127.0.0.1) и записывает результаты в docs/reliability_samples.csv
# и docs/rto_timeline.csv. Параметры эмуляции сети — см.
# docs/Reliability_Protocol.md, раздел «Методика эксперимента».
#
# Использование (из корня репозитория, после сборки .exe — см. README.md):
#   .\run_reliability_experiments.ps1
#   .\run_reliability_experiments.ps1 -Count 50 -IntervalMs 100

param(
    [string]$Client = ".\reliable_client_app.exe",
    [string]$Server = ".\reliable_server_app.exe",
    [int]$Port = 27017,
    [int]$Count = 100,
    [int]$IntervalMs = 100,
    [string]$Csv = "docs/reliability_samples.csv",
    [string]$RtoCsv = "docs/rto_timeline.csv",
    [int]$SeedBase = 200000
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Client)) {
    Write-Error "Не найден клиент '$Client' — сначала соберите его (см. README.md, раздел ПР №3)."
    exit 1
}
if (-not (Test-Path $Server)) {
    Write-Error "Не найден сервер '$Server' — сначала соберите его (см. README.md, раздел ПР №3)."
    exit 1
}

foreach ($f in @($Csv, $RtoCsv)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

function Run-Series {
    param(
        [string]$Name,
        [int]$Seed,
        [string[]]$ServerArgs = @(),
        [string[]]$ClientArgs = @()
    )

    Write-Host "=== Серия: $Name (seed=$Seed) ==="

    $logPath = "docs/server_rel_$Name.log"
    $allServerArgs = @("$Port", "--seed=$Seed") + $ServerArgs
    $proc = Start-Process -FilePath $Server -ArgumentList $allServerArgs `
        -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err" `
        -NoNewWindow -PassThru

    Start-Sleep -Milliseconds 400
    try {
        $allClientArgs = @("127.0.0.1", "$Port", $Name, "$Count", "$IntervalMs", $Csv, "--rto-csv=$RtoCsv") + $ClientArgs
        & $Client @allClientArgs
    } finally {
        Start-Sleep -Milliseconds 200
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Run-Series -Name "baseline"         -Seed ($SeedBase + 1)
Run-Series -Name "loss_5"           -Seed ($SeedBase + 2) -ServerArgs @("--loss-percent=5")
Run-Series -Name "loss_10"          -Seed ($SeedBase + 3) -ServerArgs @("--loss-percent=10")
Run-Series -Name "loss_20"          -Seed ($SeedBase + 4) -ServerArgs @("--loss-percent=20")
Run-Series -Name "delay_100_loss_5" -Seed ($SeedBase + 5) -ServerArgs @("--delay-ms=100", "--loss-percent=5")
Run-Series -Name "jitter_loss_10"   -Seed ($SeedBase + 6) -ServerArgs @("--jitter-min-ms=50", "--jitter-max-ms=150", "--loss-percent=10")

# Вспомогательные серии: те же условия, что delay_100_loss_5 (тот же seed
# сервера), но с ПОСТОЯННЫМ RTO вместо адаптивного — для раздела «Анализ».
Run-Series -Name "cmp_fixed1000_delay_100_loss_5" -Seed ($SeedBase + 5) -ServerArgs @("--delay-ms=100", "--loss-percent=5") -ClientArgs @("--fixed-rto-ms=1000")
Run-Series -Name "cmp_fixed100_delay_100_loss_5"  -Seed ($SeedBase + 5) -ServerArgs @("--delay-ms=100", "--loss-percent=5") -ClientArgs @("--fixed-rto-ms=100")

# Демонстрация окончательной недоставки: потери 20% и всего 2 попытки на команду
# (в основных сериях с 5 попытками failed почти не случается).
Run-Series -Name "extra_loss_20_max2" -Seed ($SeedBase + 7) -ServerArgs @("--loss-percent=20") -ClientArgs @("--max-attempts=2")

Write-Host "Готово: $Csv, $RtoCsv"
