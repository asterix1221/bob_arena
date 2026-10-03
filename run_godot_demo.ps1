# run_godot_demo.ps1 — ПР №4 (Godot): запуск демонстрации и автопрогон сценариев T1–T6.
#
# Примеры (PowerShell 7, из корня репозитория):
#   .\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Both -Profile lag100 -Predict 1
#   .\run_godot_demo.ps1 -Godot "..." -Role Both -Profile lag175loss4 -Predict 0
#   .\run_godot_demo.ps1 -Godot "..." -Role Scenarios                      # headless T1–T6 -> docs\godot\runs
#   .\run_godot_demo.ps1 -Godot "..." -Role Scenarios -Only T3             # только сценарии, имя которых содержит T3
#   .\run_godot_demo.ps1 -Godot "..." -Role Client -Profile none           # только второй клиент
#
# Профили сети (задержка — в ОДНУ сторону, эмулируется встроенным NetEmu на исходящем трафике клиента и сервера):
#   none        — без эмуляции                (T1)
#   lag100      — 100 мс, 0% потерь           (T2, T3)
#   lag175loss4 — 175±25 мс, 4% потерь        (T4, T5)

param(
    [string]$Godot = "godot",
    [ValidateSet("Host", "Client", "Both", "Scenarios")][string]$Role = "Both",
    [ValidateSet("none", "lag100", "lag175loss4")][string]$Profile = "none",
    [ValidateSet(0, 1)][int]$Predict = 1,
    [int]$Port = 24680,
    [string]$Only = ""
)

$ErrorActionPreference = "Stop"

# Кириллица в выводе PowerShell: консоль и .NET в UTF-8 (иначе возможны «кракозябры»).
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Proj = Join-Path $PSScriptRoot "godot"
if (-not (Test-Path (Join-Path $Proj "project.godot"))) { Write-Error "Не найден godot\project.godot (запускайте из корня репозитория)."; exit 1 }
if (-not (Get-Command $Godot -ErrorAction SilentlyContinue) -and -not (Test-Path $Godot)) {
    Write-Error "Godot не найден: '$Godot'. Укажите путь параметром -Godot (лучше *_console.exe)."; exit 1
}

function Get-Net([string]$Name) {
    switch ($Name) {
        "none"        { return "--lag=0 --jitter=0 --loss=0" }
        "lag100"      { return "--lag=100 --jitter=0 --loss=0" }
        "lag175loss4" { return "--lag=175 --jitter=25 --loss=4" }
    }
}

function Start-Godot([string]$GodotArgs, [switch]$Wait, [switch]$Hidden) {
    $line = "--path `"$Proj`" $(if ($Hidden) { '--headless ' })-- $GodotArgs"
    if ($Hidden) {
        $sink = [System.IO.Path]::GetTempFileName()
        return Start-Process -FilePath $Godot -ArgumentList $line -PassThru -Wait:$Wait -NoNewWindow -RedirectStandardOutput $sink
    }
    return Start-Process -FilePath $Godot -ArgumentList $line -PassThru -Wait:$Wait
}

if ($Role -eq "Scenarios") {
    $Out = Join-Path $PSScriptRoot "docs\godot\runs"
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    $Out = (Resolve-Path $Out).Path      # Godot не понимает относительные пути в FileAccess
    # имя, predict, lag, jitter, loss, бот
    $cases = @(
        @("T1_walk_noemu_pred",     1, 0,   0,  0, "walk"),
        @("T2_lag100_nopred",       0, 100, 0,  0, "dash_latency"),
        @("T3_lag100_pred",         1, 100, 0,  0, "dash_latency"),
        @("T4_lag175loss4_pred",    1, 175, 25, 4, "loss_mix"),
        @("T5_lag175loss4_cheat",   1, 175, 25, 4, "cheat"),
        @("T6_lag100_wall",         1, 100, 0,  0, "wall")
    )
    $p = 24800
    foreach ($c in $cases) {
        if ($Only -and ($c[0] -notlike "*$Only*")) { continue }
        $p++
        $name = $c[0]
        $hostLog = Join-Path $Out "$name.host.log"; $cliLog = Join-Path $Out "$name.client.log"
        Remove-Item $hostLog, $cliLog -ErrorAction SilentlyContinue
        $net = "--lag=$($c[2]) --jitter=$($c[3]) --loss=$($c[4])"
        $h = Start-Godot "--host --port=$p --quit-after=60 --exit-on-disconnect $net --out=`"$hostLog`"" -Hidden
        for ($i = 0; $i -lt 100; $i++) {
            if ((Test-Path $hostLog) -and (Select-String -Path $hostLog -Pattern "LISTEN SERVER" -Quiet)) { break }
            Start-Sleep -Milliseconds 200
        }
        Start-Godot "--join=127.0.0.1 --port=$p --predict=$($c[1]) $net --bot=$($c[5]) --out=`"$cliLog`"" -Wait -Hidden | Out-Null
        $h | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
        $res = if (Test-Path $cliLog) { (Select-String -Path $cliLog -Pattern "^\[RESULT\] corrections" -Encoding utf8 | Select-Object -First 1).Line } else { "НЕТ ЛОГА КЛИЕНТА" }
        Write-Host "$name : $res"
    }
    Write-Host "Логи: $Out. Графики и сводка: python tools\godot_report.py"
    exit 0
}

$net = Get-Net $Profile
if ($Role -in @("Host", "Both")) {
    Start-Godot "--host --port=$Port --predict=$Predict" | Out-Null
    Write-Host "Listen Server запущен (порт $Port)."
    if ($Role -eq "Both") { Start-Sleep -Seconds 3 }
}
if ($Role -in @("Client", "Both")) {
    Start-Godot "--join=127.0.0.1 --port=$Port --predict=$Predict $net" | Out-Null
    Write-Host "Клиент запущен: профиль=$Profile, предсказание=$Predict."
}
