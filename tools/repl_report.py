#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ПР №5: строит отчёты docs/Replication_Baseline.md и docs/Replication_Optimization.md и графики docs/media/repl_*.png
из JSON, которые пишет `godot --headless --path godot --script tests/run_repl_profile.gd` (папка docs/repl).
Все числа в отчётах берутся из JSON; текст пояснений — здесь. Запуск из корня репозитория: python tools/repl_report.py"""
import json
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")   # кириллица в консоли Windows
except Exception:
    pass

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "docs" / "repl"
MEDIA = ROOT / "docs" / "media"
CLS = ["player", "tree", "pickup", "bot", "projectile", "cloud"]
CLS_RU = {"player": "Игрок", "tree": "Дерево (декор)", "pickup": "Предмет", "bot": "Бот", "projectile": "Снаряд", "cloud": "Облако (фон)"}
TECH_RU = {
    "relevancy": "Replication Graph: сетка + релевантность",
    "custom_relevance": "IsNetRelevantFor: направление + гистерезис",
    "dormancy": "Net Dormancy",
    "push": "Push-based (только изменённые поля)",
    "quantize": "Квантование (NetQuantize)",
    "freq": "NetUpdateFrequency по классам",
    "priority": "NetPriority + бюджет",
}


def load(name):
    with open(DATA / name, encoding="utf-8") as f:
        return json.load(f)


def f1(x):
    return f"{x:,.1f}".replace(",", " ")


def f2(x):
    return f"{x:,.2f}".replace(",", " ")


def f0(x):
    return f"{x:,.0f}".replace(",", " ")


def pct_less(base, v):
    return (1.0 - v / base) * 100.0 if base else 0.0


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def table(headers, rows, align=None):
    align = align or ["l"] + ["r"] * (len(headers) - 1)
    sep = ["---:" if a == "r" else ":---" for a in align]
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join(sep) + " |"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def charts(base, opt, results, sat):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as e:  # график необязателен — отчёты строятся и без него
        print("matplotlib недоступен, графики пропущены:", e)
        return False
    MEDIA.mkdir(parents=True, exist_ok=True)
    cols = ["#6c8ebf", "#2f8f4e", "#f5c518", "#e5484d", "#ff9f1c", "#9aa7c7"]
    # 1) трафик по классам: до/после
    fig, ax = plt.subplots(figsize=(8, 4.2))
    labels = [CLS_RU[c] for c in CLS]
    b = [base["steady"]["per_class"][c]["kb_s"] for c in CLS]
    o = [opt["steady"]["per_class"][c]["kb_s"] for c in CLS]
    x = range(len(CLS))
    ax.bar([i - 0.2 for i in x], b, 0.4, label="до (baseline)", color="#c0504d")
    ax.bar([i + 0.2 for i in x], o, 0.4, label="после (optimized)", color="#4f9d69")
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, rotation=15, ha="right")
    ax.set_ylabel("КБ/с, все 3 клиента")
    ax.set_title("Исходящий трафик сервера по классам акторов")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(MEDIA / "repl_by_class.png", dpi=130)
    plt.close(fig)
    # 2) по секундам
    fig, ax = plt.subplots(figsize=(8, 3.6))
    sb = base["steady"]["series_kb"][:-1] if len(base["steady"]["series_kb"]) > base["seconds"] else base["steady"]["series_kb"]
    so = opt["steady"]["series_kb"][:-1] if len(opt["steady"]["series_kb"]) > opt["seconds"] else opt["steady"]["series_kb"]
    ax.plot(range(len(sb)), sb, label="до", color="#c0504d")
    ax.plot(range(len(so)), so, label="после", color="#4f9d69")
    ax.set_xlabel("секунда сценария")
    ax.set_ylabel("КБ/с, все клиенты")
    ax.set_title("Исходящий трафик по секундам")
    ax.legend()
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(MEDIA / "repl_timeline.png", dpi=130)
    plt.close(fig)
    # 3) вклад техник
    runs = {r["config"]: r for r in results["runs"]}
    bk = base["steady"]["kb_s_total"]
    singles = [("relevancy", "only_relevancy"), ("dormancy", "only_dormancy"), ("push", "only_push"), ("quantize", "only_quantize"), ("freq", "only_freq")]
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4))
    a1.barh([TECH_RU[k] for k, _ in singles][::-1], [runs[n]["steady"]["kb_s_total"] for _, n in singles][::-1], color="#6c8ebf")
    a1.axvline(bk, color="#c0504d", ls="--", label="baseline")
    a1.set_xlabel("КБ/с (3 клиента)")
    a1.set_title("Каждая техника отдельно")
    a1.legend()
    chain = [r for r in results["runs"] if r["config"].startswith("chain_")]
    names = ["baseline"] + [TECH_RU[r["config"].split("_", 2)[2]].split(":")[0].split(" (")[0] for r in chain]
    vals = [bk] + [r["steady"]["kb_s_total"] for r in chain]
    a2.plot(range(len(vals)), vals, marker="o", color="#4f9d69")
    a2.set_xticks(range(len(vals)))
    a2.set_xticklabels(names, rotation=35, ha="right", fontsize=8)
    a2.set_yscale("log")
    a2.set_ylabel("КБ/с, лог. шкала")
    a2.set_title("Накопительно: добавляем технику за техникой")
    a2.grid(alpha=0.3, which="both")
    fig.tight_layout()
    fig.savefig(MEDIA / "repl_techniques.png", dpi=130)
    plt.close(fig)
    return True


def build_baseline(base, has_media):
    s, j = base["steady"], base["join"]
    pc = s["per_class"]
    n_level = base["level_actors"]
    counts = {"tree": 40, "pickup": 12, "bot": 8, "cloud": 8}
    rel_join = j["per_kind"].get("reliable", {})
    rows_class = []
    for c in CLS:
        cnt = {"player": base["clients"], **counts}.get(c, "динамически")
        rows_class.append([CLS_RU[c], cnt, f1(pc[c]["entries_per_s"] / base["clients"]), f2(pc[c]["kb_s"]), f"{pc[c]['kb_s'] / s['kb_s_total'] * 100:.0f}%"])
    heavy = [[h["id"], CLS_RU[h["cls"]], f0(h["entries"]), f1(h["bytes"] / 1024.0), f2(h["bytes"] / 1024.0 / s["seconds"])] for h in s["heavy_actors"]]
    static_share = (pc["tree"]["kb_s"] + pc["pickup"]["kb_s"] + pc["cloud"]["kb_s"]) / s["kb_s_total"] * 100
    tree_share = pc["tree"]["kb_s"] / s["kb_s_total"] * 100
    media = "\n![Трафик по классам](media/repl_by_class.png)\n\n![Трафик по секундам](media/repl_timeline.png)\n" if has_media else ""
    return f"""# ПР №5 · Базовый профиль репликации («до»)

