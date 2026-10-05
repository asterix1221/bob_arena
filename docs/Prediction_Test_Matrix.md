# Prediction_Test_Matrix — матрица тестов ПР №4

Два варианта реализации (см. `docs/Prediction_Implementation.md`): **часть A — Godot 4** (запускалась, таблица ниже
заполнена фактическими числами) и **часть B — Unreal Engine** (код не запускался, строки пока пустые).

# Часть A — Godot 4

Версия движка: Godot **4.7.2** (headless, Linux). Сеть: реальный ENet на localhost, эмуляция — встроенный `NetEmu`
(задержка **в одну сторону** на исходящем трафике клиента и сервера, RTT ≈ 2 × lag). Применённые профили:
`none` (T1), `--lag=100 --jitter=0 --loss=0` (T2, T3, T6), `--lag=175 --jitter=25 --loss=4` (T4, T5).
Сценарии выполняет бот (`--bot=...`), логи — `docs/godot/runs/`, сводка — `docs/godot/runs/summary.md`.

| Тест | Сетевые условия | Действие | Ожидаемый результат | Фактический результат | Артефакт |
|---|---|---|---|---|---|
| T1 | Без эмуляции | Движение + рывок (`walk`, предсказание вкл.) | Плавное перемещение и репликация | 0 коррекций; локальный отклик 0 мс; подтверждение сервера 25 мс; сервер принял 1 рывок; финальная ошибка клиент↔сервер 0.000 px | `docs/godot/runs/T1_walk_noemu_pred.*.log` |
| T2 | 100 мс, 0% loss | Рывок **без** CSP (`dash_latency`, `--predict=0`) | Видимая задержка до подтверждения | Отклик на экране **241.5–241.7 мс** (3 рывка) ≈ RTT; 3 коррекции (макс. 22.67 px) — клиент догоняет серверный рывок; финальная ошибка 0.000 px | `docs/media/baseline_no_prediction.png`, `docs/godot/runs/T2_lag100_nopred.*.log` |
| T3 | 100 мс, 0% loss | Рывок **с** CSP (`--predict=1`) | Немедленный отклик, сервер сохраняет авторитетность | Локальный отклик **0 мс** (3 из 3); подтверждение сервера 234–242 мс (avg 236); 0 коррекций; сервер принял 3 / отклонил 0 | `docs/media/prediction_enabled.png`, `docs/godot/runs/T3_lag100_pred.*.log` |
| T4 | 175±25 мс, 4% loss | Движение и рывки, в т. ч. «до кулдауна» (`loss_mix`) | Недопустимое состояние не принимается; возможны коррекции | Сеть отбросила 40 из 1049 пакетов клиента; сервер принял 5 рывков, **отклонил 3** (`reason=cooldown`); 0 коррекций (избыточная отправка команд закрыла потери); финальная ошибка 0.000 px | `docs/godot/runs/T4_lag175loss4_pred.*.log` |
| T5 | 175±25 мс, 4% loss | Намеренное расхождение: чит клиента F1/F2 (`cheat`) | Клиент получает авторитетную коррекцию | Сервер отклонил рывок до кулдауна (`reason=cooldown`); 6 коррекций, макс. ошибка **206.27 px** (чит «рывок ×3»); после выключения чита — финальная ошибка **0.000 px**, соединение не рвалось | `docs/media/correction_example.png`, `docs/godot/runs/T5_lag175loss4_cheat.*.log` |
| T6 | 100 мс, 0% loss | Рывок у стены (`wall`) — доп. тест | Расхождения нет (одинаковые коллизии) | 0 коррекций, 2 рывка приняты, финальная ошибка 0.000 px | `docs/godot/runs/T6_lag100_wall.*.log` |

Оговорки: «Подтверждение сервера» включает ожидание снимка (30 Гц) и поэтому чуть больше RTT; в T4/T5 задержка с
джиттером, поэтому диапазоны шире. Числа пересчитываются запуском `tools/godot_scenarios.sh` (небольшие отклонения
между прогонами нормальны: часы реальные; повторный прогон на Godot 4.7.2 дал те же числа коррекций и отказов, а времена — T2: 225–234 мс, T3: подтверждение 250–303 мс, T5: 6 коррекций, макс. ошибка 161.55 px). Повторить: `.\run_godot_demo.ps1 -Godot "<путь>" -Role Scenarios`.

