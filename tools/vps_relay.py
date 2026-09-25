#!/usr/bin/env python3
"""WSBridge relay: CF worker -> VPS -> Telegram DC (IPv6).

Запуск на VPS:  python3 vps_relay.py [port]   (дефолт 7700)
Worker шлёт первой строкой "SECRET dst_ipv4", дальше сырой MTProto-поток.
Какой DC нужен — читается из datacenter-тега init (байты 60:62, int16 LE,
по модулю), и реле коннектится в IPv6-primary этого DC. Фолбэк — v4 dst.
Порт VPS должен быть открыт; секрет сверьте с worker-pipe-vps.js.
"""
import asyncio
import struct
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7700
SECRET = "wsb1"

# IPv6-primary продакшн-DC (Pyrogram FAQ, production environment).
V6 = {
    1: "2001:b28:f23d:f001::a",
    2: "2001:67c:4e8:f002::a",
    3: "2001:b28:f23d:f003::a",
    4: "2001:67c:4e8:f004::a",
    5: "2001:b28:f23f:f005::a",
}


async def pipe(r, w):
    try:
        while True:
            d = await r.read(65536)
            if not d:
                break
            w.write(d)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass


async def handle(r, w):
    up_r = up_w = None
    try:
        line = await asyncio.wait_for(r.readline(), 10)
        parts = line.decode().split()
        if len(parts) != 2 or parts[0] != SECRET:
            return
        dst = parts[1]
        # Первый кусок потока = init (>=64B): из него узнаём DC.
        head = await asyncio.wait_for(r.readexactly(62), 10)
        tag = abs(struct.unpack_from("<h", head, 60)[0])
        targets = []
        if tag in V6:
            targets.append(V6[tag])
        targets.append(dst)
        for host in targets:
            try:
                up_r, up_w = await asyncio.wait_for(
                    asyncio.open_connection(host, 443), 7
                )
                break
            except Exception:
                continue
        else:
            return
        up_w.write(head)
        await up_w.drain()
        await asyncio.gather(pipe(r, up_w), pipe(up_r, w))
    except Exception:
        pass
    finally:
        for s in (w, up_w):
            try:
                if s:
                    s.close()
            except Exception:
                pass


async def main():
    srv = await asyncio.start_server(handle, "0.0.0.0", PORT)
    print(f"relay listening on :{PORT}", flush=True)
    async with srv:
        await srv.serve_forever()


asyncio.run(main())