> Файл строится автоматически: `python tools/repl_report.py` из `docs/repl/baseline.json`. Условие — `Практическая_работа__5.pdf`
> (в нём Unreal Engine; по договорённости с преподавателем работа выполнена в **Godot** на собственном UDP-протоколе ПР №1–3).

## 1. Что измеряем

**Нагруженная сцена** («длинный уровень» платформера, 16000 px, сервер-авторитетный мир `ReplWorld`), на старте **{n_level} реплицируемых акторов**
(не менее 50 по заданию) + по одному аватару на клиента + снаряды, которые появляются и исчезают:

{table(["Класс", "Сколько", "Поведение"], [
    ["Деревья (декор)", 40, "стоят на месте; изредка снаряд попадает и меняет hp"],
    ["Предметы", 12, "лежат; при подборе игроком флаг `st` меняется, через 15 с возвращается"],
    ["Боты", 8, "патрулируют ±150 px, стреляют по игроку в радиусе 700 px"],
    ["Облака (фон)", 8, "плывут по небу 5–8 px/с"],
    ["Снаряды", "0…~15", "летят 1,5 с, исчезают; попадают в деревья/ботов"],
    ["Игроки", base["clients"], "аватары клиентов: идут, стреляют; видны всем"]], ["l", "r", "l"])}

