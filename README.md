<img width="1280" height="1147" alt="photo_2026-10-26_10-56-30" src="https://github.com/user-attachments/assets/1e7dec6a-f060-4950-a821-c0f28278677f" />

# Практическая работа №1 — UDP-протокол и архитектура

Консольные UDP-сервер и клиент на C++ для сквозного проекта — файтинга
в духе Smash Bros / Brawlhalla (в дальнейшем реализуется на Godot/GDScript).
Код кроссплатформенный (Winsock2 на Windows, Berkeley sockets на Linux),
что позволило проверить всю логику локально (127.0.0.1) перед переносом
на Windows 11.

## Структура репозитория

```
pract1/
├── common/
│   ├── protocol.h         — структуры пакетов, enum PacketType, CRC32
│   ├── protocol.cpp       — реализация CRC32
│   └── net_common.h       — кроссплатформенная обёртка сокетов
├── server/server.cpp      — UDP-сервер
├── client/client.cpp      — UDP-клиент
├── docs/
│   ├── Architecture_Design.md
│   ├── Protocol_Specification.md
│   └── mechanics.md
└── README.md
```

## Что реализовано

- [x] UDP-сервер: приём пакетов, разбор заголовка, обработка команд, лог
- [x] UDP-клиент: отправка команд раз в секунду, вывод ответа сервера
- [x] Минимум два типа команд: `MOVEMENT` и `SHOOT`
- [x] Расширенные типы под будущие механики: `ATTACK_LIGHT/HEAVY`, `SHIELD`,
      `RUNE_PICKUP`, `WEAPON_PICKUP` (зарезервированы в протоколе)
- [x] Доп. задание: поле `checksum` (CRC32) в заголовке, проверка на сервере
- [x] Доп. задание: простая авторизация по логину/паролю
- [x] Архитектурная документация (`docs/Architecture_Design.md`)
- [x] Спецификация протокола (`docs/Protocol_Specification.md`)
- [x] Механики (`docs/mechanics.md`)

## Сборка и запуск на Windows 11

Нужен один из вариантов компилятора C++ (если ещё не установлен):

