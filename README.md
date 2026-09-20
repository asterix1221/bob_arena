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
