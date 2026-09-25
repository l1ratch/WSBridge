# Хирн-тест через CF worker: повторяет ли DC поведение «burst -> тишина -> смерть»
# при параллельности/частоте подключений с CF-адресов (гипотеза троттлинга).
# Unauth-рукопожатие (init + req_pq -> resPQ), тот же путь, что и телефон.
# Uso: python tools/churn_test.py [worker_host] [dc_ip]
import os
import struct
import sys
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_gateway import ws_connect, ws_send, ws_recv, make_init  # noqa: E402
from test_pipe import ctr, build_req_pq, ABRIDGED  # noqa: E402

RES_PQ = 0x05162463


def find_respq(buf: bytes) -> bool:
    off = 0
    while off < len(buf):
        b0 = buf[off]
        if b0 < 0x7F:
            ln, hdr = (b0 & 0x7F) * 4, 1
        elif b0 == 0x7F:
            if len(buf) - off < 4:
                return False
            ln, hdr = int.from_bytes(buf[off + 1:off + 4], 'little') * 4, 4
        else:
            return False
        if len(buf) - off - hdr < ln:
            return False
        if ln >= 4:
            (ctor,) = struct.unpack_from('<I', buf, off + hdr)
            if ctor == RES_PQ:
                return True
        off += hdr + ln
    return False


def handshake(host, dc_ip, dc_idx=2, timeout=12):
    """Одно рукопожатие. Возвращает dict: ws/first/respq (сек) или err/stall."""
    ev = {}
    t0 = time.time()
    try:
        ss = ws_connect(host, f'/apiws?dst={dc_ip}', timeout=8)
    except Exception as e:
        return {'err': f'ws:{type(e).__name__}'}
    ev['ws'] = time.time() - t0
    try:
        init = make_init(dc_idx, ABRIDGED)
        enc = ctr(init[8:40], init[40:56])
        rev = init[8:56][::-1]
        dec = ctr(rev[:32], rev[32:])
        nonce = os.urandom(16)
        ws_send(ss, enc.update(init))
        ws_send(ss, enc.update(build_req_pq(nonce, abridged=True)))
        ss.settimeout(timeout)
        buf = b''
        while time.time() - t0 < timeout:
            op, payload, _ = ws_recv(ss)
            if op == 8:
                ev['close'] = round(time.time() - t0, 2)
                break
            if op in (0, 1, 2) and payload:
                if 'first' not in ev:
                    ev['first'] = round(time.time() - t0, 2)
                buf += dec.update(payload)
                if find_respq(buf):
                    ev['respq'] = round(time.time() - t0, 2)
                    break
        else:
            ev['stall'] = True  # время вышло: данные были или нет, resPQ не пришёл
    except Exception as e:
        ev['err'] = f'{type(e).__name__}'
    finally:
        try:
            ss.close()
        except Exception:
            pass
    return ev


def show(tag, evs):
    ok = sum(1 for e in evs if 'respq' in e)
    stall = sum(1 for e in evs if e.get('stall') or ('first' in e and 'respq' not in e))
    silent = sum(1 for e in evs if 'err' in e or ('close' in e and 'first' not in e))
    med = sorted(e['respq'] for e in evs if 'respq' in e)
    med = med[len(med) // 2] if med else None
    print(f'{tag}: ok={ok}/{len(evs)} stall={stall} silent={silent} '
          f'respq_med={med}', flush=True)
    for i, e in enumerate(evs):
        print(f'   #{i} {e}', flush=True)


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else 'long-bush-c170.sm171105.workers.dev'
    dc_ip = sys.argv[2] if len(sys.argv) > 2 else '149.154.167.41'
    print(f'worker={host} dc={dc_ip}', flush=True)

    base = [handshake(host, dc_ip) for _ in range(3)]
    show('BASELINE seq x3', base)

    with ThreadPoolExecutor(max_workers=8) as ex:
        par = list(ex.map(lambda _: handshake(host, dc_ip), range(8)))
    show('PARALLEL K=8', par)

    churn = [handshake(host, dc_ip) for _ in range(12)]
    show('CHURN seq x12 no-pause', churn)


if __name__ == '__main__':
    main()
