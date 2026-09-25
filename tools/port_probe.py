# Портовая матрица через воркер: dst=IP&port=N (query-трюк, воркер парсит port).
# Uso: python tools/port_probe.py [worker] [dc_ip]
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from churn_test import handshake  # noqa: E402

host = sys.argv[1] if len(sys.argv) > 1 else 'long-bush-c170.sm171105.workers.dev'
ip = sys.argv[2] if len(sys.argv) > 2 else '149.154.167.51'
for port in (443, 80, 88):
    ev = handshake(host, f'{ip}&port={port}', timeout=10)
    print(f'port {port}: {ev}', flush=True)
