# Живы ли kws-гейтвеи? Честный probe: relay_init (padded) + req_pq -> resPQ.
# Фрейминг как в референсе: init первым кадром, запрос — отдельным кадром,
# intermediate-длины (padded = intermediate framing, см. test_bridge.py).
# Uso: python tools/kws_probe.py [dc]
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_gateway import ws_connect, ws_send, ws_recv, make_init  # noqa: E402
from test_pipe import ctr, build_req_pq  # noqa: E402

PADDED = b'\xdd\xdd\xdd\xdd'
RES_PQ = 0x05162463
BASES = [
    "pclead.co.uk", "offshor.co.uk", "cakeisalie.co.uk", "noskomnadzor.co.uk",
    "lovetrue.co.uk", "sorokdva.co.uk", "pyatdesyatdva.co.uk", "kartoshka.co.uk",
    "sorokodin.co.uk", "pyatdesyatodin.co.uk", "notelega.co.uk", "ebally.co.uk",
    "nebally.co.uk", "havegreatday.co.uk", "pomogite.co.uk", "fixtelega.co.uk",
    "sadnews.co.uk", "onedaychamp.co.uk", "stopblocking.co.uk", "nothingthere.co.uk",
]


def find_respq(buf: bytes) -> bool:
    off = 0
    while len(buf) - off >= 4:
        ln = struct.unpack_from('<I', buf, off)[0] & 0x7FFFFFFF
        if len(buf) - off - 4 < ln:
            return False
        if ln >= 4:
            (ctor,) = struct.unpack_from('<I', buf, off + 4)
            if ctor == RES_PQ:
                return True
        off += 4 + ln
    return False


def probe(host: str, dc: int):
    try:
        ss = ws_connect(host, timeout=6)
    except Exception as e:
        return f'CONNECT FAIL {e}'
    try:
        init = make_init(dc, PADDED)
        enc = ctr(init[8:40], init[40:56])
        rev = init[8:56][::-1]
        dec = ctr(rev[:32], rev[32:])
        t0 = time.time()
        ws_send(ss, init)
        ws_send(ss, enc.update(build_req_pq(os.urandom(16), abridged=False)))
        ss.settimeout(10)
        buf = b''
        while time.time() - t0 < 10:
            op, payload, _ = ws_recv(ss)
            if op == 8:
                return f'CLOSED +{time.time()-t0:.1f}s'
            if op in (0, 1, 2) and payload:
                if not buf:
                    first = time.time() - t0
                buf += dec.update(payload)
                if find_respq(buf):
                    return f'ALIVE resPQ +{time.time()-t0:.1f}s (first byte +{first:.1f}s)'
        return f'SILENT (got {len(buf)}B plain, no resPQ)'
    except Exception as e:
        return f'SILENT {type(e).__name__}'
    finally:
        try:
            ss.close()
        except Exception:
            pass


dc = int(sys.argv[1]) if len(sys.argv) > 1 else 2
for base in BASES:
    host = f'kws{dc}.{base}'
    r = probe(host, dc)
    print(f'{host}: {r}', flush=True)
    if r.startswith('ALIVE'):
        break