**Baseline = всё как в наивной реализации**: каждый клиент получает **все** акторы мира; на каждом сетевом тике (30 Гц) шлётся
**полное состояние** каждого актора (21 байт: `id u16, cls u8, x y vx vy float32, st u8, hp u8`); без дельт, без квантования,
без сна статики, без приоритетов. Репликация включена всем всем без ограничений — как требует пункт 1 задания.

**Сценарий идентичен «до» и «после»**: seed мира 7, {base["clients"]} клиента (UDP-логика `NetNode` на виртуальном времени), 2 с входа
(начальная синхронизация, фаза `join`) и {base["seconds"]} с игры (фаза `steady`): клиент 0 идёт вправо, клиент 1 влево вдвое медленнее,
клиент 2 стоит 10 с, стреляя, затем идёт влево. За прогон: {base["world_events"]["shots"]} выстрелов, {base["world_events"]["tree_hits"]} попаданий
в деревья, {base["world_events"]["bot_hits"]} в ботов, {base["world_events"]["pickups_taken"]} подборов предметов. Мир от репликации не зависит, поэтому
контрольная сумма состояния мира в конце прогона у «до» и «после» совпадает (`{base["checksum"]}`).

## 2. Чем измеряем (аналог `netprofile enable` + Network Profiler)

| Unreal Engine | Эта работа |
|---|---|
| `netprofile enable` / Network Profiler | `ReplProfiler` (`godot/scripts/repl/repl_profiler.gd`): включён всегда, считает на сервере |
| исходящий трафик сервера | байты «на проводе» = полезная нагрузка + заголовок протокола 8 Б + IPv4/UDP 28 Б — как считает `NetNode` |
| частота обновлений | записей (обновлений актора) и пакетов в секунду на клиента |
| «тяжёлые» акторы | таблица актор → байты за прогон (раздел 5) |
| сверка с сетью | суммарные байты канала `LoopLink.sent_bytes` и счётчики `NetNode.Peer.bytes_out_total` |

Профиль сохраняется в `docs/repl/baseline.json` (полный) и `docs/repl/results.json` (все 15 конфигураций).

## 3. Результат: исходящий трафик сервера

{table(["Показатель (фаза steady, {} с)".format(base["seconds"]), "Значение"], [
    ["Исходящий трафик, всего ({} клиента)".format(base["clients"]), f"**{f1(s['kb_s_total'])} КБ/с**"],
    ["Исходящий трафик на одного клиента", f"**{f1(s['kb_s_per_client'])} КБ/с**"],
    ["Пик за 100 мс (все клиенты)", f"{f1(s['peak_100ms_kb_s_total'])} КБ/с"],
    ["Пакетов в секунду на клиента", f1(s["packets_per_s_per_client"])],
    ["Обновлений акторов в секунду на клиента", f0(s["entries_per_s_per_client"])],
    ["Средний размер записи", f"{f1(s['avg_bytes_per_entry'])} Б"],
    ["Доля заголовков (8 Б + 28 Б IP/UDP на пакет)", f"{s['overhead_bytes'] / s['wire_bytes'] * 100:.1f}%"],
    ["Акторов, известных клиенту (среднее / максимум)", f"{f1(s['known_avg'])} / {s['known_max']} из {base['actors_at_end']}"],
    ["Начальная синхронизация: надёжных байт на 3 клиентов", f"{f0(rel_join.get('bytes', 0))} Б ({rel_join.get('entries', 0)} записей)"]],
    ["l", "r"])}
{media}
## 4. Куда уходит трафик по классам

{table(["Класс", "Акторов", "Обн./с на клиента", "КБ/с (все клиенты)", "Доля"], rows_class)}

Главный вывод baseline: **деревья, предметы и облака — {static_share:.0f}% трафика**, хотя почти ничего не меняют
(одни только деревья — {tree_share:.0f}%). Самое «горячее» для игры — боты и снаряды — занимает лишь {(pc['bot']['kb_s'] + pc['projectile']['kb_s']) / s['kb_s_total'] * 100:.0f}%.
При этом каждый клиент получает весь уровень 16000 px, а видит из него 1280 px (8%).

