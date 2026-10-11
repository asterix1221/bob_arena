<#
.SYNOPSIS
  Запуск Bob Arena (Godot 4) и проверок. PowerShell 7, из корня репозитория.
.EXAMPLE
  .\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Bot
  .\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Both -Profile lag175loss4
  .\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Tests
.PARAMETER Role
  Menu — главное меню; Host — хост; Join — клиент (-Ip, -Port); Both — хост и клиент (два окна) на этой машине;
  Bot — хост + бот-тренер; Tests — все автотесты Godot (без окна); Shots — автоскриншоты экранов (нужен дисплей).
.PARAMETER Profile
  Эмуляция сети на датаграммах: none | lag100 (100 мс) | lag175loss4 (175±25 мс, 4% потерь). Меняется и в меню.
#>
param(
    [Parameter(Mandatory = $true)][string]$Godot,
    [ValidateSet("Menu", "Host", "Join", "Both", "Bot", "Tests", "Shots")][string]$Role = "Menu",
    [ValidateSet("none", "lag100", "lag175loss4")][string]$Profile = "none",
    [string]$Ip = "127.0.0.1",
    [int]$Port = 24680,
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
$importOut = & $Godot --headless --path $Proj --import 2>&1
$cache = Join-Path $Proj ".godot\global_script_class_cache.cfg"
if (-not (Test-Path $cache)) {
    Write-Host ($importOut | Select-Object -Last 20 | Out-String)
    Write-Error "Импорт не создал $cache"; exit 1
}

$preset = @{ none = 0; lag100 = 1; lag175loss4 = 2 }[$Profile]
function Game-Args([string]$extra) {
    $a = "--path `"$Proj`" -- --preset=$preset --port=$Port $extra"
    if ($DebugKeys) { $a += " --debug" }
    return $a
}

switch ($Role) {
    "Tests" {
        $suites = @("run_net_tests", "run_game_tests", "run_game_net_tests", "run_app_tests", "run_udp_tests")
        $bad = 0
        foreach ($s in $suites) {
            $out = & $Godot --headless --path $Proj -s "res://tests/$s.gd" 2>&1
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
