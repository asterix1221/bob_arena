<#
.SYNOPSIS
  Запуск Bob Arena (Godot 4) и проверок. PowerShell 7, из корня репозитория.
.EXAMPLE
  .\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Bot
  .\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Both -Profile lag175loss4
  .\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Tests
.PARAMETER Role
  Menu — главное меню; Host — хост; Join — клиент (-Ip, -Port); Both — хост и клиент (два окна) на этой машине;
  Bot — хост + бот-тренер; Tests — все автотесты Godot (без окна); Shots — автоскриншоты экранов (нужен дисплей);
  Scenarios — автопрогон сценариев ПР №4 T1–T5 (хост и клиент — два процесса по реальному UDP, без окна), логи в docs\game_runs;
  Scenario — один сценарий (-Case T3) С ОКНАМИ: хост и клиент, клиентом управляет скрипт — для записи экрана (OBS / Win+Alt+R);
  Lab — ПР №5: игра сразу на экране «Лаборатория репликации» (то же, что в меню; переключатели техник — в настройках справа и клавишами 1–7, B/O — «до»/«после»);
  ReplProfile — ПР №5: профиль трафика «до/после» без окна (15 конфигураций), JSON в docs\repl, затем отчёты docs\Replication_*.md (нужен python).
.PARAMETER Repl
  Для Role Lab (ПР №5): стартовый набор оптимизаций — optimized («после», по умолчанию) или baseline («до»).
.PARAMETER Predict
  1 — клиент предсказывает рывок сразу (по умолчанию), 0 — рывок виден только после ответа сервера. В игре: F4.
.PARAMETER Viz
  Визуализация предсказания: 0 выкл, 1 призрак сервера, 2 предсказанный персонаж полупрозрачный, 3 полная. В игре: F8.
.PARAMETER Profile
  Эмуляция сети на датаграммах: none | lag100 (100 мс) | lag175loss4 (175±25 мс, 4% потерь). Меняется и в меню.
#>
param(
    [Parameter(Mandatory = $true)][string]$Godot,
    [ValidateSet("Menu", "Host", "Join", "Both", "Bot", "Tests", "Shots", "Scenarios", "Scenario", "Lab", "ReplProfile")][string]$Role = "Menu",
    [ValidateSet("none", "lag100", "lag175loss4")][string]$Profile = "none",
    [string]$Ip = "127.0.0.1",
    [int]$Port = 24680,
    [ValidateSet(0, 1)][int]$Predict = 1,
    [ValidateSet(0, 1, 2, 3)][int]$Viz = 1,
    [ValidateSet("T1", "T2", "T3", "T4", "T5")][string]$Case = "T3",
    [ValidateSet("baseline", "optimized")][string]$Repl = "optimized",
    [string]$Name = "",
    [switch]$DebugKeys
)

# Кириллица в консоли: вывод Godot — UTF-8.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$ErrorActionPreference = "Stop"

$Proj = Join-Path $PSScriptRoot "godot"
if (-not (Test-Path $Godot)) { Write-Error "Godot не найден: $Godot"; exit 1 }

# Импорт проекта при КАЖДОМ запуске (2-5 секунд). Godot без окна редактора не перестраивает реестр глобальных классов
# (class_name): если в godot\.godot остался кэш от другой версии игры, скрипты не компилируются
# («Could not find type "GameUI"», серый экран, тесты без результата). Импорт этот реестр обновляет.
Write-Host "Импорт проекта Godot (обновление кэша .godot) ..."
$ErrorActionPreference = "Continue"   # Godot пишет безобидные предупреждения в stderr; со "Stop" PowerShell счёл бы их ошибкой
$importOut = & $Godot --headless --path $Proj --import 2>&1
$ErrorActionPreference = "Stop"
$cache = Join-Path $Proj ".godot\global_script_class_cache.cfg"
if (-not (Test-Path $cache)) {
    Write-Host ($importOut | Select-Object -Last 20 | Out-String)
    Write-Error "Импорт не создал $cache"; exit 1
}

