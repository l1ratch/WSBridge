# TLS-зонд через CF worker pipe: что реально слушает на dst:443?
# Гоняет настоящий TLS-handshake через ssl.MemoryBIO поверх WS-фреймов.
# Uso: python tools/test_tls_probe.py [worker_host] [dst] [sni]
import os, ssl, socket, sys, time

from test_gateway import ws_connect, ws_send, ws_recv


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else 'long-bush-c170.sm171105.workers.dev'
    dst = sys.argv[2] if len(sys.argv) > 2 else '149.154.167.41'
    sni = sys.argv[3] if len(sys.argv) > 3 else 'apv3.stel.com'

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    incoming = ssl.MemoryBIO()
    outgoing = ssl.MemoryBIO()
    sslobj = ctx.wrap_bio(incoming, outgoing, server_hostname=sni)

    print(f'worker={host} dst={dst} sni={sni}')
    ss = ws_connect(host, path=f'/apiws?dst={dst}')
    ss.settimeout(10)
    t0 = time.time()
    print('WS 101 OK, driving TLS handshake...')

    got_hello = False
    try:
        while time.time() - t0 < 12:
            try:
                sslobj.do_handshake()
                print(f'+{time.time()-t0:.2f}s TLS HANDSHAKE COMPLETE — '
                      f'{dst}:443 говорит TLS')
                got_hello = True
                break
            except ssl.SSLWantReadError:
                pass
            # вытолкнуть ClientHello/next flight в WS
            out = outgoing.read()
            if out:
                ws_send(ss, out)
                print(f'+{time.time()-t0:.2f}s -> ws {len(out)}B')
            # прочитать ответ в bio
            try:
                opcode, payload, fin = ws_recv(ss)
                if opcode == 8:
                    code = int.from_bytes(payload[:2], 'big') if len(payload) >= 2 else 0
                    reason = payload[2:].decode('utf-8', 'replace') if len(payload) > 2 else ''
                    print(f'+{time.time()-t0:.2f}s CLOSE code={code} reason={reason!r}')
                    break
                if payload:
                    head = payload[:5].hex()
                    print(f'+{time.time()-t0:.2f}s <- ws {len(payload)}B head={head}')
                    incoming.write(payload)
            except (TimeoutError, socket.timeout):
                print('+%.2fs WS молчит' % (time.time()-t0))
                break
            except EOFError:
                print('+%.2fs EOF' % (time.time()-t0))
                break
    finally:
        ss.close()

    if got_hello:
        print('RESULT: TLS-эндпоинт за worker-трубой')
    else:
        print('RESULT: TLS не ответил')


if __name__ == '__main__':
    main()