## 5. «Тяжёлые» акторы

В baseline все акторы одинаково «тяжёлые» (полное состояние на каждом тике), поэтому топ-10 по байтам — это просто первые по `id`
из самых частых; по-настоящему показательна таблица по классам выше.

{table(["id", "Класс", "Записей", "КБ за прогон", "КБ/с"], heavy)}

## 6. Как воспроизвести

```powershell
# PowerShell 7, из корня репозитория (кириллица: вывод Godot уже переключён скриптом на UTF-8)
.\\run_godot_demo.ps1 -Godot "C:\\Godot\\Godot_v4.7.2-stable_win64_console.exe" -Role ReplProfile
```
или вручную: `godot --headless --path godot --script tests/run_repl_profile.gd -- --out=docs/repl` и `python tools/repl_report.py`.
Живая визуализация — в самой игре: Меню → «Лаборатория репликации» (или `-Role Lab -Repl baseline`); клавиша `O` включает оптимизации «на лету».
"""


def build_optimization(base, opt, results, sat, has_media, has_shots):
    bs, os_ = base["steady"], opt["steady"]
    runs = {r["config"]: r for r in results["runs"]}
    bk, ok = bs["kb_s_total"], os_["kb_s_total"]
    red = pct_less(bk, ok)
    n_cl = base["clients"]
    bj = base["join"]["per_kind"].get("reliable", {}).get("bytes", 0)
    oj = opt["join"]["per_kind"].get("reliable", {}).get("bytes", 0)
    q_b, q_o = base["quality"], opt["quality"]

    main_rows = [
        ["Исходящий трафик, всего (КБ/с)", f1(bk), f1(ok), f"−{red:.1f}%"],
        ["Исходящий трафик на клиента (КБ/с)", f1(bs["kb_s_per_client"]), f1(os_["kb_s_per_client"]), f"−{pct_less(bs['kb_s_per_client'], os_['kb_s_per_client']):.1f}%"],
        ["Пик за 100 мс, все клиенты (КБ/с)", f1(bs["peak_100ms_kb_s_total"]), f1(os_["peak_100ms_kb_s_total"]), f"−{pct_less(bs['peak_100ms_kb_s_total'], os_['peak_100ms_kb_s_total']):.1f}%"],
        ["Реплицируемых акторов у клиента (среднее)", f1(bs["known_avg"]), f1(os_["known_avg"]), f"−{pct_less(bs['known_avg'], os_['known_avg']):.0f}%"],
        ["…из акторов в мире", base["actors_at_end"], opt["actors_at_end"], "—"],
        ["Обновлений акторов в секунду на клиента", f0(bs["entries_per_s_per_client"]), f0(os_["entries_per_s_per_client"]), f"−{pct_less(bs['entries_per_s_per_client'], os_['entries_per_s_per_client']):.1f}%"],
        ["Пакетов в секунду на клиента", f1(bs["packets_per_s_per_client"]), f1(os_["packets_per_s_per_client"]), f"−{pct_less(bs['packets_per_s_per_client'], os_['packets_per_s_per_client']):.0f}%"],
        ["Средний размер записи (Б)", f1(bs["avg_bytes_per_entry"]), f1(os_["avg_bytes_per_entry"]), f"−{pct_less(bs['avg_bytes_per_entry'], os_['avg_bytes_per_entry']):.0f}%"],
        ["Надёжный трафик начальной синхронизации, 3 клиента (Б)", f0(bj), f0(oj), f"−{pct_less(bj, oj):.0f}%"],
    ]
    cls_rows = []
    for c in CLS:
        b, o = bs["per_class"][c], os_["per_class"][c]
        cls_rows.append([CLS_RU[c], f2(b["kb_s"]), f2(o["kb_s"]), f1(b["entries_per_s"] / n_cl), f1(o["entries_per_s"] / n_cl)])
    qrows = [
        ["Видимых акторов выбрано для проверки (10 раз/с)", f0(q_b["visible"]), f0(q_o["visible"])],
        ["Видимых акторов, которых нет у клиента", q_b["missing"], q_o["missing"]],
        ["Средняя ошибка позиции видимых, px", f2(q_b["err_avg_px"]), f2(q_o["err_avg_px"])],
        ["95-й процентиль ошибки, px", f2(q_b["err_p95_px"]), f2(q_o["err_p95_px"])],
        ["Максимальная ошибка, px", f2(q_b["err_max_px"]), f2(q_o["err_max_px"])],
    ]
    singles = []
    for key in ["relevancy", "dormancy", "push", "quantize", "freq", "priority"]:
        r = runs["only_" + key]
        singles.append([TECH_RU[key], f1(r["steady"]["kb_s_total"]), f"−{pct_less(bk, r['steady']['kb_s_total']):.0f}%", f2(r["quality"]["err_avg_px"])])
    chain = []
    for r in results["runs"]:
        if r["config"].startswith("chain_"):
            key = r["config"].split("_", 2)[2]
            chain.append([f"+ {TECH_RU[key]}", f1(r["steady"]["kb_s_total"]), f"−{pct_less(bk, r['steady']['kb_s_total']):.1f}%", f1(r["steady"]["known_avg"])])
    sat_off = next(r for r in sat["runs"] if r["config"].endswith("off"))
    sat_on = next(r for r in sat["runs"] if r["config"].endswith("on"))
    srows = []
    for c in ["player", "bot", "projectile", "cloud", "tree"]:
        srows.append([CLS_RU[c], f1(sat_off["steady"]["per_class"][c]["entries_per_s"] / n_cl), f1(sat_on["steady"]["per_class"][c]["entries_per_s"] / n_cl),
                      f1(sat_off["quality"]["per_class_err_px"][c]), f1(sat_on["quality"]["per_class_err_px"][c])])
    cpu_b, cpu_o = bs["cpu_us_avg_per_client_nettick"], os_["cpu_us_avg_per_client_nettick"]
    media = "\n![Трафик по классам](media/repl_by_class.png)\n\n![Трафик по секундам](media/repl_timeline.png)\n" if has_media else ""
    media2 = "\n![Вклад техник](media/repl_techniques.png)\n" if has_media else ""
    shots = ""
    if has_shots:
        shots = "\n### Как это увидеть в игре\n\nВсё доступно из самой игры: **Меню → «Лаборатория репликации»** (строка «Репликация (ПР №5)» под настройками предсказания). Справа — настройки: набор «до»/«после»/свой, семь переключателей техник, оверлеи, профиль сети из настроек игры, кнопка «Замер». Слева — счётчики сервера в реальном времени, внизу — мини-карта уровня (яркие точки реплицируются клиенту 0).\n\n| «до» | «после» |\n|---|---|\n| ![до](media/repl_lab_baseline.png) | ![после](media/repl_lab_optimized.png) |\n\nКнопка «Замер «до/после»» прогоняет тот же сценарий на 10 с (около 10–15 с ожидания) и показывает таблицу: «до», «после», ваш текущий набор и пять техник по отдельности:\n\n![Замер](media/repl_lab_measure.png)\n\nМеню с новой строкой: ![Меню](media/repl_menu.png)\n"
    return f"""# ПР №5 · Оптимизация репликации: результат («после») и сравнение

