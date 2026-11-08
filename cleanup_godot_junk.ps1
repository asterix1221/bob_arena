<#
.SYNOPSIS
  Очистка репозитория bob_arena от файлов, созданных Godot в корне
  (после случайного открытия/создания проекта не в папке godot/).

.DESCRIPTION
  По умолчанию скрипт работает в режиме ПОКАЗА (DryRun) — только выводит список.
  Для реального удаления запустите с ключом -Apply.

  Копируйте этот файл в КОРЕНЬ репозитория bob_arena (рядом с README.md)
  и запускайте из PowerShell:
      powershell -ExecutionPolicy Bypass -File .\cleanup_godot_junk.ps1          # показать
      powershell -ExecutionPolicy Bypass -File .\cleanup_godot_junk.ps1 -Apply   # удалить

  Ключ -KeepConfig сохраняет .editorconfig и .gitattributes (они безвредны).

.NOTES
  Проверено на структуре репозитория от 28.10.2026. Скрипт удаляет ТОЛЬКО
  явно перечисленные ниже пути — никаких общих масок вида *.import по всему диску.
#>
param(
    [switch]$Apply,
    [switch]$KeepConfig
)

$ErrorActionPreference = 'Stop'

# ---------- Проверки безопасности ----------
$ok1 = Test-Path 'godot\project.godot'   # настоящий проект лежит в godot/
$ok2 = Test-Path 'README.md'             # мы в корне репозитория
if (-not ($ok1 -and $ok2)) {
    Write-Host 'ОШИБКА: запустите скрипт из КОРНЯ репозитория bob_arena' -ForegroundColor Red
    Write-Host '(рядом с README.md; должен существовать godot\project.godot)'
    exit 1
}
if (-not (Test-Path 'project.godot') -and -not (Test-Path '.godot')) {
    Write-Host 'Похоже, мусор уже удалён — project.godot и .godot в корне отсутствуют.' -ForegroundColor Yellow
    exit 0
}

# ---------- Явный список целей ----------
# Одиночные файлы/папки в корне (созданы Godot 3 окт и 10 окт при случайном открытии)
$singleTargets = @(
    'project.godot',        # лишний конфиг проекта "bob_arena" (Godot 4.7) в корне
    'icon.svg',             # стандартная иконка Godot
    'icon.svg.import',      # метаданные импорта иконки
    '.godot'                # кэш редактора + импортированные текстуры (~весь мусор)
)

# Каталоги, куда Godot раскидал *.import рядом с картинками/CSV
$importDirs = @(
    'docs\game_shots',      # 21 файл .import (solo/, host/, client/)
    'docs\godot\media',     # 3 файла
    'docs\graphs',          # 5 файлов
    'docs\media'            # 3 файла
)
$importFiles = @(
    'docs\latency_samples.csv.import',
    'docs\reliability_samples.csv.import',
    'docs\rto_timeline.csv.import'
)

# Созданы вместе со случайным проектом (та же секунда, что icon.svg), но безвредны.
# Удаляются по умолчанию; ключ -KeepConfig оставит их.
$configTargets = @('.editorconfig', '.gitattributes')

# ---------- Сбор полного списка ----------
$plan = New-Object System.Collections.Generic.List[string]
foreach ($t in $singleTargets) { if (Test-Path $t) { $plan.Add($t) } }
foreach ($d in $importDirs) {
    if (Test-Path $d) {
        Get-ChildItem -Path $d -Recurse -Filter '*.import' -File |
            ForEach-Object { $plan.Add($_.FullName) }
    }
}
foreach ($f in $importFiles) { if (Test-Path $f) { $plan.Add($f) } }
if (-not $KeepConfig) { foreach ($c in $configTargets) { if (Test-Path $c) { $plan.Add($c) } } }

# ---------- Вывод / удаление ----------
if ($plan.Count -eq 0) {
    Write-Host 'Нечего удалять — всё уже чисто.' -ForegroundColor Green
    exit 0
}

Write-Host ("Найдено целей: {0}" -f $plan.Count) -ForegroundColor Cyan
$plan | Sort-Object | ForEach-Object { Write-Host "  $_" }

if (-not $Apply) {
    Write-Host ''
    Write-Host 'Это режим ПОКАЗА. Для реального удаления запустите с ключом -Apply' -ForegroundColor Yellow
    exit 0
}

$deleted = 0; $failed = 0
foreach ($p in $plan) {
    try {
        if (Test-Path $p -PathType Container) {
            Remove-Item -LiteralPath $p -Recurse -Force
        } else {
            Remove-Item -LiteralPath $p -Force
        }
        $deleted++
    } catch {
        Write-Host ("  НЕ УДАЛОСЬ: {0} ({1})" -f $p, $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
}

Write-Host ''
Write-Host ("Готово. Удалено: {0}. Ошибок: {1}." -f $deleted, $failed) -ForegroundColor Green
Write-Host 'Рабочий проект Godot не тронут — он лежит в папке godot\.'
Write-Host 'Открывайте в редакторе именно godot\project.godot.'
