# Проба нескольких DC-адресов через воркер: block per-IP или по всему CF-эгрессу?
# Uso: python tools/dc_probe.py [worker_host]
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from churn_test import handshake  # noqa: E402

DCS = [
    (2, '149.154.167.41'),   # мастер телефона
    (2, '149.154.167.51'),   # канонический DC2
    (1, '149.154.175.53'),   # DC1
    (4, '149.154.167.91'),   # DC4
    (5, '91.108.56.130'),    # DC5
]

host = sys.argv[1] if len(sys.argv) > 1 else 'long-bush-c170.sm171105.workers.dev'
for idx, ip in DCS:
    evs = [handshake(host, ip, dc_idx=idx, timeout=10) for _ in range(2)]
    print(f'dc{idx} {ip}: {evs}', flush=True)