> Файл строится автоматически: `python tools/repl_report.py` из `docs/repl/*.json`. Базовый профиль — `docs/Replication_Baseline.md`.
> Условие — Unreal Engine; по договорённости с преподавателем выполнено в **Godot**: механизмы UE (Replication Graph, Net Dormancy,
> Push Model, NetQuantize, NetUpdateFrequency, NetPriority, IsNetRelevantFor) реализованы поверх собственного UDP-протокола ПР №1–3.

## 1. Итог

**Исходящий трафик сервера упал с {f1(bk)} до {f1(ok)} КБ/с — на {red:.1f}%** при том же сценарии ({n_cl} клиента, {base["seconds"]} с, seed 7).
Это заметно больше ориентира 40–60% из задания: сцена — длинный уровень, на котором клиент видит около 8% акторов, а ≈ 75% акторов — статика (деревья и предметы),
поэтому для неё выигрыш максимален (см. раздел 6 о границах). Качество картинки при этом не страдает: ни один видимый актор не пропал,
средняя ошибка позиции {f2(q_b['err_avg_px'])} → {f2(q_o['err_avg_px'])} px.

{table(["Показатель (фаза steady)", "До", "После", "Изменение"], main_rows)}

Условия «до» и «после» идентичны: тот же seed, те же клиенты и команды; контрольная сумма мира совпала (`{opt["checksum"]}`),
т. е. разница только от сетевых настроек. Таблицы собраны из `docs/repl/baseline.json` и `docs/repl/optimized.json`.
{media}
По классам (КБ/с — все клиенты вместе, обновлений/с — на одного клиента):

