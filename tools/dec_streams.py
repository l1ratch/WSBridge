# Журнал 08:54 (build 25): для каждого соединения есть uphead (init с ключами)
# и ws_head (первые входящие байты). Obfuscated2: исходящий CTR = init[8:40]/[40:56]
# (payload с офсета 64), входящий = реверс тех же байтов (вопрос: офсет 0 или 64?).
# Проверяем: (1) структура исходящих кадров телефона, (2) каким офсетом decryptится
# входящий поток, (3) совпадает ли auth_key_id в обе стороны.
import struct
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

PAIRS = [
    ('c0', '3f9e50435527c37746dcec00f7a28963e68e002211a88c4821447560ae16d8203684e1af9fa292372ec2304a85a327412ecc0a1ea6e988db3d251913e8c98b7a5dc3ae59bb66d3a1e826871f9c083406ef3f1c9777a2a8d582b6c9434e1869fb',
     'd4f8f575669e03665687206841abc6e6'),
    ('c1', 'dbba7fb266fb4764b27b1925c41add4751aa2bb331243a115d136caf97fa7124f641fc3e77c69f895cda9667aeadd47316443a3925c7d21037d4fb61ee942fcc7dfbbc80629d8235187a7fc038fdfb4116b1af616cf42f0a2e327b224170ed88',
     'a75c9d93'),
    ('c2a', '2718034f41b18ebaac67dfcd9b7cd9565015ab830cf294f472d95cbf1bc20b05ddcaeff055e115ed6ea5cc4ddb36f7d4ded2485ae1eee09534ec9864091625d9a793cc35eccb20f403efdbb6b9553f0a6c3f4502310b7b69a36ae707c68aa83a',
     '4a753405'),
    ('c4', '2854571ea981c773f4f5e35599dd48cd477929b453c3bb9287a67b6e579fc7373dcf94f34b866420b4befba1234c08ccef10d6216373b19d8d42602f2b72edeebb1c8d0126cce201954bc7e72e9d2bed16d068bc99357d163dd94fbae19527ea',
     'de09ea02'),
    ('c3a', 'c7f14af1b9dc8d4bfc5c572003038687ce0a9c48af146beccab90b9dae282a3ec43ea521f8be2a052577aad69c4f279517394cee75bfcade75629bbc43fa22bc28c7a06d9252a628ba359335cf97246a5b3ff3c5101528c17ab203add2904c36',
     'ca4341cd'),
    ('c6', '208238b96036213650a57a0ad4e13e58385324d3a28d2128f4573015a8d5dd888bf50912734f1f60d680c0e8cff5479c3e0e1c936f0f0de6666adad3e222b8e0cdf69a8899657f152ee48f415c9322bfc4220630e0a3b69e21cbeb69323788e1',
     '99e18c8f'),
    ('c9', '886f0e8d144d4fb01bef80ad49d6e815aa37252ea57062fd54f86804870fea5d61001b2770d8e5977579e1a23949729158196739ba73ab7ac0e6208cb889d893fe1d59be22ca01c005c4e46d63002c999115d36e80c020488e3614d099651799',
     '7a454861'),
    ('c2b', '255cf18bffcb23bb8f09bef0d6868e3b3b50d537932fb7122f5606ee74ee6270266c30badda9140e0c7337ee7dc3caaf9b730af85b76aed54453e0e2205ab541999d010e60d4192d41baba97efddffeb32eadd9d3585e09454be8d1bc83b54d0',
     'd969c557b4779591b1d587e9e5aa18f3'),
    ('c3b', '282948be3104d3ddda676e6e59677ecd0602e0f0072d15aba08a398f2afee701d91a2e472078d1caa272b965558325984dba840ee7a180a421665eb8169afd1ed15fe8db429964448b8f3c47835cd44f57f1b4b9e66dce672b13d6798017b4fc',
     'bb4ac26c'),
]


def ks(key, iv, skip, n):
    e = Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()
    if skip:
        e.update(b'\x00' * skip)
    return e.update(b'\x00' * n)


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


def hx(b):
    return b.hex()


for name, up, dn in PAIRS:
    if len(up) % 2:
        up = up[:-1]
    blob = bytes.fromhex(up)
    init, rest = blob[:64], blob[64:]
    key, iv = init[8:40], init[40:56]
    rev = init[8:56][::-1]
    rkey, riv = rev[:32], rev[32:]
    tag = xor(init[56:64], ks(key, iv, 56, 8))
    up_plain = xor(rest, ks(key, iv, 64, len(rest)))
    print(f'== {name}: tag={tag[:4].hex()} dc={struct.unpack("<h", tag[4:6])[0]}')
    if up_plain:
        m = up_plain[0]
        if m & 0x7f == 0x7f:
            ln = int.from_bytes(up_plain[1:4], 'little') * 4
            body = up_plain[4:4 + ln]
            print(f'  UP marker=0x{m:02x} long len={ln} key_id={hx(body[:8])} '
                  f'msg_key={hx(body[8:24])}')
        else:
            ln = (m & 0x7f) * 4
            body = up_plain[1:1 + ln]
            print(f'  UP marker=0x{m:02x} qa={bool(m & 0x80)} len={ln} '
                  f'key_id={hx(body[:8])} msg_key={hx(body[8:24])}')
    dn = bytes.fromhex(dn)
    for skip in (0, 64):
        p = xor(dn, ks(rkey, riv, skip, len(dn)))
        m = p[0]
        ln = (m & 0x7f) * 4 if m & 0x7f != 0x7f else -1
        print(f'  DN skip={skip}: {hx(p)} marker=0x{m:02x} qa={bool(m & 0x80)} '
              f'len={ln}' + (f' key_id={hx(p[1:9])}' if len(p) >= 9 else ''))