**Вариант A — MinGW-w64 (проще всего)**
1. Установить [MSYS2](https://www.msys2.org/) (скачать установщик и пройти его).
2. В терминале MSYS2 UCRT64 выполнить: `pacman -S mingw-w64-ucrt-x86_64-gcc`
3. Добавить в PATH: `C:\msys64\ucrt64\bin`
4. Собрать (из PowerShell/CMD в папке проекта):
   ```
   g++ -std=c++17 common\protocol.cpp server\server.cpp -o server_app.exe -lws2_32
   g++ -std=c++17 common\protocol.cpp client\client.cpp -o client_app.exe -lws2_32
   ```

**Вариант B — Visual Studio**
1. Установить [Visual Studio Community](https://visualstudio.microsoft.com/) с компонентом
   «Разработка классических приложений на C++» (Desktop development with C++).
2. Открыть «Developer Command Prompt for VS» в папке проекта и выполнить:
   ```
   cl /std:c++17 /EHsc common\protocol.cpp server\server.cpp /Fe:server_app.exe ws2_32.lib
   cl /std:c++17 /EHsc common\protocol.cpp client\client.cpp /Fe:client_app.exe ws2_32.lib
   ```
   (`ws2_32.lib` подключать не обязательно вручную для server.cpp/client.cpp —
   она уже подключена через `#pragma comment(lib, "ws2_32.lib")` в
   `net_common.h`, но для MinGW явный флаг `-lws2_32` всё равно нужен.)

### Запуск

**Важно про PowerShell:** в отличие от `cmd.exe`, PowerShell из соображений
безопасности не запускает исполняемые файлы из текущей папки по голому
имени — нужно явно указывать путь `.\`, иначе будет ошибка
«The term ... is not recognized...». Правильно так:

В одном окне терминала:
```
.\server_app.exe 27015
```

В другом окне:
```
.\client_app.exe 127.0.0.1 27015 player1 pass1 10
```
(логин/пароль по умолчанию — `player1`/`pass1` или `player2`/`pass2`,
последний аргумент — число итераций, по умолчанию 10).

Может понадобиться разрешить приложению доступ в брандмауэре Windows при
первом запуске (достаточно для локальной сети/`127.0.0.1`).

**Про кириллицу в консоли.** Исходники в UTF-8, а консоль Windows по
умолчанию использует кодовую страницу OEM (обычно 866 для русской
локали) — без явной настройки кириллический текст в `printf` выводится
нечитаемой тарабарщиной («╨г╨б╨Я...»). Сервер и клиент сами переключают
кодовую страницу консоли на UTF-8 при старте (`SetConsoleOutputCP(CP_UTF8)`
в `net_common.h`), поэтому после пересборки из этого репозитория текст
должен отображаться корректно. Если всё ещё видны кракозябры — скорее
всего используется классический `cmd.exe`/PowerShell с растровым шрифтом
консоли (Raster Fonts): переключите шрифт консоли на TrueType (например,
Consolas) в свойствах окна или запускайте через
[Windows Terminal](https://apps.microsoft.com/detail/9n0dx20hk701), который
поддерживает UTF-8 «из коробки».

## Работа с GitVerse

Локальный git-репозиторий с историей коммитов, имитирующей план работы
из задания (см. вывод `git log`), уже подготовлен в этой папке. Чтобы
опубликовать в GitVerse:

```
git remote add origin https://github.com/asterix1221/bob_arena
git branch -M main
git push -u origin main
git push -u origin feature/udp-echo
```

Дальше — по плану задания: Pull Request из `feature/udp-echo` в `main` с
описанием изменений.

## Дальнейшее развитие (за рамками пр. работы №1)

Для будущей полноценной сетевой части файтинга стоит рассмотреть готовые
библиотеки поверх «сырых» сокетов — надёжную доставку, борьбу с потерей
пакетов, компрессию состояния и NAT-punching:

- [GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets) (Valve)
- [yojimbo](https://github.com/mas-bandwidth/yojimbo)

Обе реализуют поверх UDP надёжные и ненадёжные каналы, что удобно для
файтинга: позиции/удары — по ненадёжному каналу с высокой частотой,
критичные события (смерть, подбор руны) — по надёжному.

---

# Практическая работа №2 — телеметрия UDP-соединения (RTT/SRTT/джиттер/потери)

Продолжает ПР №1: добавлена ИЗОЛИРОВАННАЯ подсистема телеметрии — свои
PING/PONG-пакеты, свой протокол (не путать с `common/protocol.h` из ПР №1),
свой порт (`27016` вместо `27015`), измеряющая RTT, сглаженный RTT (SRTT),
джиттер и долю потерь на UDP-соединении. Она понадобится в ПР №3 при
реализации ACK/тайм-аутов/повторных передач. Причины держать её отдельно
от игрового протокола ПР №1 подробно объяснены в комментарии к
`protocol/protocol.h` и в приложении к `docs/Protocol_Specification.md`.

## Что добавлено (структура)

```
bob_arena/
├── protocol/                       — НОВОЕ: контракт протокола телеметрии
│   └── protocol.h / protocol.cpp   — PING/PONG, явная сериализация
│                                      (WriteU16/WriteU64/ReadU16/ReadU64,
│                                      сетевой порядок байт, БЕЗ memcpy structs)
├── telemetry/                      — НОВОЕ: расчёт метрик телеметрии
│   ├── telemetry.h / telemetry.cpp — RTT/SRTT/джиттер, inFlight-контейнер,
│   │                                  классификация ответов, ComputeSeriesStats
│   │                                  для офлайн-статистики по CSV
│   └── transport.h / transport.cpp — тонкая обёртка UDP-сокета (только
│                                       сетевой ввод-вывод, без знания о
│                                       формате пакетов и метриках)
├── client/ping_client.cpp          — НОВОЕ: UDP-клиент серии PING
├── server/pong_server.cpp          — НОВОЕ: UDP-сервер PONG с флагами
│                                       эмуляции задержки/джиттера/потерь
├── tests/
│   ├── mini_test.h                 — крошечный header-only test-harness
│   │                                  (без внешних зависимостей, как и ПР №1)
│   ├── test_protocol.cpp           — сериализация PING/PONG + отбраковка
│   │                                  некорректных датаграмм (13 тестов)
│   ├── test_telemetry.cpp          — RTT/SRTT/джиттер/статусы/статистика
│   │                                  (10 тестов)
│   └── test_main.cpp               — точка входа тестового бинарника
├── analysis/analyze_latency.py     — считает статистику по CSV и строит
│                                       3 обязательных графика (Python/matplotlib)
├── run_experiments.sh              — прогоняет все 6 серий эксперимента подряд (bash)
├── run_experiments.ps1             — то же самое нативным PowerShell (без Git Bash/WSL)
└── docs/
    ├── Protocol_Specification.md   — дополнен приложением про PING/PONG
    ├── Experiment_Config.md        — НОВОЕ: параметры/среда/seed'ы эксперимента
    ├── Latency_Report.md           — НОВОЕ: таблица метрик + 3 графика + разбор
    ├── latency_samples.csv         — НОВОЕ: журнал измерений (реальный прогон)
    └── graphs/                     — НОВОЕ: latency_by_measurement.png,
                                        mean_rtt_srtt_loss.png, rtt_distribution.png
```

## Что реализовано

- [x] Контракт пакетов PING (клиент→сервер) / PONG (сервер→клиент): версия
      протокола, порядковый номер, размер payload — заголовок 7 байт
- [x] Явная сериализация в сетевом порядке байт (`WriteU16/WriteU64/
      ReadU16/ReadU64`), без побайтового копирования структур
- [x] Валидация ДО чтения: длина заголовка, `packetType`, версия,
      совпадение `payloadSize` с длиной датаграммы, границы буфера —
      некорректная датаграмма отбрасывается без падения процесса, с логом
- [x] Три раздельных модуля `protocol` / `telemetry` / `transport`,
      не смешивающих сетевой ввод, сериализацию и расчёт метрик
- [x] RTT по монотонным часам клиента (`std::chrono::steady_clock`),
      SRTT по формуле `0.875·SRTT + 0.125·RTT`, ограниченный (bounded)
      контейнер `inFlight`
- [x] Статусы `received` / `timeout` / `late_response` /
      `duplicate_response` / `unknown_response`
- [x] CSV-журнал `docs/latency_samples.csv` в формате из задания
- [x] Автотесты сериализации, ошибочных пакетов и статистики
      (23 теста, все проходят — см. «Как собрать и прогнать» ниже)
- [x] `docs/Experiment_Config.md` и `docs/Latency_Report.md` с тремя графиками
- [x] Реальный (не смоделированный вручную) прогон всех 6 серий: `baseline`,
      `delay_50`, `delay_100`, `jitter`, `loss_5`, `combined` — по 60 PING
      каждая (минимум по заданию — 50), интервал 300 мс
- [x] Эмуляция задержки/джиттера/потерь встроена в `pong_server_app`
      (флаги `--delay-ms`/`--jitter-min-ms`/`--jitter-max-ms`/
      `--loss-percent`/`--seed`) — явно задокументировано в
      `docs/Experiment_Config.md`, почему не использован Clumsy
      (инструмент только под Windows, недоступен в среде сборки/проверки)
- [ ] Ветка `feature/latency-measurement`, issues, Pull Request, ревью —
      подготовлены ЛОКАЛЬНО (см. раздел «Git-workflow» ниже), но не
      запушены в GitHub/GitVerse — для этого нужны ваши учётные данные,
      см. инструкцию ниже

## Сборка и запуск

> **Важно про перенос строк в командах:** символ `\` в конце строки
> означает «продолжение команды на следующей строке» только в
> bash/sh/zsh (Linux/macOS/Git Bash/WSL). В PowerShell это НЕ работает —
> там для переноса нужен обратный апостроф `` ` ``, а в cmd.exe — `^`.
> Если скопировать bash-многострочную команду в обычный PowerShell,
> `\` попадёт в команду как обычный (лишний) аргумент, и g++/clang
> передаст его линкеру как «файл», которого не существует — отсюда
> ошибка вида `ld.exe: cannot find \: No such file or directory`
> (подробности и разбор — в разделе «Баги, обнаруженные в процессе
> разработки» в конце README). Поэтому ниже все команды даны в ОДНУ
> строку — их можно копировать в PowerShell как есть.

**PowerShell / cmd.exe (Windows, MinGW из MSYS2 — как в разделе ПР №1):**
```
g++ -std=c++17 -O2 protocol/protocol.cpp telemetry/telemetry.cpp telemetry/transport.cpp client/ping_client.cpp -o ping_client_app.exe -lws2_32
g++ -std=c++17 -O2 protocol/protocol.cpp telemetry/transport.cpp server/pong_server.cpp -o pong_server_app.exe -lws2_32
```
`-lws2_32` обязателен для MinGW (тот же нюанс, что и в ПР №1: MinGW/GCC
не обрабатывает `#pragma comment(lib, ...)` — это расширение только
MSVC, — поэтому без явного флага будет `undefined reference to
WSAStartup` при линковке).

**Developer Command Prompt for VS (MSVC):**
```
cl /std:c++17 /EHsc protocol/protocol.cpp telemetry/telemetry.cpp telemetry/transport.cpp client/ping_client.cpp /Fe:ping_client_app.exe ws2_32.lib
cl /std:c++17 /EHsc protocol/protocol.cpp telemetry/transport.cpp server/pong_server.cpp /Fe:pong_server_app.exe ws2_32.lib
```

**Linux/macOS/Git Bash/WSL (bash):**
```bash
g++ -std=c++17 -O2 protocol/protocol.cpp telemetry/telemetry.cpp telemetry/transport.cpp client/ping_client.cpp -o ping_client_app
g++ -std=c++17 -O2 protocol/protocol.cpp telemetry/transport.cpp server/pong_server.cpp -o pong_server_app
```
(`-lws2_32` здесь не нужен — это чисто Windows-библиотека.)

**Одна серия вручную** (два окна терминала; путь к `.exe` в PowerShell —
через `.\`, в cmd.exe можно и без):
```
.\pong_server_app.exe 27016 --delay-ms=50
.\ping_client_app.exe 127.0.0.1 27016 delay_50 60 300 docs/latency_samples.csv
```

**Все 6 серий сразу:**
- Linux/macOS/Git Bash/WSL — `run_experiments.sh` (bash):
  ```bash
  CLIENT=./ping_client_app SERVER=./pong_server_app ./run_experiments.sh
  python3 analysis/analyze_latency.py
  ```
- Нативный Windows PowerShell (без bash) — `run_experiments.ps1`,
  делает то же самое средствами PowerShell:
  ```powershell
  .\run_experiments.ps1
  python analysis/analyze_latency.py
  ```

**Тесты:**
```
g++ -std=c++17 protocol/protocol.cpp telemetry/telemetry.cpp tests/test_protocol.cpp tests/test_telemetry.cpp tests/test_main.cpp -o telemetry_tests.exe
.\telemetry_tests.exe
```
(на Linux/macOS/Git Bash — то же самое, но без `.exe` и запуск через `./telemetry_tests`.)
Ожидаемый результат: `23 тестов, 0 провалено`.

## Git-workflow (ветка/issues/PR)

В этой среде нет доступа к вашему GitHub-аккаунту, поэтому issues и Pull
Request нельзя создать программно — они требуют ваших учётных данных
через веб-интерфейс или `gh`/API с токеном. Вместо этого здесь ЛОКАЛЬНО
подготовлено то, что можно сделать без сетевого доступа к GitHub:

- ветка `feature/latency-measurement`, ответвлённая от `main`;
- история коммитов на этой ветке, повторяющая этапы из таблицы
  «План выполнения» задания (проектирование → реализация →
  базовый тест → конфигурация → эксперимент → анализ/отчёт).

Чтобы опубликовать и довести до Pull Request, после `git push`:

```
git push -u origin feature/latency-measurement
```

1. Создайте на GitHub/GitVerse issues по числу этапов (например:
   «Контракт протокола PING/PONG», «Модуль telemetry: RTT/SRTT/джиттер»,
   «CSV-журнал и базовый baseline-тест», «Experiment_Config.md»,
   «Прогон 6 серий эксперимента», «Latency_Report.md + графики») и
   свяжите с ними соответствующие коммиты (`Fixes #N` в сообщении коммита
   при последующих правках, если понадобятся).
2. Откройте Pull Request `feature/latency-measurement` → `main`, в
   описание можно скопировать раздел «Что реализовано» выше.
3. Попросите участника команды сделать ревью (по заданию — обязательный
   пункт) и по его комментариям при необходимости дополните ветку.

## Известные ограничения / что не проверялось "физически"

- Эксперимент прогнан по локальной петле (`127.0.0.1`) в Linux-песочнице,
  а не на двух отдельных машинах в реальной сети — искусственные
  задержка/джиттер/потери эмулированы сервером (см. `Experiment_Config.md`
  и обоснование там же); формулы и код от этого не зависят и одинаково
  работают что на loopback, что в реальной сети, что на Windows 11.
- Статусы `late_response`/`duplicate_response`/`unknown_response`
  не встретились в реальном прогоне (максимальная искусственная задержка
  250 мс с большим запасом меньше тайм-аута 1000 мс) — они покрыты
  модульными тестами (`tests/test_telemetry.cpp`), подробности — в
  `docs/Latency_Report.md`, раздел «Почему не наблюдались...».

## Если IDE подсвечивает `std::optional`/`std::nullopt` как ошибку

Реальная сборка (`g++ -std=c++17 ...` / `cl /std:c++17 ...`, как показано
выше) от этой проблемы не страдает — она проверена и в g++, и в clang
(в т.ч. принудительно с флагом `-std=c++17`). Если редактор (VS Code,
CLion и т.п.) всё равно подчёркивает `std::optional`/`std::nullopt`
красным с сообщением вида *"no template named 'optional' in namespace
'std'"*, это ложное срабатывание анализатора кода (IntelliSense/clangd),
который без явной настройки проекта иногда разбирает файлы со старым
стандартом (C++14) вместо C++17, где `<optional>` ещё не существовал —
воспроизведено и подтверждено принудительным запуском с `-std=gnu++14`.

Чтобы редактор тоже узнал про C++17, в репозиторий добавлены:
- `compile_flags.txt` (корень репозитория) — читается `clangd` (расширение
  clangd для VS Code, CLion, Neovim/Vim с LSP, Sublime) автоматически,
  без дополнительной настройки.
- `.vscode/c_cpp_properties.json` — для официального расширения
  Microsoft C/C++ (IntelliSense) в VS Code, `"cppStandard": "c++17"`
  для конфигураций Win32 и Linux.

После добавления этих файлов красные подчёркивания должны исчезнуть
(в VS Code иногда требуется "C/C++: Reset IntelliSense Database" из
палитры команд или перезапуск редактора). Заодно в `common/net_common.h`
добавлено `#define _CRT_SECURE_NO_WARNINGS` для Windows — это убирает
настоящее (не только IDE) предупреждение MSVC про `fopen` в
`client/ping_client.cpp` ("consider using fopen_s instead"): `fopen` тут
использован намеренно ради переносимости между Windows и Linux, `fopen_s`
такой возможности не даёт.

## Баги, обнаруженные в процессе разработки

Раздел для проблем, которые реально возникли при работе над проектом
(в основном — на моей Windows 11 при первой попытке собрать и запустить
ПР №2), вместе с тем, как они были найдены и исправлены.

### 1. `ld.exe: cannot find \: No such file or directory` при сборке в PowerShell

**Симптом:** копирование команды сборки из README в PowerShell 7
(`g++ ... \` + перенос на следующую строку) падало с ошибкой линковки
про несуществующий файл `\`, и то же самое для `pong_server_app`.

**Причина:** символ `\` в конце строки — это line-continuation ТОЛЬКО
для bash/sh/zsh. В PowerShell (и в cmd.exe) `\` не имеет такого смысла:
это либо обычный разделитель пути, либо просто символ. Когда команда
из README (написанная в bash-стиле, как это часто делают в туториалах)
попадала в PowerShell, `\` оставался в командной строке как отдельный,
ничем не оправданный аргумент; g++ передавал его линкеру как «входной
файл», а линкер закономерно не мог найти файл с именем `\`.

**Как подтверждено:** причина не осталась гипотезой — я скачал и
запустил ровно ту же версию PowerShell (7.6.6) в тестовом окружении и
дословно воспроизвёл ошибку пользователя на многострочной команде с
`\` (`/usr/bin/ld: cannot find \: No such file or directory` — то же
сообщение, только путь к `ld` другой, так как тест шёл на Linux).
Однострочная версия той же команды в том же PowerShell отрабатывает
без единой ошибки.

**Исправление:** все команды сборки в `README.md` и
`docs/Experiment_Config.md` переписаны в одну строку — без `\` вообще,
чтобы их можно было копировать в любой терминал (PowerShell, cmd.exe,
bash) одинаково безопасно. Раздел «Сборка и запуск» также явно
предупреждает про разницу между `\` (bash), `` ` `` (PowerShell) и `^`
(cmd.exe), чтобы при появлении новых команд в будущем не наступить на
те же грабли.

### 2. Скрытая вторая проблема: MinGW игнорирует `#pragma comment(lib, ...)`

Даже после исправления бага №1 следующая же попытка собрать
`ping_client_app`/`pong_server_app` под MinGW привела бы к `undefined
reference to WSAStartup` при линковке, потому что `common/net_common.h`
подключает `ws2_32.lib` через `#pragma comment(lib, "ws2_32.lib")` —
а это расширение понимает только MSVC; GCC/MinGW его молча
игнорирует (подтверждено несколькими независимыми источниками,
включая обсуждения на forum.qt.io и sourceforge.net/p/mingw, и это же
уже было верно подмечено в README для ПР №1). Для ПР №1 (`server_app`/
`client_app`) явный флаг `-lws2_32` уже был в командах сборки, а вот
в новые команды ПР №2 я его изначально не добавил в саму
копируемую строку (только упомянул отдельным предложением ниже —
что было легко пропустить).

**Исправление:** `-lws2_32` теперь встроен прямо в команды сборки для
PowerShell/cmd.exe в README.md, а не вынесен в отдельную сноску.

### 3. `run_experiments.sh` — bash-скрипт, не запускается в «голом» PowerShell

`run_experiments.sh` написан на bash и требует Git Bash/WSL — в
нативном PowerShell без них он не выполнится. Поскольку у автора
задачи не было под рукой Git Bash/WSL (судя по вопросу — только
MSYS2/MinGW + PowerShell), это тоже стало бы следующим препятствием.

**Исправление:** добавлен `run_experiments.ps1` — независимый скрипт
на чистом PowerShell с той же логикой (поднимает сервер с нужными
флагами и seed, ждёт, запускает клиента, останавливает сервер, и так
для всех 6 серий). Реально запущен и проверен в PowerShell 7.6.6
(та же версия, что у автора задачи, скачана отдельно для проверки) —
все 6 серий отрабатывают, `docs/latency_samples.csv` заполняется
корректно, процессы серверов корректно завершаются после каждой серии.

Промежуточная ошибка при первой версии этого скрипта: путь к CSV по
умолчанию был `docs\latency_samples.csv` (с обратным слешем, как
принято писать пути на Windows) — на Windows это сработало бы
корректно, но чтобы полноценно проверить сам скрипт независимо от ОС
(а заодно на будущее не зависеть от того, на какой ОС его в следующий
раз тестируют), путь по умолчанию исправлен на `docs/latency_samples.csv`
(прямой слеш) — Windows одинаково понимает оба варианта, а тестировать
и переносить такой путь проще.


---

# Практическая работа №3 — надёжная доставка поверх UDP (ACK, RTO, повторная передача)

Продолжает ПР №1 и ПР №2: на тех же модулях `protocol` и `telemetry` построен
механизм подтверждений (ACK), адаптивного тайм-аута повторной передачи (RTO по
SRTT/RTTVAR, как в TCP) и повторной отправки критичной команды `SHOOT`.
Подробный отчёт с таблицами, графиками и ответами на вопросы для защиты —
`docs/Reliability_Protocol.md`.

> **Совместимость с ПР №2.** Формат пакетов повышен до версии 2 (заголовок
> 8 байт вместо 7: добавлено поле `requiresAck`). Пакеты версии 1 новые
> бинарники отбрасывают, поэтому `ping_client_app` / `pong_server_app` /
> `telemetry_tests` нужно пересобрать из этого репозитория (команды сборки ПР №2
> выше остаются верными). `.exe` из корня архива уже пересобраны под Windows (MinGW,
> статическая линковка).

## Что добавлено (структура)

```
bob_arena/
├── protocol/protocol.h/.cpp        — РАСШИРЕНО: тип ACK, поле requiresAck,
│                                      команды MOVEMENT / SHOOT, версия 2
├── reliability/                    — НОВОЕ (без сокетов и без чтения часов)
│   ├── reliable_channel.hpp/.cpp   — ReliableChannel: учёт неподтверждённых
│   │                                  пакетов, выдача на повтор, failed_
│   ├── adaptive_timeout.hpp/.cpp   — AdaptiveTimeout: SRTT/RTTVAR/RTO (Jacobson/Karn)
│   └── dedup_window.hpp/.cpp       — окно дедупликации на сервере
├── client/reliable_client.cpp      — НОВОЕ: клиент (SHOOT с ACK + PING для RTT)
├── server/reliable_server.cpp      — НОВОЕ: сервер (ACK, дедупликация, эмуляция сети)
├── tests/
│   ├── test_reliable_channel.cpp   — ReliableChannel, DedupWindow, симуляция с потерями
│   ├── test_adaptive_timeout.cpp   — формулы RTO, границы, всплеск задержки
│   └── test_reliable_protocol.cpp  — ACK/requiresAck/SHOOT/MOVEMENT, отбраковка пакетов
├── analysis/analyze_reliability.py — таблицы, сверка с логами сервера, 2 графика
├── run_reliability_experiments.sh / .ps1 — прогон всех серий (bash / PowerShell)
└── docs/
    ├── Reliability_Protocol.md     — НОВОЕ: отчёт
    ├── reliability_samples.csv     — НОВОЕ: журнал доставки (по строке на команду)
    ├── rto_timeline.csv            — НОВОЕ: ряд измерений RTO (для графика)
    ├── server_rel_*.log            — НОВОЕ: логи сервера по сериям
    ├── Protocol_Specification.md   — дополнен приложением про ACK и requiresAck
    └── graphs/                     — + attempts_vs_loss.png, rto_over_time.png
```

## Что реализовано

- [x] Расширение протокола: тип `ACK`, поле `requiresAck`, `struct AckPayload`,
      ручная сериализация в сетевом порядке байт, валидация длины/версии/типа/флага до чтения полей
- [x] Разделение команд: `SHOOT` — надёжная, `MOVEMENT` — ненадёжная (обоснование в отчёте),
      `PING`/`PONG` и `ACK` подтверждений не требуют (ACK с `requiresAck = 1` отбрасывается)
- [x] `ReliableChannel` (`OnSent`, `OnAckReceived`, `CollectForRetransmission`,
      `PendingCount`, `FailedCount`) без обращения к сокетам; дубликат ACK игнорируется;
      пакет не возвращается чаще раза в RTO; после `maxAttempts` попыток уходит в `failed_`
      с записью в лог
- [x] `AdaptiveTimeout`: `RTTVAR = 0.75·RTTVAR + 0.25·|SRTT − RTT|`, `RTO = SRTT + 4·RTTVAR`,
      границы [100 мс, 3000 мс], инициализация первым сэмплом; питается RTT из PING/PONG (ПР №2)
      и временем до ACK
- [x] Сервер: ACK сразу при `requiresAck = 1`, затем эффект; `DedupWindow` не даёт применить
      эффект повторно, ACK на дубликат отправляется снова
- [x] Клиент: регистрация в `ReliableChannel`, повторная отправка в каждом такте цикла,
      лог «выстрел не подтверждён сервером» при окончательной недоставке
- [x] Эксперимент: 6 обязательных серий по 200 команд (минимум 50) + 3 вспомогательные
      (сравнение с фиксированным RTO 1000 мс / 100 мс и демонстрация `failed`);
      `docs/reliability_samples.csv`, 2 графика, таблица в отчёте
- [x] Автотесты: 62 теста в сумме (23 из ПР №2 + 39 новых), включая дублирование ACK,
      истечение попыток и сквозную симуляцию с потерями; тесты также проходят под
      AddressSanitizer + UBSan
- [x] `docs/Reliability_Protocol.md`, дополненный `docs/Protocol_Specification.md`
- [ ] Ветка `feature/reliable-delivery`, issues, Pull Request, ревью — ветка и коммиты
      подготовлены ЛОКАЛЬНО, issues/PR создаются вручную (см. «Git-workflow» ниже)

## Сборка и запуск

Все команды в одну строку (в PowerShell `\` для переноса строк не работает — см.
«Баги ... в процессе разработки» ниже). Нужен `-lws2_32` для MinGW.

**PowerShell / cmd.exe (Windows, MinGW из MSYS2):**
```
g++ -std=c++17 -O2 protocol/protocol.cpp reliability/adaptive_timeout.cpp reliability/reliable_channel.cpp telemetry/telemetry.cpp telemetry/transport.cpp client/reliable_client.cpp -o reliable_client_app.exe -lws2_32
g++ -std=c++17 -O2 protocol/protocol.cpp reliability/dedup_window.cpp telemetry/transport.cpp server/reliable_server.cpp -o reliable_server_app.exe -lws2_32
```

**Developer Command Prompt for VS (MSVC):**
```
cl /std:c++17 /EHsc protocol/protocol.cpp reliability/adaptive_timeout.cpp reliability/reliable_channel.cpp telemetry/telemetry.cpp telemetry/transport.cpp client/reliable_client.cpp /Fe:reliable_client_app.exe ws2_32.lib
cl /std:c++17 /EHsc protocol/protocol.cpp reliability/dedup_window.cpp telemetry/transport.cpp server/reliable_server.cpp /Fe:reliable_server_app.exe ws2_32.lib
```

**Linux/macOS/Git Bash/WSL (bash):** те же команды без `.exe` и без `-lws2_32`.

**Одна серия вручную** (два окна терминала; порт по умолчанию `27017`):
```
.\reliable_server_app.exe 27017 --loss-percent=10 --seed=1
.\reliable_client_app.exe 127.0.0.1 27017 loss_10 100 100 docs/reliability_samples.csv
```
Флаги сервера: `--loss-percent`, `--delay-ms`, `--jitter-min-ms`, `--jitter-max-ms`, `--seed`,
`--dedup-window`. Потери применяются независимо в каждую сторону (к входящим пакетам и к
исходящим ACK/PONG). Дополнительные флаги клиента: `--max-attempts=N`, `--fixed-rto-ms=N`
(постоянный RTO вместо адаптивного), `--ping-interval-ms=N`, `--rto-csv=путь`.

**Все серии сразу:**
- PowerShell (без bash): 
  ```powershell
  .\run_reliability_experiments.ps1
  python analysis/analyze_reliability.py
  ```
  Параметры: `-Count 50 -IntervalMs 100`. Полный прогон при 200 командах занимает около 5 минут.
- bash:
  ```bash
  COUNT=200 CLIENT=./reliable_client_app SERVER=./reliable_server_app ./run_reliability_experiments.sh
  python3 analysis/analyze_reliability.py
  ```

`analyze_reliability.py` печатает таблицы для отчёта, сверяет журнал клиента с логами
сервера (ни один эффект не применён дважды, каждая подтверждённая команда применена)
и строит графики в `docs/graphs/`. Требуется `matplotlib`.

**Тесты (все: ПР №2 + ПР №3):**
```
g++ -std=c++17 protocol/protocol.cpp telemetry/telemetry.cpp reliability/adaptive_timeout.cpp reliability/reliable_channel.cpp reliability/dedup_window.cpp tests/test_protocol.cpp tests/test_telemetry.cpp tests/test_reliable_protocol.cpp tests/test_adaptive_timeout.cpp tests/test_reliable_channel.cpp tests/test_main.cpp -o telemetry_tests.exe
.\telemetry_tests.exe
```
Ожидаемый результат: `62 тестов, 0 провалено`. Тестовый харнесс — `tests/mini_test.h`
(как в ПР №2, без Catch2; три теста из задания перенесены дословно).

## Git-workflow (ветка/issues/PR)

Локально создана ветка `feature/reliable-delivery` (от `main`/текущей ветки ПР №2) с коммитами
вида `feat: extend protocol with ACK ...`, `feat: ack-based retransmission ...`,
`feat: adaptive RTO ...`, `docs: add reliability report`. Публикация:

```
git push -u origin feature/reliable-delivery
```

Затем вручную: issues на каждую подзадачу (расширение протокола; `ReliableChannel`;
`AdaptiveTimeout`; клиент/сервер с ACK и дедупликацией; тесты; эксперимент и графики;
отчёт), Pull Request `feature/reliable-delivery` → `main`, ревью участником команды.

## Известные ограничения

- Эксперимент выполнен по локальной петле в Linux-песочнице; потери, задержка и джиттер
  эмулируются сервером (как в ПР №2; Clumsy — только Windows). Сборка под Windows проверена
  MinGW-кросс-компиляцией, но запуск на Windows 11 и PowerShell-скрипт
  `run_reliability_experiments.ps1` в этой среде НЕ выполнялись (написан по образцу
  `run_experiments.ps1` из ПР №2, который был проверен).
- На Windows таймер сокета и `Sleep` имеют гранулярность около 1–15 мс, поэтому эмулируемая
  задержка и такт клиента (2 мс) там менее точны, чем на Linux; на выводы по формулам это
  не влияет, но числа в таблицах будут немного другими.
- Реальная доля потерь в серии (200 команд) отличается от номинальной на несколько
  процентных пунктов — см. таблицу в отчёте.
- `failed` означает «ACK не получен», а не «сервер не применил команду»: сервер мог
  применить выстрел, но все ACK потерялись (пример — seq 107 в `jitter_loss_10`).

## Баги и нюансы, найденные в процессе разработки ПР №3

1. **Потерянный хвост лога сервера.** Сервер останавливают принудительно (`kill` /
   `Stop-Process`), а при перенаправлении вывода в файл `stdout` буферизован — последние
   строки лога пропадали, и сверка «эффекты на сервере ↔ журнал клиента» врала.
   Исправление: `setvbuf(stdout, nullptr, _IONBF, 0)` в `reliable_server.cpp`.
2. **RTO до первого измерения.** Код из задания даёт RTO = 0 (затем 100 мс по нижней границе),
   поэтому до первого RTT клиент слал бы ложные повторы. Добавлено начальное значение 1000 мс
   (RFC 6298).
3. **Сэмпл RTT от повторно отправленного пакета** искажал бы SRTT (неизвестно, на какую
   отправку пришёл ACK): учитываются только ACK на пакеты, отправленные с первой попытки
   (правило Карелса).
4. **Недетерминированный порядок `unordered_map`.** `CollectForRetransmission` сортирует
   результат по времени первой отправки, иначе повторы и тесты зависели бы от реализации
   стандартной библиотеки.
5. **Несовместимость версий протокола.** Повышение версии протокола сделало бинарники ПР №2
   несовместимыми — это зафиксировано в блоке «Совместимость с ПР №2» выше.
6. **Кириллица в выводе тестов (PowerShell 7 / cmd).** `tests/test_main.cpp` не переключал
   консоль на UTF-8, и названия тестов выводились как `╤В╨╡╤Б╤В╤Л` (консоль Windows по умолчанию
   в CP866/CP437, а исходники и вывод — UTF-8). Исправление: `enable_utf8_console()` в `main`
   тестов — та же функция, что уже используется клиентами и серверами. Затронуты были и тесты
   ПР №2. Если после пересборки всё равно видны искажённые символы, проверьте шрифт консоли
   (нужен TrueType, например Cascadia/Consolas) или выполните `chcp 65001` перед запуском.


---

# Практическая работа №4 — Client-Side Prediction и Server Reconciliation (в игре на Godot 4)

Схема: «клиент шлёт **ввод**, сервер проверяет и решает, клиент предсказывает и сверяется». Преподаватель разрешил делать работу
не на Unreal Engine, поэтому всё реализовано **в игре bob_arena на Godot 4** (`godot/`, собственный UDP-протокол из ПР №1–3, Listen Server):
рывок с кулдауном и выносливостью, серверные проверки, предсказание клиента, сверка с повтором неподтверждённых команд, режим «без предсказания»,
эмуляция сети, чит для намеренного расхождения, сценарии T1–T5, графики, видео, скриншоты и **визуализация предсказания** (F8, меню настроек).
Подробности — `docs/Prediction_Implementation.md`, матрица — `docs/Prediction_Test_Matrix.md`, артефакты — `docs/game_runs/` и `docs/media/`.

Первая версия ПР №4 (отдельный прототип на ENet) сохранена тегом `pr4-submitted`; вариант на Unreal Engine (код не компилировался) вынесен из
репозитория в ветку `feature/prediction-unreal`.

## Что сделано

- **Серверный авторитет.** Клиент отправляет `{seq, ось, кнопки}`; сервер сам считает шаг (`PlatSim`) и проверяет рывок (`already_dashing`, `stunned`,
  `attacking`, `cooldown`, `no_stamina`), отбрасывает недопустимые команды, дубликаты и команды «из будущего».
- **Предсказание рывка вкл/выкл** (настройка, клавиша **F4**, `--predict=0|1`): без предсказания рывок на экране появляется только после ответа сервера.
- **Сверка** (`GameClient._reconcile`): `history[ack]` против состояния сервера; при расхождении — серверное состояние + повтор `pending`.
- **Замеры**: «нажатие → рывок на экране» и «нажатие → подтверждение сервера», принято/отклонено; строки в `net_graph` (F3), сообщения в ленте, логи.
- **Чит клиента** (`GameClient.cheat_no_rules`; вручную — запуск с `--debug`, F10) для намеренного расхождения.
- **Визуализация предсказания** (настройки в меню/паузе, **F8**, `--viz=0..3`): призрак сервера, предсказанный персонаж полупрозрачный, путь неподтверждённых
  команд, красное кольцо при коррекции. Только отрисовка, состояние симуляции не меняется.
- **Спрайты** персонажей и биты (пиксель-арт, `godot/assets/sprites/characters.png`: 4 цвета игры + бита). Переключатель «Модели персонажей» в меню и паузе, **F6**,
  `--sprites=0|1`; без файла или при выключенных спрайтах игра рисует прежние фигуры. «Призрак» сервера повторяет форму спрайта.
- **Сценарии T1–T5** по реальному UDP (два процесса, клиентом управляет `ScenarioBrain`) и запись видео/скриншотов в режиме виртуального времени.

## Требования и запуск (Windows 11, PowerShell 7)

Godot 4.7.2 (консольная версия, например `Godot_v4.7.2-stable_win64_console.exe`). Игра: `.\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Menu`.

```powershell
$g = "C:\Godot\Godot_v4.7.2-stable_win64_console.exe"
.\run_godot_demo.ps1 -Godot $g -Role Tests                                  # все автотесты Godot (без окна)
.\run_godot_demo.ps1 -Godot $g -Role Scenarios                              # T1–T5 по реальному UDP, логи в docs\game_runs
python tools\game_report.py                                                  # сводка + графики docs\media\*.png
.\run_godot_demo.ps1 -Godot $g -Role Scenario -Case T3 -Viz 3               # один сценарий с окнами (запись экрана)
.\run_godot_demo.ps1 -Godot $g -Role Both -Profile lag100 -Predict 0 -Viz 3 # вручную: хост + клиент, без предсказания, 100 мс
.\run_godot_demo.ps1 -Godot $g -Role Both -Profile lag175loss4 -DebugKeys   # вручную: 175±25 мс, 4% потерь, чит F10
```

Профили сети (меню «Сеть»/`-Profile`): `none`, `lag100` (100 мс), `lag175loss4` (175±25 мс, 4% потерь) — задержка «в одну сторону» на исходящем
трафике каждой стороны. **Клавиши в игре:** A/D — бег, Space — прыжок, Shift — рывок, **F4** — предсказание рывка, **F8** — режим визуализации, **F6** — спрайты/фигуры,
**F3** — net_graph, H — здоровье, Esc — пауза; с `--debug`: F9 — локальный телепорт, F10 — рывок без кулдауна (чит), F11 — смена профиля сети.

**Минимальный сценарий демонстрации:** запустить хост и клиент → показать ходьбу и рывок при задержке (F4: без предсказания и с ним, режим F8 = «Полная») →
показать, что сервер видит подтверждённое состояние (оранжевый призрак) → включить чит (F10) и рывок до конца кулдауна → увидеть «Рывок ОТКЛОНЁН сервером»,
красное кольцо коррекции и возврат клиента к серверному положению без разрыва соединения.

## Результаты (реальный UDP, 5 рывков на сценарий; подробно — `docs/Prediction_Test_Matrix.md`)

| Тест | Сеть | Предсказание | Рывок на экране | Коррекций | Принято/отклонено |
|---|---|---|---|---|---|
| T1 | нет | вкл | 0 мс | 0 | 2/0 |
| T2 | 100 мс | **выкл** | **≈ 258 мс** | 5 (до 136 px) | 5/0 |
| T3 | 100 мс | вкл | **0 мс** (подтверждение ≈ 270 мс) | 0 | 5/0 |
| T4 | 175±25 мс, 4% | вкл | 0 мс | 0 | 5/1 |
| T5 | 175±25 мс, 4% + чит | вкл | 0 мс | 5–7 (50–150 px) | 5/3 |

## Тесты

```powershell
# C++ (ПР №2–3 и пакеты игры): ожидается "78 тестов, 0 провалено"
g++ -std=c++17 protocol/protocol.cpp telemetry/telemetry.cpp reliability/adaptive_timeout.cpp reliability/reliable_channel.cpp reliability/dedup_window.cpp tests/test_protocol.cpp tests/test_telemetry.cpp tests/test_reliable_protocol.cpp tests/test_adaptive_timeout.cpp tests/test_reliable_channel.cpp tests/test_game_packets.cpp tests/test_main.cpp -o telemetry_tests.exe
.\telemetry_tests.exe

# Godot (все наборы): net 20, game 26, game_net 13, pred 10 (ПР №4), view 5 (спрайты), app 4, udp 2
.\run_godot_demo.ps1 -Godot $g -Role Tests                                  # либо: GODOT=<путь> ./tools/godot_check.sh
```

`run_pred_tests.gd` (ПР №4): предсказание вкл/выкл и переключение на лету, замеры отклика, чит и серверный отказ, путь предсказания для визуализации,
режимы визуализации, сценарии T2/T3/T4/T5 в виртуальном времени (детерминированно). `run_app_tests.gd`: F4/F8, меню и пауза, строки net_graph.

## Git-workflow (ветка/PR)

Работа в ветке `feature/game-prediction` (от `feature/game-polish`). Порядок сдачи — после слияния PR №3 в `main`:

```powershell
git fetch origin
git switch main; git merge --ff-only origin/main
# 1) PR feature/reliable-delivery -> main (если ещё не слит), затем при необходимости rebase ветки ПР №4 на main
git switch feature/game-prediction
git rebase main
git push --force-with-lease -u origin feature/game-prediction
# 2) открыть Pull Request в main
```

## Известные ограничения

- Это не `CharacterMovementComponent`: предсказание и сверка написаны вручную — в Godot такого механизма нет.
- Эмуляция сети встроена в приложение (исходящий трафик каждой стороны), на localhost; результаты по реальному UDP слегка зависят от загрузки машины.
- Видео и скриншоты записаны в режиме виртуального времени (логика та же, что по UDP); запись с настоящим UDP между двумя окнами — `-Role Scenario` + OBS.
- Принятие рывка клиент определяет по таймеру перезарядки в авторитетном состоянии: формат протокола ПР №2–3 не менялся, отдельного пакета «рывок отклонён» нет.
- Открывайте в редакторе Godot папку `godot/`, а не корень репозитория (иначе появятся `project.godot`, `icon.svg` и `*.import` в корне и `docs/`).

# Доработка игры на Godot (ветка `feature/game-polish`)

Цель: 2D-платформер для 2–4 игроков на **вашем** протоколе (вместо ENet), с минимальным инпутлагом, разноцветными
моделями игроков, рунами и аурами, переключаемыми HP и net_graph, меню и экранами победы/поражения. План — в начале
работы согласован; первая версия ПР №4 (прототип на ENet) зафиксирована тегом `pr4-submitted` (воспроизводится через `git checkout pr4-submitted`); теперь ПР №4 реализована в самой игре — см. раздел выше.

## Этап M1 — протокол и транспорт (готово)

- C++: игровые типы пакетов 6–11 (Hello, Welcome, Input, Snapshot, GameEvent, Leave) в `protocol/`; 14 новых тестов
  (всего 78). Заголовок и версия формата не менялись, ПР №2–3 работают как раньше.
- GDScript: порт протокола и транспорта в `godot/scripts/net/` (`NetNode` — ACK, повторы по адаптивному RTO, дедупликация,
  Ping/Pong, обрыв, статистика для будущего net_graph; `UdpLink` — реальный UDP; `LoopLink` — память для тестов).
- Совместимость доказана: байты пакетов и поведение AdaptiveTimeout/DedupWindow/ReliableChannel сверяются с C++ по
  `godot/tests/golden_vectors.json` (на этой сверке нашёлся и был исправлен размер payload Welcome); порт на реальном UDP
  обменивается Ping/Pong с вашим `pong_server_app`.
- Спецификация: `docs/Protocol_Specification.md`, раздел «игровые пакеты».

Проверка (из корня репозитория, Godot 4.4+):

```powershell
godot --headless --path godot --import                                  # один раз
godot --headless --path godot -s res://tests/run_net_tests.gd           # 20 тестов протокола/транспорта
godot --headless --path godot -s res://tests/run_pred_tests.gd         # 10 тестов ПР №4 (предсказание, чит, визуализация, сценарии)
```

Совместимость с C++ на реальных сокетах (bash): `GODOT=<путь> ./tools/net_interop.sh`.
Дальше: M2 — платформерная симуляция, бой, руны; M3 — модели, ауры, интерфейс, net_graph, экраны.

## Этап M2 — платформерная симуляция, бой, руны, сервер и клиент (готово)

Играется поверх вашего протокола (ENet в новых модулях не используется): `godot/scripts/game/`.

| Файл | Роль |
|---|---|
| `gc.gd` | константы игры (единицы: 1 px = 256 u, 120 тиков/с), карта, руны, фазы, виды событий |
| `pstate.gd` | полное состояние игрока (целые числа), сериализация в `ownerState`, побайтовое сравнение |
| `plat_sim.gd` | детерминированный шаг: бег, прыжок (переменная высота, coyote 83 мс, буфер 100 мс), спрыгивание вниз, рывок, атаки |
| `combat.gd` | только сервер: попадания, урон, отталкивание, оглушение, вампиризм, дебаффы, подбор рун |
| `game_host.gd` | сервер-авторитет: недоверенный ввод, фазы лобби → отсчёт → игра → итоги, руны, снимки 60 Гц, события |
| `game_client.gd` | предсказание своего персонажа, история, сверка (reconciliation) с повтором команд, статистика для net_graph |
| `remote_view.gd` | интерполяция чужих игроков по серверным тикам (+ ограниченная экстраполяция) |

**Арена:** три платформы (центральная и две боковые, выше центральной), все проходимы снизу и «спрыгиваемы» (DOWN + прыжок),
под ареной пустота: падение = смерть. 2–4 игрока, раунд до последнего выжившего.

**Управление (команда за тик):** ось −127..127, кнопки: прыжок, рывок, лёгкий удар (ЛКМ, срабатывает сразу, 8 урона),
тяжёлый удар (ПКМ, замах 150 мс, 22 урона), вниз. Рывок — действие ПР №4: кулдаун 1.2 с и выносливость, проверки на сервере.

**Руны** (каждые 10 с на платформе, эффект 15 с, одновременно не более трёх; вытесняется самая короткая): скорость +30%,
высота прыжка, урон +30%, отталкивание +30%, вампиризм (30% урона), броня −30% урона, устойчивость −30% отталкивания,
замедление врага при ударе, инверсия управления врага при ударе (дебаффы по 4 с), здоровье (+30, не берётся при полном HP),
«случайность» (30 с, влияет на отображение у подобравшего; визуал в M3). Не вошли в первую версию: кражи характеристик,
замедление скорости атаки, щит и падающее оружие.

**Как сервер защищается** (всё покрыто тестами): ось и кнопки санитизируются, команды из далёкого будущего отбрасываются,
сервер сам решает попадания, рывок, подбор рун и смерть; клиентская подмена позиции или кулдауна просто исправляется
коррекцией (`t_teleport`, `t_dash_cheat`).

Проверка (из корня, Godot 4.4+):

```powershell
godot --headless --path godot -s res://tests/run_game_tests.gd       # 26: движение, рывок, бой, руны, детерминизм
godot --headless --path godot -s res://tests/run_game_net_tests.gd   # 13: хост+клиенты по протоколу, потери до 30%, обрыв
godot --headless --path godot -s res://tests/run_net_tests.gd        # протокол и транспорт
```

Следующий этап (M3: интерфейс, визуал, net_graph, инпутлаг) выполнен — см. ниже.

## Этап M3 — игра целиком: модели, ауры, меню, net_graph, инпутлаг (готово)

Запуск (PowerShell 7, из корня; Godot 4.4+, проверено на 4.7.2; используйте `*_console.exe`, чтобы видеть вывод):

```powershell
.\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Bot                         # хост + бот-тренер, одному
.\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Both -Profile lag175loss4   # хост и клиент, два окна, плохая сеть
.\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Host                        # по сети: друзья вводят ваш IP:порт
.\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Join -Ip 192.168.1.5
.\run_godot_demo.ps1 -Godot "C:\Godot\Godot_v4.7.2-stable_win64_console.exe" -Role Tests                       # все автотесты Godot (без окна)
```

Либо просто откройте папку `godot` в редакторе Godot и нажмите F5 — запустится меню. Скрипт при каждом запуске сам обновляет кэш Godot (`--import`): если после обновления игры в `godot\.godot` остался кэш старой версии, без этого будет серый экран и ошибки `Could not find type "GameUI"`. Если запускаете Godot вручную — откройте папку `godot` в редакторе один раз (он перестроит кэш) или выполните `godot --headless --path godot --import`.
Параметры после `--`: `--debug` (читы F9–F11 для демонстрации сервера), `--preset=0|1|2` (эмуляция сети), `--host`, `--join=<ip>`, `--port=`, `--name=`, `--bot`.

**Управление** (физические клавиши — русская раскладка не мешает):

| Действие | Клавиши |
|---|---|
| Бег | A / D или ← / → |
| Прыжок (держите — выше) | W, ↑ или Пробел |
| Спрыгнуть вниз с платформы | S (удерживать) + прыжок |
| Рывок (кулдаун 1.2 с, выносливость) | Shift или K |
| Лёгкий / тяжёлый удар | ЛКМ или J / ПКМ или L |
| Показать/скрыть здоровье (своё и соперников) | **H** |
| Показать/скрыть net_graph | **F3** |
| Пауза / продолжить (мир не останавливается) | Esc |
| Читы для демонстрации (только с `--debug`) | F9 телепорт себя, F10 рывок без кулдауна, F11 профиль сети |

**Экраны:** главное меню (имя, цвет, хост, подключение по IP, тренировка с ботом, эмуляция сети и режим VSync, выход) → лобби (список игроков, «Старт» у хоста) →
отсчёт 3-2-1 → матч (HUD: пинг, таймер, активные руны с таймерами, лента событий) → **ПОБЕДА / ПОРАЖЕНИЕ / НИЧЬЯ** со статистикой (убийства, урон, время) и кнопками «Реванш» / «В меню»;
отдельно экран «Соединение потеряно» (нет пакетов 3 секунды, хост закрыл игру, хост не отвечает) и пауза. Снимки всех экранов: `docs/game_shots/`.

**Визуал (всё рисуется кодом, ассетов нет):** разноцветные модели игроков (4 цвета), анимация бега, растяжение и сжатие при прыжке/приземлении, вспышка при попадании, взмах «палки»,
силуэты рывка, звёздочки оглушения, имя и полоска HP над головой. У каждой руны свой значок и **своя аура вокруг персонажа**: скорость — полосы-следы, прыжок — расходящиеся кольца и поднимающиеся частицы,
урон — языки пламени, отталкивание — ударные кольца, вампиризм — капли, летящие к игроку, броня — вращающийся шестиугольный щит, устойчивость — камни вокруг ног, заморозка — снежинки, инверсия — вращающиеся стрелки,
«случайность» — парящие «?» (и у подобравшего руны на карте скрыты знаками «?»). Ауры складываются, вокруг своего персонажа дуги показывают остаток времени каждой руны; дебаффы на жертве (заморозка, инверсия) видны отдельно.
Подбор руны — всплеск частиц цвета руны (у здоровья — плюсы), смерть — взрыв.

**net_graph (F3)** — всё, что влияет на игру: RTT (сейчас, сглаженный и RTO, мин/сред/макс, джиттер); потери (пинги без ответа и входящие по разрывам номеров); трафик (пакеты и КБ/с);
надёжные пакеты (очередь, повторы, провалы, время до ACK, дубликаты); снимки сервера (частота, интервал ± джиттер, возраст, пропуски, задержка интерполяции, экстраполяции из-за нехватки данных);
предсказание (неподтверждённые команды в мс, коррекции в секунду и всего, размер ошибки); ввод и кадр (нажатие → тик, нажатие → кадр, FPS, тиков за кадр); эмуляция. Мини-графики за 10 секунд: RTT, потери, ошибка коррекции, интервал снимков.
Цвета: зелёный — норма, жёлтый — заметно, красный — плохо. У хоста — то же по каждому клиенту плюс серверные счётчики (заполненные дыры в командах, отброшенные команды, отклонённые рывки).

**Инпутлаг — что сделано:** ввод по событиям с «защёлкой» (короткий тап не теряется, `Input.use_accumulated_input = false`); события применяются в том же кадре (приём сети и тики идут в `_process` сразу после ввода, без ожидания отдельного физического шага);
свой персонаж рисуется из предсказанного состояния без интерполяции, удар и рывок стартуют в тот же тик; симуляция 120 Гц, пакеты Input 60 раз в секунду с избыточностью 10 команд; чужие игроки — интерполяция с задержкой 8 тиков (≈67 мс), снимки 60 Гц;
выбор режима VSync в меню (по умолчанию Mailbox; «Выкл» — минимум задержки, возможны разрывы). Измеритель в net_graph показывает программную часть цепочки «событие → тик → кадр».
Замер на сервере сборки (виртуальный дисплей, программная отрисовка, 15 FPS): «событие → тик» ≈ 1.0–1.1 мс (среднее), максимум < 2 мс, то есть приложение не добавляет ожидания сверх одного кадра; «событие → кадр» ≈ 40 мс — это время кадра при 15 FPS, на обычной видеокарте оно равно времени кадра (≈ 7–17 мс).
Задержку ОС, монитора и драйвера программно не измерить; на вашей машине смотрите строки «Нажатие → тик/кадр» в net_graph.

**Проверка этапа** (Linux, Godot 4.7.2): `run_net_tests` 20, `run_game_tests` 26, `run_game_net_tests` 13, `run_app_tests` 3 (меню → бот → матч → победа → реванш; два приложения по реальному UDP; переключатели H/F3/Esc), `run_udp_tests` 2 + совместимость с C++ `pong_server_app`;
C++ — 93 теста. Всё одной командой: `GODOT=<путь> ./tools/godot_check.sh` или `.\run_godot_demo.ps1 -Godot <путь> -Role Tests`. Скриншоты: `GODOT=<путь> ./tools/godot_shots.sh`.

**Ограничения и честные оговорки:** запуск на Windows 11 с PowerShell и игра по интернету/NAT не проверялись (для игры через интернет нужен проброс порта UDP или VPN вроде ZeroTier);
проверка внешнего вида — по скриншотам с виртуального дисплея, на живой машине могут понадобиться правки размеров; звука нет; щит и падающее оружие из `mechanics.md`, кражи характеристик и замедление скорости атаки не реализованы; компенсация задержки для попаданий не делалась;
боты-тренеры простые (бегут к цели, бьют в упор, не падают с края).



---

# Практическая работа №5 — оптимизация репликации (в игре на Godot 4)

Условие (PDF «Оптимизация репликации в Unreal Engine»): нагруженная сцена с ≥ 50 реплицируемыми акторами → профиль трафика «до» → минимум две
оптимизации (Replication Graph, Net Dormancy, Push-Based, квантование, частоты) → профиль «после» в тех же условиях → отчёты. С преподавателем договорились
делать **не на Unreal Engine, а в Godot** (как ПР №4): механизмов UE в Godot нет, поэтому они написаны с нуля поверх собственного UDP-протокола ПР №1–3
(`NetNode`, надёжный канал, Listen Server) с теми же названиями настроек (`NetUpdateFrequency`, `NetPriority`, `NetCullDistance`, dormancy, `IsNetRelevantFor`).
Отчёты — `docs/Replication_Baseline.md` и `docs/Replication_Optimization.md`, данные профиля — `docs/repl/*.json`, графики — `docs/media/repl_*.png`.

## Как условие разбито на подзадачи

| № | Требование PDF | Что сделано | Где и чем проверено |
|---|---|---|---|
| 1 | Сцена с ≥ 50 реплицируемыми акторами, репликация всех всем без ограничений | Мир-нагрузка `ReplWorld`: 40 деревьев, 12 предметов, 8 ботов, 8 облаков = **68 акторов** на старте + аватары клиентов + снаряды; «длинный уровень» 16000 px | `t_world`, `t_baseline`; режим baseline = всё всем, полным состоянием |
| 2 | Базовый профиль: исходящий трафик, частота обновлений, «тяжёлые» акторы → `docs/Replication_Baseline.md` | `ReplProfiler` (аналог `netprofile enable`/Network Profiler): КБ/с, пакеты/с, записи/с, разбивка по классам и по акторам, пик за 100 мс | `docs/Replication_Baseline.md`, `t_profiler` (сверка с реальными байтами канала) |
| 3 | ≥ 2 оптимизации | Реализованы **все семь**: Replication Graph (сетка), Net Dormancy, Push-based, квантование, NetUpdateFrequency по классам, + доп. задания `IsNetRelevantFor` (направление, гистерезис) и `NetPriority` с бюджетом | `t_relevancy`, `t_custom_relevance`, `t_dormancy`, `t_push`, `t_freq`, `t_priority` |
| 4 | Повторный профиль в идентичных условиях | Один сценарий (seed 7, 3 клиента, 30 с, одинаковые скриптовые команды); мир от репликации не зависит, контрольная сумма совпадает | `t_same_world`, `run_repl_profile.gd` |
| 5 | `docs/Replication_Optimization.md`: таблица «до/после», число акторов, техники, почему сработали для жанра | Таблицы, вклад каждой техники отдельно и накопительно, NetPriority под нагрузкой, качество картинки, оговорки | `docs/Replication_Optimization.md` (строится `tools/repl_report.py`) |

## Что добавлено (структура)

```
godot/scripts/repl/
├── repl_defs.gd       — константы мира, классы акторов, NetUpdateFrequency/NetPriority/NetCullDistance, квантование
├── repl_actor.gd      — актор; set_* помечают поля «грязными» (push-модель)
├── repl_world.gd      — сервер-авторитетный мир: уровень, боты, снаряды, предметы, облака, аватары
├── repl_grid.gd       — Grid Spatialization (ячейки 500 px)
├── repl_cfg.gd        — набор включённых оптимизаций (все выкл = «до»), пресеты baseline/optimized
├── repl_codec.gd      — пакеты WorldUpdate (13) и WorldReliable (14), разбор со строгой проверкой
├── repl_server.gd     — репликатор Listen Server: релевантность, сон, push, частоты, приоритеты, бюджет
├── repl_client.gd     — клиент: применение пакетов, «надгробия», tick-контроль, экстраполяция позиций
├── repl_profiler.gd   — профилировщик трафика (аналог netprofile)
├── repl_scenario.gd   — воспроизводимый сценарий «до/после» на виртуальном времени
└── repl_lab.gd        — режим игры «Лаборатория репликации» (мир, 3 клиента, рисование, замер)
godot/scripts/game_ui.gd, app.gd  — встроено в игру: строка «Репликация (ПР №5)» в меню, экран лаборатории с настройками, окно результатов замера
godot/tests/run_repl_tests.gd     — 23 теста;  godot/tests/run_repl_profile.gd — профиль 15 конфигураций → docs/repl/*.json
tools/repl_report.py              — отчёты docs/Replication_*.md и графики из JSON
```
**ПР №5 встроена в саму игру** (не отдельная программа): в `GameUI` добавлены строка меню и экран «Лаборатория репликации» с настройками, в `App` — открытие/закрытие режима и передача настроек; остальной код игры не менялся. В существующий код внесены малые добавки: `Wire.w_f32`/`Reader.f32` (float32 big-endian), типы 13–14 в `Proto` (заголовок и версия протокола не менялись),
накопительные счётчики байт в `NetNode.Peer`. Игра ПР №4 и её тесты не затронуты.

## Как это работает

- **Сцена-нагрузка — длинный уровень, а не арена.** Арена ПР №4 помещается в один экран 1280 px, и релевантность там бессмысленна; поэтому нагрузка — боковой уровень
  16000 px, где камера видит 8% мира. Вторая часть выбора — реалистичное соотношение: ≈ 75% акторов (деревья, предметы) статичны.
- **Baseline («до»)**: каждому клиенту — все акторы; на каждом сетевом тике (30 Гц) полное состояние каждого актора, 21 Б на запись (`float32`), без дельт и приоритетов.
- **Replication Graph**: сетка 500 px; сервер на тике смотрит только ячейки рядом с аватаром и проверяет `IsNetRelevantFor`; вошедший актор приходит `UPSERT`, вышедший — `DESTROY` (надёжный канал).
- **Net Dormancy**: деревья и предметы после появления молчат; изменение (попадание, подбор) «будит» актора одним надёжным пакетом с полным состоянием.
- **Push-based**: поля меняются только через `set_*`, которые помечают маску; на клиента копится маска, в пакет идут только изменённые поля; раз в секунду — ключевое состояние (лечит потерю ненадёжных дельт).
- **Квантование**: позиция `u16` с шагом 0,25 px, скорость `i8` с шагом 8 px/с; клиент экстраполирует по скорости.
- **Частоты и приоритеты**: деревья 2 Гц, облака и предметы 5 Гц, игровое 30 Гц; обновления разнесены по тикам; при нехватке бюджета очередь — по `приоритет × время с последней отправки`.
- Формат пакетов — `docs/Protocol_Specification.md`, приложение «ПР №5».

## Результат (профиль 30 с, 3 клиента, идентичный сценарий; подробно — `docs/Replication_Optimization.md`)

| Показатель | До | После |
|---|---|---|
| Исходящий трафик сервера, всего | 142.3 КБ/с | **6.2 КБ/с (−95.6%)** |
| На одного клиента | 47.4 КБ/с | 2.1 КБ/с |
| Акторов, реплицируемых клиенту (из 72) | 72.9 | 12.1 |
| Обновлений акторов в секунду на клиента | 2189 | 151 |
| Средний размер записи | 21.1 Б | 6.1 Б |
| Видимых акторов, пропавших у клиента | 0 | 0 |
| Средняя ошибка позиции видимых | 1.01 px | 1.04 px |

Каждая техника отдельно (КБ/с, baseline 142.3): релевантность 27.2, Dormancy 43.1, Push 20.3,
квантование 74.8, частоты 39.1. NetPriority при насыщении канала (бюджет 600 Б/тик): ошибка ботов 78.5 → 1.5 px,
снарядов 54.9 → 5.3 px при том же трафике.
Снижение выше ориентира 40–60% из условия — потому что на длинном уровне клиент видит ≈ 8% акторов; границы вывода — в разделе 6 `docs/Replication_Optimization.md`.

## Настройки репликации в игре (как преподавателю всё увидеть и проверить)

Запуск игры как обычно (`.\run_godot_demo.ps1 -Godot $g -Role Menu`) → в главном меню, под «Моделями персонажей», строка **«Репликация (ПР №5)»**: выбор стартового набора
(«после» — все оптимизации, «до» — наивная) и кнопка **«Лаборатория репликации»**. Сразу на этот экран игра открывается и командой `-Role Lab [-Repl baseline]`.

**Экран лаборатории** (Listen Server и 3 клиента в одном окне; вы — клиент 0, остальные ходят по сценарию):

| Элемент | Что делает |
|---|---|
| Панель «Настройки репликации (ПР №5)» справа | **Набор**: «До» (всё выключено), «После» (все семь), «Свой набор»; **7 переключателей**: Replication Graph, IsNetRelevantFor, Net Dormancy, Push-based, квантование, NetUpdateFrequency, NetPriority — применяются на лету |
| «Показывать»: панель статистики / мини-карта / серые контуры | оверлеи: серые контуры — акторы, которые есть на сервере, но клиенту не реплицируются; яркие точки мини-карты — реплицируются |
| «Сеть» | профиль эмуляции из настроек игры (без эмуляции / 100 мс / 175±25 мс и 4% потерь) — видно, как репликация держится при задержке и потерях |
| Панель слева | исходящий трафик сервера (КБ/с всего и на клиента), сколько акторов из скольких реплицируется клиенту 0, ошибка вида, график за 40 с |
| **«Замер «до/после»»** | за ≈ 10–15 с прогоняет тот же воспроизводимый сценарий (10 с игры, seed 7, 3 клиента) для «до», «после», **вашего текущего набора** и каждой из пяти техник отдельно; таблица КБ/с, снижение, акторов у клиента, ошибка вида и подтверждение, что контрольная сумма мира совпала |
| Клавиши | A/D — идти, Пробел — выстрел, 1–7 — техники, B/O — «до»/«после», H/M/G — оверлеи, Esc — в меню |

Полный профиль на 30 с и отчёты — отдельной командой без окна. Все команды (Windows 11, PowerShell 7; Godot 4.7.2 консольная; Python 3 с matplotlib нужен только для отчётов и графиков):

```powershell
$g = "C:\Godot\Godot_v4.7.2-stable_win64_console.exe"
.\run_godot_demo.ps1 -Godot $g -Role Menu                   # игра: Меню → «Лаборатория репликации»
.\run_godot_demo.ps1 -Godot $g -Role Lab -Repl baseline   # сразу лаборатория, старт «до»
.\run_godot_demo.ps1 -Godot $g -Role ReplProfile            # профиль 15 конфигураций без окна → docs\repl\*.json и отчёты docs\Replication_*.md (нужен python)
python tools\repl_report.py                                  # только пересобрать отчёты и графики из docs\repl\*.json
.\run_godot_demo.ps1 -Godot $g -Role Tests                  # все автотесты Godot, включая run_repl_tests
```
Кириллица в PowerShell: `run_godot_demo.ps1` сохранён в UTF-8 **с BOM** и переключает консоль на UTF-8 (`[Console]::OutputEncoding`), `repl_report.py` пишет файлы в UTF-8 и
переключает вывод; если правите скрипт в Zed — оставьте кодировку UTF-8 with BOM для `.ps1`.

**Минимальный сценарий показа преподавателю:** Меню → «Лаборатория репликации» (старт «до»: ≈ 143 КБ/с, клиенту известны все 74 актора) → пройти вправо клавишей D → нажать **«После»** в панели справа или клавишу **O**
(трафик падает до ≈ 6 КБ/с, на мини-карте яркими остаются только акторы рядом, картинка не меняется) → выключать техники по одной и смотреть, как растёт трафик → переключить «Сеть» на «175±25 мс, 4% потерь»
(мир остаётся согласованным) → **«Замер «до/после»»**: таблица с вкладом каждой техники → показать `docs/Replication_Optimization.md`.
Скриншоты: `docs/media/repl_menu.png`, `repl_lab_baseline.png`, `repl_lab_optimized.png`, `repl_lab_measure.png`.

## Тесты

```powershell
.\run_godot_demo.ps1 -Godot $g -Role Tests      # либо: GODOT=<путь> ./tools/godot_check.sh
# ожидается: net 20, game 26, game_net 13, pred 10, view 5, app 4, udp 2, repl 23 — всё «0 провалено»
```
`run_repl_tests.gd` (23 теста): квантование и границы ошибки, размеры записей, кодек туда-обратно и отказ на мусоре, сетка, мир (≥ 50 акторов, детерминизм), push-пометки, baseline, релевантность
(видимое не пропадает при ходьбе), направление и гистерезис, сон и надёжное «пробуждение» при 30% потерь, push и ключевые кадры, частоты и разнесение, приоритет при нехватке бюджета,
потери 15% и задержка, опоздавшие и переставленные пакеты, переключение оптимизаций на лету, идентичность мира «до/после», снижение ≥ 60% и эффект каждой техники,
согласие профилировщика с реальным трафиком, **реальный UDP на localhost**, лаборатория (переключатели, наборы, профиль сети) и **лаборатория внутри игры** (меню → кнопка → переключатели настроек → замер → выход).

## Git-workflow (ветка/PR)

```powershell
git switch feature/game-polish        # ПР №5 — поверх игры ПР №4
git switch -c feature/replication-optimization
git add godot/scripts/repl godot/scripts/app.gd godot/scripts/game_ui.gd godot/tests/run_repl_tests.gd* godot/tests/run_repl_profile.gd* godot/scripts/net tools/repl_report.py docs/Replication_Baseline.md docs/Replication_Optimization.md docs/repl docs/media/repl_*.png docs/Protocol_Specification.md run_godot_demo.ps1 tools/godot_check.sh README.md
git commit -m "ПР №5: оптимизация репликации (Replication Graph, Net Dormancy, Push, квантование, частоты, приоритеты) на Godot"
git push -u origin feature/replication-optimization   # затем Pull Request в main
```

## Известные ограничения и оговорки

- Это не Unreal Engine: Replication Graph, dormancy, push model и NetQuantize воспроизведены по смыслу, а не API-совместимо; числа КБ/с — для этой сцены и этого протокола, к UE переносить нельзя.
- Профиль идёт на виртуальном времени (`LoopHub`) без потерь, чтобы числа воспроизводились до байта; потери, задержку и перестановку пакетов проверяют тесты, а один тест — на реальном UDP.
  Профиль по двум окнам/машинам и по интернету не снимался.
- Время сетевого тика (мкс) меряется реальными часами и ориентировочное; остальные метрики детерминированы.
- Лаборатория — режим игры на одной машине (сервер и три клиента в процессе, на виртуальных каналах с эмуляцией сети из настроек игры, без сокетов); игровая арена ПР №4 репликацию мира не использует, т. к. помещается в один экран, поэтому настройки ПР №5 относятся к лаборатории, а не к матчу.
- Не сделано: сжатие `id` до одного байта на клиента, объединение мелких пакетов, сборка с учётом MTU по факту (сейчас лимит 1100 Б полезной нагрузки), компенсация задержки.

## Баги и нюансы, найденные в процессе разработки ПР №5

1. **Разнесение по тикам терялось.** Фаза `id % период`, заданная при создании записи об акторе, перезаписывалась при отправке `UPSERT`, и все 40 деревьев уходили одним всплеском на каждом периоде. Тест `t_freq` ловит это (максимум записей за тик).
2. **Порядок надёжных пакетов.** Первая версия различала `spawn` и `state`; при потере `spawn` пришедшее раньше `state` игнорировалось, а повторный старый `spawn` затирал бы актора устаревшим состоянием навсегда (у спящих нет ключевых кадров).
   Теперь один `UPSERT` с полным состоянием и `tick`, плюс «надгробия» удалённых id — тесты `t_dormancy` (30% потерь) и `t_reorder`.
3. **Ложные «пропажи» в метрике.** Снаряд, созданный в этот же тик, доезжает до клиента за 1–2 сетевых тика; без поправки на `born_tick` метрика «видимых акторов нет у клиента» показывала ~0,7% и в baseline.
4. **Ошибка внутри тестовой функции не считалась провалом** (скриптовая ошибка прерывает функцию, а счётчик `failed` не растёт). Поэтому вывод тестов при разработке проверялся ещё и на `SCRIPT ERROR` (`... | grep -E "ERROR|FAIL|тестов"`).