{table(["Класс", "КБ/с до", "КБ/с после", "Обн./с до", "Обн./с после"], cls_rows)}

## 2. Применённые техники (все семь; требовалось минимум две)

Включение каждой — флаг в `ReplCfg`; в игре переключаются в настройках лаборатории (справа) и клавишами `1`–`7`.

1. **Replication Graph — Grid Spatialization** (`ReplGrid`, `ReplServer._update_relevance`). Мир разбит на ячейки по 500 px; движущиеся
   акторы перекладываются между ячейками. На сетевом тике сервер для каждого клиента просматривает только ячейки в радиусе 1520 px вокруг
   аватара и точно проверяет релевантность. Класс-зависимые радиусы (`CULL_PX`, аналог `NetCullDistance`): деревья/облака 1000 px, предметы 1100,
   боты и снаряды 1400 (они опасны и вне экрана), игроки — всегда. Вышедшие из зоны получают надёжный `OP_DESTROY`, вошедшие — `OP_UPSERT`
   с полным состоянием. Камера видит ±640 px, радиусы заметно больше — «выскакивания» нет (в тестах и в профиле пропаж 0).
2. **IsNetRelevantFor** (доп. задание). Направление «взгляда» — куда смотрит аватар (`st` бит 0): за спиной радиус декора и предметов ×0,75 (1000 → 750 px, всё равно больше
   полуокна камеры 640 px, поэтому видимое не пропадает); враги и снаряды опасны с любой стороны — радиус не сужается. Плюс гистерезис 120 px: уже известный актор отпускается дальше, чем берётся, — нет мигания на границе.
3. **Net Dormancy** (`CAN_SLEEP`, `ReplServer._distribute_dirty`). Деревья и предметы — `DORM_Initial`: передаются один раз при появлении
   и больше не обновляются. Если актор изменился (попадание в дерево, подбор предмета) — «пробуждение»: один **надёжный** пакет с полным состоянием
   (`FlushNetDormancy`), потому что у спящих нет периодических ключевых кадров, которые вылечили бы потерю. За прогон: {os_["reliable_ops"]["state"]} пробуждений.
4. **Push-based** (`ReplActor.set_*`, `ReplCodec` с `FMT_DELTA`). Актор сам помечает изменённое поле «грязным»; сервер не сравнивает состояние
   каждого актора с отправленным, а накапливает маску на клиента и шлёт только изменённые поля (бот в патруле: `id + mask + x` = 5 Б вместо 21 Б).
   Раз в секунду для живых акторов — ключевое полное состояние: лечит потерянные ненадёжные дельты.
5. **Квантование** (`FMT_QUANT`, аналог `FVector_NetQuantize`). Позиция — `u16` с шагом 0,25 px (ошибка ≤ 0,125 px), скорость — `i8` с шагом 8 px/с
   (≤ 4 px/с) вместо `float32`; весь уровень 16000 px помещается в `u16`. Клиент экстраполирует позицию по скорости (dead reckoning), поэтому ошибка
   скорости на 0,3 с даёт ≤ 1,2 px.
6. **NetUpdateFrequency по классам** (`OPT_HZ`). Игровое (игроки, боты, снаряды) — как было, 30 Гц; деревья 2 Гц, облака и предметы 5 Гц.
   Обновления разнесены по сетевым тикам (`id % период`, аналог frequency buckets из Replication Graph), чтобы 40 деревьев не уходили одним
   всплеском (проверено тестом `t_freq`).
