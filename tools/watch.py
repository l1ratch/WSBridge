# Монитор оживления: worker->DC и kws-гейтвей каждые 20 минут.
# Выходит (и печатает REVIVED), когда любой путь ожил.
# Uso: python tools/watch.py
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from churn_test import handshake  # noqa: E402
from gw_dcs import probe_dc  # noqa: E402

WORKER = 'long-bush-c170.sm171105.workers.dev'

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
    alive = ('respq' in ev) or gw.startswith('PASS')
    print(f'{ts} worker={ev} kws={gw}', flush=True)
    if alive:
        print('REVIVED', flush=True)
        break
    time.sleep(1200)