## Как собрать числа из лога (PowerShell 7)

```powershell
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Select-String -Path .\docs\godot\runs\T5_*.client.log -Pattern '^\[(DASH|CORRECTION|CHEAT|RESULT)\]' -Encoding utf8
```

---

# Часть B — матрица для варианта на Unreal Engine (не заполнена: движок не запускался)

Столбцы «Фактический результат» и «Артефакт» **заполняются по итогам реального прогона** в Unreal Engine —
автором заготовки они не заполнены намеренно (движок в среде разработки не запускался).

Версия Unreal Engine: **ЗАПОЛНИТЬ**. Фактически применённые команды эмуляции: **ЗАПОЛНИТЬ**.

| Тест | Сетевые условия | Действие | Ожидаемый результат | Фактический результат | Артефакт |
|---|---|---|---|---|---|
| T1 | Без эмуляции | Движение (+ рывок) | Плавное перемещение и репликация; на втором клиенте персонаж виден и двигается | _заполнить_ | _ссылка_ |
| T2 | 100 мс, 0% loss | Рывок без CSP (`bob.PredictDash 0`) | Видимая задержка до подтверждения (≈ RTT) | _заполнить: `[DASH] mode=NO_PREDICTION ... response=… ms`_ | _ссылка_ (`baseline_no_prediction.*`) |
| T3 | 100 мс, 0% loss | Рывок с CSP (`bob.PredictDash 1`) | Немедленный отклик, сервер сохраняет авторитетность | _заполнить: `PREDICTION key->local response=… ms`, затем `SERVER CONFIRMED … ms`_ | _ссылка_ (`prediction_enabled.*`) |
| T4 | 150–200 мс, 3–5% loss | Движение и рывок | Недопустимое состояние не принимается; возможны коррекции | _заполнить: число `[CORRECTION]`, были ли `REJECTED`_ | _ссылка_ |
| T5 | 150–200 мс, 3–5% loss | Намеренное расхождение (`BobCheatNoDashRules 1`, рывок до конца кулдауна) | Клиент получает авторитетную коррекцию | _заполнить: `SERVER REJECTED reason=cooldown`, `[CORRECTION] … error=… uu`_ | _ссылка_ (`correction_example.*`) |

### Как прогнать (PowerShell 7)

```powershell
# сборка редакторного таргета (нужны Visual Studio 2022 с C++ и Unreal Engine)
.\run_prediction_demo.ps1 -Role Build -EngineRoot "C:\Program Files\Epic Games\UE_5.8"

.\run_prediction_demo.ps1 -Role Both -Profile none        -Predict 1   # T1
.\run_prediction_demo.ps1 -Role Both -Profile lag100      -Predict 0   # T2
.\run_prediction_demo.ps1 -Role Both -Profile lag100      -Predict 1   # T3
.\run_prediction_demo.ps1 -Role Both -Profile lag150loss5 -Predict 1   # T4, T5
```

Эмуляция: профили в скрипте задают `NetEmulation.PktLag/PktLoss` клиенту. Если по Ping в HUD видно, что
задержка не применилась — введите команды вручную в консоль клиента (`~`):
`NetEmulation.PktLag 100` / `NetEmulation.PktLoss 0` либо `NetEmulation.PktLag 150`,
`NetEmulation.PktLagVariance 25`, `NetEmulation.PktLoss 5`. Перед чистовой записью сбросьте: `NetEmulation.PktLag 0`,
`NetEmulation.PktLoss 0`. Тот же результат даёт Play → Advanced Settings → Network Emulation (PIE).

### Сбор чисел из лога

Метки в логе — только латиница (нет проблем с кодировкой). Лог клиента — `Saved\Logs\BobArenaPrediction*.log`:

```powershell
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Select-String -Path .\Saved\Logs\BobArenaPrediction*.log -Pattern '\[DASH\]|\[CORRECTION\]|\[CHEAT\]' -Encoding utf8
```

Намеренное расхождение (T5): в консоли клиента `BobCheatNoDashRules 1`, затем дважды подряд Left Shift (второй
раз — до окончания кулдауна 1.5 с). Ожидается: на клиенте второй рывок «случается», на сервере
`[DASH] SERVER REJECTED ... reason=cooldown`, на клиенте `[CORRECTION]` и возврат к серверной позиции.
`BobCheatDashSpeed 3` даёт расхождение по дистанции даже без отказа.
