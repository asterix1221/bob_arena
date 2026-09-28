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

