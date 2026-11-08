#!/usr/bin/env python3
"""Подписывает скриншоты сценария ПР №4: сверху добавляет полосу с подписью (кириллица, DejaVu Sans).
Использование: python tools/caption_shots.py <каталог_сырых_скриншотов> <каталог_результата> <имя_префикса>
Сырые файлы: T?_<n>_<метка>.png (их делает Scenario при --shots-dir)."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

CAPTIONS = {
    "T2": {"1_press": "T2 · БЕЗ предсказания рывка · 100 мс в одну сторону. Момент нажатия Shift: на экране клиента пока ничего не происходит",
           "2_waiting": "Прошло ~120 мс: ответ сервера ещё в пути, рывка на экране нет — игрок видит «залипание» управления",
           "3_server_response": "Ответ сервера пришёл (≈ RTT 200 мс + тик): рывок появился только сейчас, клиента «догоняет» коррекция",
           "4_after": "Через 250 мс: клиент и сервер согласованы, соединение не рвётся"},
    "T3": {"1_press": "T3 · С предсказанием рывка · 100 мс в одну сторону. Нажатие Shift: рывок виден СРАЗУ, оранжевый «призрак» — положение по серверу",
           "2_waiting": "Прошло ~120 мс: клиент уже впереди (линия «опережения»), сервер ещё не подтвердил",
           "3_server_response": "Подтверждение сервера пришло: расхождения нет, коррекция не нужна",
           "4_after": "Через 250 мс: призрак догнал персонажа, состояния совпали"},
    "T5": {"1_press": "T5 · ЧИТ клиента · 175±25 мс, 4% потерь. Рывок во время кулдауна: клиент локально его выполняет",
           "2_waiting": "Сервер ещё не знает о нём: предсказанный персонаж ушёл вперёд, призрак сервера стоит",
           "3_server_response": "Сервер ОТКЛОНИЛ рывок (cooldown): красное кольцо — клиент получил авторитетное состояние и переиграл команды",
           "4_after": "Клиент вернулся к авторитетному результату; игра и соединение продолжаются без разрыва"},
}
raw, out, prefix = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
out.mkdir(parents=True, exist_ok=True)
font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 17)
for f in sorted(raw.glob("T*_*.png")):
    case, rest = f.stem.split("_", 1)
    text = CAPTIONS.get(case, {}).get(rest, f"{case} · {rest}")
    im = Image.open(f).convert("RGB")
    w, h = im.size
    canvas = Image.new("RGB", (w, h + 62), (16, 18, 28))
    canvas.paste(im, (0, 62))
    d = ImageDraw.Draw(canvas)
    # перенос строки по ширине
    words, lines, cur = text.split(), [], ""
    for wd in words:
        t = (cur + " " + wd).strip()
        if d.textlength(t, font=font) > w - 24:
            lines.append(cur)
            cur = wd
        else:
            cur = t
    lines.append(cur)
    for i, ln in enumerate(lines[:2]):
        d.text((12, 8 + i * 24), ln, font=font, fill=(235, 238, 250))
    canvas.save(out / f"{prefix}_{rest}.png")
    print("подписан:", out / f"{prefix}_{rest}.png")