$preset = @{ none = 0; lag100 = 1; lag175loss4 = 2 }[$Profile]
function Game-Args([string]$extra) {
    $a = "--path `"$Proj`" -- --preset=$preset --port=$Port --predict=$Predict --viz=$Viz $extra"
    if ($DebugKeys) { $a += " --debug" }
    return $a
}

switch ($Role) {
    "Tests" {
        $suites = @("run_net_tests", "run_game_tests", "run_game_net_tests", "run_pred_tests", "run_view_tests", "run_app_tests", "run_udp_tests", "run_repl_tests")
        $bad = 0
        foreach ($s in $suites) {
            $ErrorActionPreference = "Continue"
            $out = & $Godot --headless --path $Proj -s "res://tests/$s.gd" 2>&1
            $ErrorActionPreference = "Stop"
            $line = ($out | Select-String "тестов" | Select-Object -Last 1).Line
            if (-not $line) {
                $line = "НЕТ РЕЗУЛЬТАТА. Последние строки вывода Godot:"
                $bad++
                $out | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" }
            }
            elseif ($line -notmatch ", 0 провалено") { $bad++ }
            "{0,-22} {1}" -f $s, $line
        }
        if ($bad -gt 0) { Write-Host "Есть проваленные наборы: $bad"; exit 1 }
        Write-Host "Все наборы Godot прошли."
    }
    "Shots" {
        $dir = Join-Path $PSScriptRoot "docs\game_shots"
        New-Item -ItemType Directory -Force $dir | Out-Null
        & $Godot --path $Proj -- --shots="$($dir -replace '\\','/')"
        Write-Host "Скриншоты: $dir"
    }
    "Scenarios" {
        # T1–T5: два процесса Godot без окна по реальному UDP (хост = Listen Server, клиентом управляет скрипт). Логи: docs\game_runs
        $runs = Join-Path $PSScriptRoot "docs\game_runs"
        New-Item -ItemType Directory -Force $runs | Out-Null
        $p = 24800
        foreach ($c in @("T1", "T2", "T3", "T4", "T5")) {
            $p++
            $hl = Join-Path $runs "$c.host.log"; $cl = Join-Path $runs "$c.client.log"
            Remove-Item $hl, $cl -ErrorAction SilentlyContinue
            $h = Start-Process -FilePath $Godot -PassThru -WindowStyle Hidden -ArgumentList "--headless --path `"$Proj`" -- --scenario=$c --role=host --port=$p --quit-after=90 --out=`"$hl`""
            for ($i = 0; $i -lt 100; $i++) { if ((Test-Path $hl) -and (Select-String -Path $hl -Pattern "LISTEN SERVER" -Quiet)) { break }; Start-Sleep -Milliseconds 200 }
            & $Godot --headless --path $Proj -- --scenario=$c --role=client --join=127.0.0.1 --port=$p --quit-after=90 --out="$cl" | Out-Null
            $h | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue
            $line = if (Test-Path $cl) { (Select-String -Path $cl -Pattern "^\[RESULT\] corrections" | Select-Object -First 1).Line } else { $null }
            "{0}: {1}" -f $c, $(if ($line) { $line } else { "НЕТ РЕЗУЛЬТАТА (см. логи)" })
        }
        Write-Host "Логи: $runs. Сводка и графики: python tools\game_report.py"
    }
    "Scenario" {
        # Один сценарий С ОКНАМИ: хост и клиент (клиентом управляет скрипт). Запишите окно клиента (OBS / Win+Alt+R).
        $hl = Join-Path $env:TEMP "bob_$Case.host.log"; $cl = Join-Path $env:TEMP "bob_$Case.client.log"
        Remove-Item $hl, $cl -ErrorAction SilentlyContinue
        $h = Start-Process -FilePath $Godot -PassThru -ArgumentList "--path `"$Proj`" -- --scenario=$Case --role=host --port=$Port --out=`"$hl`""
        for ($i = 0; $i -lt 100; $i++) { if ((Test-Path $hl) -and (Select-String -Path $hl -Pattern "LISTEN SERVER" -Quiet)) { break }; Start-Sleep -Milliseconds 200 }
        Write-Host "Запись экрана: начните её сейчас (Win+Alt+R). Окно клиента запускается; сценарий идёт ~20 с."
        & $Godot --path $Proj -- --scenario=$Case --role=client --join=127.0.0.1 --port=$Port --viz=$Viz --out="$cl"
        $h | Wait-Process -Timeout 20 -ErrorAction SilentlyContinue
        Write-Host "Готово. Лог клиента: $cl"
    }
    "Lab" {
        # ПР №5: сама игра, сразу экран «Лаборатория репликации» (то же, что меню -> «Лаборатория репликации»)
        Start-Process -FilePath $Godot -ArgumentList (Game-Args "--lab --repl=$Repl")
        Write-Host "Лаборатория репликации запущена. Справа — настройки (переключатели техник, набор, сеть, «Замер»); A/D — идти, Пробел — выстрел, 1–7, B/O, H/M/G — клавиши, Esc — в меню."
    }
    "ReplProfile" {
        $out = Join-Path $PSScriptRoot "docs\repl"
        New-Item -ItemType Directory -Force $out | Out-Null
        $ErrorActionPreference = "Continue"
        $outArg = "--out=" + ($out -replace '\\', '/')
        & $Godot --headless --path $Proj --script res://tests/run_repl_profile.gd -- $outArg
        $rc = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        if ($rc -ne 0) { Write-Error "Профиль завершился с ошибкой ($rc)"; exit 1 }
        $py = Get-Command python -ErrorAction SilentlyContinue
        if ($py) { & python (Join-Path $PSScriptRoot "tools\repl_report.py") }
        else { Write-Host "python не найден: отчёты docs\Replication_*.md не обновлены (python tools\repl_report.py)" }
    }
    "Menu" { Start-Process -FilePath $Godot -ArgumentList (Game-Args "") }
    "Bot" {
        $n = if ($Name) { "--name=`"$Name`"" } else { "" }
        Start-Process -FilePath $Godot -ArgumentList (Game-Args "--host --bot $n")
    }
    "Host" {
        $n = if ($Name) { "--name=`"$Name`"" } else { "" }
        Start-Process -FilePath $Godot -ArgumentList (Game-Args "--host $n")
        Write-Host "Хост запущен (порт $Port). Друзья подключаются на ваш IP:$Port; игра стартует кнопкой «Старт» в лобби."
    }
    "Join" {
        $n = if ($Name) { "--name=`"$Name`"" } else { "" }
        Start-Process -FilePath $Godot -ArgumentList (Game-Args "--join=$Ip $n")
    }
    "Both" {
        Start-Process -FilePath $Godot -ArgumentList (Game-Args "--host --name=Хост")
        Start-Sleep -Milliseconds 1500
        Start-Process -FilePath $Godot -ArgumentList (Game-Args "--join=127.0.0.1 --name=Гость --color=1")
        Write-Host "Запущены хост и клиент (два окна). Нажмите «Старт» в окне хоста."
    }
}
