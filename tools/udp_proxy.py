#!/usr/bin/env python3
"""UDP-прокси между клиентом и сервером для ПР №6: «злоумышленник посередине» и имитация Cloudflare Spectrum.

  python tools/udp_proxy.py --listen 27030 --target 127.0.0.1:27031 [--tamper] [--tamper-count N] [--replay] [--loss P] [--quiet]

Клиент подключается к --listen, сервер слушает --target. Для сервера все клиенты выглядят как адрес прокси (так же, как
для origin-сервера за Spectrum все клиенты выглядят как адреса Cloudflare) — см. docs/Cloudflare_Spectrum_Setup.md.
Режимы атаки (только направление клиент -> сервер):
  --tamper         в каждой ENCRYPTED-датаграмме меняется один бит шифртекста (негативный тест ПР №6);
  --tamper-count N портить только первые N таких датаграмм (потом пропускать, чтобы увидеть, что повторная передача лечит);
  --replay         каждая датаграмма отправляется серверу ещё раз через 50 мс (replay-атака);
  --loss P         терять P процентов датаграмм в обе стороны.
В журнал пишутся тип пакета и первые байты каждой датаграммы — то, что показал бы Wireshark.
"""
import argparse
import random
import socket
import sys
import threading
import time

T_NAMES = {1: "PING", 2: "PONG", 3: "MOVEMENT", 4: "SHOOT", 5: "ACK", 6: "HELLO", 7: "WELCOME", 8: "INPUT", 9: "SNAPSHOT",
           10: "GAME_EVENT", 11: "LEAVE", 12: "ROSTER", 13: "WORLD_UPDATE", 14: "WORLD_RELIABLE",
           15: "KEY_EXCHANGE", 16: "ENCRYPTED"}


def describe(d: bytes) -> str:
    if not d:
        return "пусто"
    t = d[0]
    seq = int.from_bytes(d[1:3], "big") if len(d) >= 3 else -1
    return "%s seq=%d len=%d  %s" % (T_NAMES.get(t, "type%d" % t), seq, len(d), d[:24].hex(" "))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--tamper", action="store_true")
    ap.add_argument("--tamper-count", type=int, default=-1)
    ap.add_argument("--replay", action="store_true")
    ap.add_argument("--loss", type=float, default=0.0)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    host, port = a.target.rsplit(":", 1)
    target = (host, int(port))

    front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    front.bind(("0.0.0.0", a.listen))
    back = {}                     # адрес клиента -> сокет к серверу (у каждого клиента свой исходящий порт прокси)
    lock = threading.Lock()
    tampered = [0]

    def log(msg: str) -> None:
        if not a.quiet:
            print(msg, flush=True)

    def pump_back(client, s):
        while True:
            try:
                d, _ = s.recvfrom(2048)
            except OSError:
                return
            if a.loss and random.random() * 100 < a.loss:
                log("[сервер -> клиент] ПОТЕРЯН %s" % describe(d))
                continue
            log("[сервер -> клиент] %s" % describe(d))
            front.sendto(d, client)

    print("прокси :%d -> %s:%s  tamper=%s count=%s replay=%s loss=%s%%" % (a.listen, host, port, a.tamper, a.tamper_count, a.replay, a.loss), flush=True)
    while True:
        d, client = front.recvfrom(2048)
        with lock:
            if client not in back:
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.bind(("0.0.0.0", 0))
                back[client] = s
                threading.Thread(target=pump_back, args=(client, s), daemon=True).start()
                log("новый клиент %s:%d -> для сервера он будет «%s»" % (client[0], client[1], "прокси, порт %d" % s.getsockname()[1]))
            s = back[client]
        if a.loss and random.random() * 100 < a.loss:
            log("[клиент -> сервер] ПОТЕРЯН %s" % describe(d))
            continue
        out = d
        if a.tamper and d and d[0] == 16 and len(d) > 21 and (a.tamper_count < 0 or tampered[0] < a.tamper_count):
            b = bytearray(d)
            b[8 + 12] ^= 0x01                # первый байт шифртекста
            out = bytes(b)
            tampered[0] += 1
            log("[клиент -> сервер] ИСПОРЧЕН бит шифртекста: %s" % describe(out))
        else:
            log("[клиент -> сервер] %s" % describe(out))
        s.sendto(out, target)
        if a.replay and d and d[0] == 16:
            threading.Timer(0.05, lambda dd=d, ss=s: ss.sendto(dd, target)).start()
            log("[клиент -> сервер] (replay: копия уйдёт через 50 мс)")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
