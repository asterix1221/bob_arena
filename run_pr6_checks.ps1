<#
.SYNOPSIS
  ПР №6 (шифрование UDP): сборка и все проверки одним запуском. PowerShell 7, из корня репозитория.
.DESCRIPTION
  1. собирает и запускает C++-тесты (протокол ПР №1-3 + crypto, нужен OpenSSL 3: MSYS2 `pacman -S mingw-w64-ucrt-x86_64-openssl`);
  2. самопроверка crypto_selftest из материалов задания;
  3. пересоздаёт эталонные векторы godot\tests\crypto_vectors.json из C++ и сверяет с файлом в репозитории;
  4. запускает secure_server_app + secure_client_app по реальному UDP (без потерь и с потерями 30%);
  5. тесты Godot run_crypto_tests.gd (в том числе совместимость GDScript <-> C++ secure_server_app по сети);
  6. негативный тест: прокси udp_proxy.py портит бит шифртекста — сервер пишет AUTH_FAIL, клиент не получает ACK (нужен python).
.EXAMPLE
  .\run_pr6_checks.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe"
.PARAMETER Gpp
  Компилятор (по умолчанию g++ из PATH, MSYS2 UCRT64).
.PARAMETER Out
  Каталог для собранных программ и логов (по умолчанию build_pr6, в .gitignore его нет — удалите после проверки).