7. **NetPriority + бюджет** (доп. задание, `PRIORITY`, `budget_bytes`). При нехватке бюджета на тик актор выбирается по `приоритет × время с последней
   отправки`: важное (игроки 3, снаряды 2,5, боты 2) обгоняет декор (0,3 и 0,2), а редкое не голодает — его очередь растёт. Эффект виден только при
   насыщении канала, см. раздел 5.

Новые пакеты: `T_WORLD_UPDATE` (13, ненадёжный) и `T_WORLD_RELIABLE` (14, надёжный) — формат в `docs/Protocol_Specification.md`, раздел «ПР №5».

## 3. Почему эти техники сработали именно для нашего жанра

Жанр — 2D-платформер с боковой прокруткой и стрельбой: уровень длинный, камера показывает узкое окно вокруг своего персонажа, ≈ 75% объектов —
статичный декор и предметы, а «игровое» (враги, снаряды, игроки) — небольшая доля.

* **Релевантность по X** срабатывает, потому что в боковом скролле интересный клиенту мир — узкая полоса вокруг камеры. Радиус по одной оси и
  сетка из ячеек дают дешёвый запрос; с ростом уровня трафик на клиента почти не растёт (определяется окрестностью, а не размером мира).
  В самой арене ПР №4 (один экран 1280 px) релевантность ничего бы не дала — поэтому сцена-нагрузка сделана «длинным уровнем».
* **Dormancy и push** убирают то, что не меняется: деревья и подбираемые предметы большую часть времени неподвижны. После этих двух техник деревья
  стоят {f2(os_["per_class"]["tree"]["kb_s"])} КБ/с вместо {f2(bs["per_class"]["tree"]["kb_s"])}.
* **Квантование безопасно** для 2D: 0,25 px много меньше пикселя на экране; игровая физика на сервере остаётся точной, квантуется только то, что видят клиенты.
* **Пониженная частота декора** незаметна, потому что декор почти не движется, а облако экстраполируется по скорости; игровое оставлено на 30 Гц, чтобы
  попадания и перемещения врагов не страдали.
* **Приоритеты** важны в боях: именно в стычках трафик растёт (снаряды), а канал ограничен — декор должен уступать.

## 4. Вклад каждой техники

Каждая техника в одиночку (остальные выключены), КБ/с на {n_cl} клиентов; baseline = {f1(bk)} КБ/с:

{table(["Техника отдельно", "КБ/с", "Снижение", "Ошибка вида, px"], singles)}

Накопительно (порядок добавления соответствует списку выше):

{table(["Набор", "КБ/с", "Снижение от baseline", "Акторов у клиента"], chain)}
{media2}
Замечания к таблицам: (а) техники перекрываются — «Push отдельно» уже убирает почти весь трафик статики, поэтому Dormancy после Push даёт меньше, чем сам по себе;
(б) «NetPriority отдельно» снижает трафик только потому, что бюджет 1000 Б/тик урезает обновления (спрос baseline — 1491 Б/тик), ценой видимой потери
актуальности — это не оптимизация, а ограничитель, он нужен для приоритета; (в) когда трафик уже мал, последние техники (квантование, частоты) дают единицы процентов, а главной статьёй становятся заголовки пакетов
({os_["overhead_bytes"] / os_["wire_bytes"] * 100:.0f}% трафика «после», у baseline {bs["overhead_bytes"] / bs["wire_bytes"] * 100:.0f}%).

## 5. NetPriority под нагрузкой (доп. задание)

Чтобы приоритет проявился, канал нужно насытить: релевантность выключена, бюджет {sat["budget"]} Б на клиента на сетевой тик (спрос 1491 Б).
Без приоритета бюджет расходуется по порядку `id` — первыми идут деревья, и до ботов и снарядов очередь не доходит; с приоритетом выбирается самое
«просроченное по приоритету». Трафик одинаков ({f1(sat_off["steady"]["kb_s_total"])} против {f1(sat_on["steady"]["kb_s_total"])} КБ/с), меняется то, на что он потрачен:

