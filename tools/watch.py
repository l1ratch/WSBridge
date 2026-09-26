# Монитор оживления: worker->DC и kws-гейтвей каждые 20 минут.
# Выходит (и печатает REVIVED), когда любой путь ожил.
# Uso: python tools/watch.py
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from churn_test import handshake  # noqa: E402
from gw_dcs import probe_dc  # noqa: E402
from kws_probe import probe as front_probe  # noqa: E402

WORKER = 'long-bush-c170.sm171105.workers.dev'
FRONTS = ['kws2.pclead.co.uk', 'kws2.offshor.co.uk', 'kws2.kartoshka.co.uk']

while True:
    ts = time.strftime('%d %H:%M')
    try:
        ev = handshake(WORKER, '149.154.167.51', timeout=10)
    except Exception as e:
        ev = {'err': type(e).__name__}
    try:
        gw = probe_dc('149.154.167.99', 'web.telegram.org', 2, 'padded')
    except Exception as e:
        gw = f'ERR {type(e).__name__}'
    front = 'dead'
    for f in FRONTS:
        try:
            r = front_probe(f, 2)
        except Exception as e:
            r = f'ERR {type(e).__name__}'
        if r.startswith('ALIVE'):
            front = f'{f}: {r}'
            break
    alive = ('respq' in ev) or gw.startswith('PASS') or front != 'dead'
    print(f'{ts} worker={ev} kws={gw} front={front}', flush=True)
    if alive:
        print('REVIVED', flush=True)
        break
    time.sleep(1200)