#>
param(
    [Parameter(Mandatory = $true)][string]$Godot,
    [string]$Gpp = "g++",
    [string]$Out = "build_pr6"
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$onWin = [System.Environment]::OSVersion.Platform -eq "Win32NT"
$exe = if ($onWin) { ".exe" } else { "" }
$ws = if ($onWin) { @("-lws2_32") } else { @() }
$bin = if ($onWin) { ".\$Out\" } else { "./$Out/" }
New-Item -ItemType Directory -Force $Out | Out-Null
$failures = 0
$hidden = if ($onWin) { @{ WindowStyle = "Hidden" } } else { @{} }   # на Linux (pwsh) параметра нет

function Step([string]$title) { Write-Host ""; Write-Host "=== $title" -ForegroundColor Cyan }
function Fail([string]$msg) { Write-Host "  ПРОВАЛ: $msg" -ForegroundColor Red; $script:failures++ }
function Ok([string]$msg) { Write-Host "  ok: $msg" -ForegroundColor Green }
function Build([string]$name, [string[]]$files) {
    $o = "$Out/$name$exe"
    & $Gpp -std=c++17 -O1 @files -o $o -lcrypto @ws
    if ($LASTEXITCODE -ne 0) { throw "сборка $name не удалась (нужен OpenSSL 3: см. описание скрипта)" }
}
function Stop-Quiet($p) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }

Step "1. C++: сборка и тесты (протокол + crypto)"
$testFiles = @("protocol/protocol.cpp", "telemetry/telemetry.cpp", "reliability/adaptive_timeout.cpp", "reliability/reliable_channel.cpp", "reliability/dedup_window.cpp",
    "crypto/crypto.cpp", "crypto/secure_channel.cpp",
    "tests/test_protocol.cpp", "tests/test_telemetry.cpp", "tests/test_reliable_protocol.cpp", "tests/test_adaptive_timeout.cpp", "tests/test_reliable_channel.cpp",
    "tests/test_game_packets.cpp", "tests/test_crypto.cpp", "tests/test_main.cpp")
Build "tests_app" $testFiles
$line = (& "${bin}tests_app${exe}" | Select-Object -Last 1)
if ($line -match ", 0 провалено") { Ok $line } else { Fail "C++-тесты: $line" }

Step "2. Самопроверка crypto_selftest (из материалов задания)"
Build "crypto_selftest" @("tests/crypto_selftest.cpp", "crypto/crypto.cpp")
$selfOut = & "${bin}crypto_selftest${exe}"
$selfOut | ForEach-Object { Write-Host "  $_" }
if (($selfOut | Where-Object { $_ -match "FAIL" }).Count -gt 0 -or $LASTEXITCODE -ne 0) { Fail "crypto_selftest" } else { Ok "crypto_selftest" }

Step "3. Эталонные векторы C++ -> GDScript"
Build "gen_crypto" @("protocol/protocol.cpp", "crypto/crypto.cpp", "crypto/secure_channel.cpp", "tools/gen_crypto_vectors.cpp")
$fresh = (& "${bin}gen_crypto${exe}") -join "`n"
$stored = (Get-Content "godot/tests/crypto_vectors.json" -Raw -Encoding UTF8) -replace "`r`n", "`n"
if ($fresh.Trim() -eq $stored.Trim()) { Ok "crypto_vectors.json совпадает с тем, что выдаёт OpenSSL" } else { Fail "godot/tests/crypto_vectors.json устарел: пересоздайте (см. tools/gen_crypto_vectors.cpp)" }

Step "4. secure_server_app + secure_client_app по реальному UDP"
$common = @("protocol/protocol.cpp", "crypto/crypto.cpp", "crypto/secure_channel.cpp", "reliability/adaptive_timeout.cpp", "reliability/reliable_channel.cpp", "reliability/dedup_window.cpp", "telemetry/transport.cpp")
Build "secure_server_app" ($common + "server/secure_server.cpp")
Build "secure_client_app" ($common + "client/secure_client.cpp")
foreach ($loss in 0, 30) {
    $port = 27110 + $loss
    $log = "$Out/secure_server_loss$loss.log"
    $srv = Start-Process -FilePath "${bin}secure_server_app${exe}" -ArgumentList "$port --loss-percent=$loss --seed=5" -PassThru @hidden -RedirectStandardOutput $log
    Start-Sleep -Milliseconds 500
    $res = & "${bin}secure_client_app${exe}" 127.0.0.1 $port --count=6 --interval-ms=100 --max-attempts=10
    $rc = $LASTEXITCODE
    Stop-Quiet $srv
    Write-Host "  потери ${loss}%: $($res | Select-Object -Last 1)"
    if ($rc -eq 0) { Ok "все SHOOT доставлены и подтверждены (потери $loss%)" } else { Fail "клиент вернул код $rc (потери $loss%)" }
}

Step "5. Godot: run_crypto_tests.gd (+ совместимость с C++ secure_server_app)"
$ErrorActionPreference = "Continue"
& $Godot --headless --path godot --import 2>&1 | Out-Null
$srv = Start-Process -FilePath "${bin}secure_server_app${exe}" -ArgumentList "27095" -PassThru @hidden -RedirectStandardOutput "$Out/secure_server_godot.log"
Start-Sleep -Milliseconds 500
$gOut = & $Godot --headless --path godot -s res://tests/run_crypto_tests.gd -- --cpp-port=27095 2>&1
Stop-Quiet $srv
$ErrorActionPreference = "Stop"
$gOut | Select-String "FAIL|ok  |тестов|C\+\+ secure" | ForEach-Object { Write-Host "  $($_.Line)" }
$gl = ($gOut | Select-String "тестов" | Select-Object -Last 1).Line
if ($gl -match ", 0 провалено") { Ok $gl } else { Fail "тесты Godot: $gl" }

Step "6. Негативный тест: прокси портит бит шифртекста"
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) { Write-Host "  python не найден — шаг пропущен (python tools\udp_proxy.py --help)" -ForegroundColor Yellow }
else {
    $slog = "$Out/secure_server_tamper.log"
    $srv = Start-Process -FilePath "${bin}secure_server_app${exe}" -ArgumentList "27120" -PassThru @hidden -RedirectStandardOutput $slog
    $prx = Start-Process -FilePath $py.Source -ArgumentList "tools/udp_proxy.py --listen 27121 --target 127.0.0.1:27120 --tamper --quiet" -PassThru @hidden
    Start-Sleep -Milliseconds 700
    $res = & "${bin}secure_client_app${exe}" 127.0.0.1 27121 --count=2 --interval-ms=100 --max-attempts=3
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 300
    Stop-Quiet $prx; Stop-Quiet $srv
    $fails = (Select-String -Path $slog -Pattern "AUTH_FAIL" -Encoding UTF8 | Measure-Object).Count
    $applied = (Select-String -Path $slog -Pattern "ПРИМЕНЁН" -Encoding UTF8 | Measure-Object).Count
    Write-Host "  сервер: AUTH_FAIL = $fails, применено выстрелов = $applied; клиент: $($res | Select-Object -Last 1)"
    if ($fails -gt 0 -and $applied -eq 0 -and $rc -ne 0) { Ok "подделка отклонена, выстрел не применён" } else { Fail "подмена бита не была отклонена" }
}

Write-Host ""
if ($failures -gt 0) { Write-Host "Проваленных проверок: $failures" -ForegroundColor Red; exit 1 }
Write-Host "Все проверки ПР №6 прошли." -ForegroundColor Green