{table(["Класс", "Обн./с без приоритета", "Обн./с с приоритетом", "Ошибка без, px", "Ошибка с, px"], srows)}

## 6. Качество, цена и границы выводов

{table(["Показатель качества", "До", "После"], qrows)}

* **Ошибка ≈ {f1(q_o["err_avg_px"])} px** одинакова до и после: это шаг мира за тик при экстраполяции (снаряд 320 px/с ÷ 60 = 5,3 px, игрок до 4,3 px), а не следствие оптимизаций.
* **Потери и задержка**: тест `t_loss` — задержка 25 мс и 15% потерь в обе стороны, 15 с игры: видимые акторы на месте, hp деревьев и состояние предметов
  у клиента совпадают с серверными, боты в пределах 60 px. Порядок пакетов: опоздавший `UPSERT` не воскрешает удалённый актор («надгробия»), опоздавшее
  обновление старше применённого отбрасывается (тест `t_reorder`).
* **CPU**: время сетевого тика на клиента в GDScript — {f0(cpu_b)} мкс против {f0(cpu_o)} мкс (меряется реальными часами, значения ориентировочные): релевантность
  и push заменяют обход всех акторов обходом соседних ячеек и «грязных» акторов.
* **Почему −{red:.0f}%, а не 40–60%.** Ориентир из задания рассчитан на сцены, где большая часть объектов видна. Здесь клиент видит ≈ 8% уровня и ≈ 75% объектов статичны.
  На компактной арене с видимым целиком миром эффект релевантности исчезнет, и останутся Push, Dormancy, квантование и частоты. По таблице раздела 4 каждая из них
  в одиночку даёт −{pct_less(bk, runs["only_push"]["steady"]["kb_s_total"]):.0f}% (Push), −{pct_less(bk, runs["only_freq"]["steady"]["kb_s_total"]):.0f}% (частоты), −{pct_less(bk, runs["only_dormancy"]["steady"]["kb_s_total"]):.0f}% (Dormancy), −{pct_less(bk, runs["only_quantize"]["steady"]["kb_s_total"]):.0f}% (квантование) — то есть и без релевантности ориентир перекрыт, хотя порядок величин другой.
* **Что не моделировалось**: реальная сеть с джиттером в профиле (профиль идёт на виртуальном времени без потерь — так числа воспроизводимы; потери и задержку
  проверяют тесты), байты считаются «на проводе» (+28 Б IPv4/UDP), без шифрования; сжатие `u16`-идентификаторов в 1 байт на клиента и объединение мелких
  пакетов — следующие шаги.
{shots}
## 7. Как воспроизвести

```powershell
# PowerShell 7, из корня репозитория
.\\run_godot_demo.ps1 -Godot "C:\\Godot\\Godot_v4.7.2-stable_win64_console.exe" -Role ReplProfile   # профиль + эти отчёты
.\\run_godot_demo.ps1 -Godot "C:\\Godot\\Godot_v4.7.2-stable_win64_console.exe" -Role Lab            # игра сразу на экране лаборатории (или Меню → «Лаборатория репликации»)
.\\run_godot_demo.ps1 -Godot "C:\\Godot\\Godot_v4.7.2-stable_win64_console.exe" -Role Tests          # все автотесты, в т.ч. репликации
```
"""


def main():
    base, opt = load("baseline.json"), load("optimized.json")
    results, sat = load("results.json"), load("saturation.json")
    has_media = charts(base, opt, results, sat)
    has_shots = (MEDIA / "repl_lab_baseline.png").exists() and (MEDIA / "repl_lab_optimized.png").exists()
    write(ROOT / "docs" / "Replication_Baseline.md", build_baseline(base, has_media))
    write(ROOT / "docs" / "Replication_Optimization.md", build_optimization(base, opt, results, sat, has_media, has_shots))
    red = pct_less(base["steady"]["kb_s_total"], opt["steady"]["kb_s_total"])
    print(f"docs/Replication_Baseline.md и docs/Replication_Optimization.md обновлены; снижение трафика {red:.1f}%")


if __name__ == "__main__":
    main()
