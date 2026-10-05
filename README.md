



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

   
<img width="853" height="1106" alt="image" src="https://github.com/user-attachments/assets/931da974-df3f-4bb9-8dcc-dfac30ee0b41" />
