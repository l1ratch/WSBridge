# Расшифровка uphead-дампов из журнала телефона: obfuscated2 init несёт
# ключ/iv открыто (байты 8:56), поэтому хвост первого чанка расшифровывается
# локально. Показывает тег транспорта, dc_idx и начало первого пакета.
import struct
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

UPHEADS = {
    'c0:1460': 'fbf8532a079af354edd2b5aab106ddf78063d43ce3a78045d737c9aaa4c8693ed4648e0a647b20761e9a73a7c8ba9c245339e6199eebecd9a7b2ccb44eb6051f885fd55e7601d448eaa45b7ed06ca2cf3ad767341b0aebded6ff9f30aec4fbf5',
    'c2:201': '1c2fe227a4019d760b495907a63cf95889b322edf228188a327a47549cffd1d2b10dceb5f249ac33303034b9f0d0a46f13dc768a6c84878ef43691947e41f19bce3d49143cd14e743029de8f77ce24329903faa703fa761fb8b96e3bf15bde79',
    'c11:377': '404df3379c98d530174639a08f302af1ffe795eacdcfa71a9725e8cb92e67ec7e537f9dc99f8e452180e92ed2660e42fc2054918ef7dcebeb4e21f805da56474bf62549e1dd670f0241e6adc9984901cd3fc1d71ebceec6f3dd09a406c51a203',
    'c14:201': '9d306e1ff1fc6930473291095bba6e6a55416ba6f6709477a95ceee946e999f73d49b4f3ff9c4a6b203af90789481048c3fb37506baf53329bf669c1986ebf77ebb40f2deb6bb4c47e155c11abde3eb65f5d9ea09caf400e667b4f5672142a4a',
    'c13:537': '6e93c1aafc66fe3b0c9fa5bbace5d2d5756e52ecd951dd28e253e7c6d238146cba09b75714e6dc885476d0d3c1c5283282c8d73b354f5d7be1d9c1fa8157cc0999ac9d47eeef4c0554f702aa2950e13478bfbfe5fbc7d742ef7bc6b7f43f56d7',
    'c12:185': '758766256d90c5724cddc352845c1842a0f9dc13681ff13852db4108ec84f920bc25ec68f5e723e48127ed441f83147f5c6ad6731f425c2b6458de9f498be980e7e37d7ebce2e1fda038f413148cc26e97774bb22bb191cc088ee17c3dbf7212',
    'c10:489': 'c472e9994486081a44065abef265a42953341196e41b5d1a571b7b7ccfe04c97cf7b0b964aecaf98deaec6baeaf712b6a5f5196b7cb987cba09cc85ba9e44c6af95369f5529c70502af1cd14f7d95f2ec233ee255bf114b476620420e4e9b0ab',
    'c8:409': 'f108539253c41c66a06c5f799bb4af6e74a6cc557b9f83f2265e6b29599ffd92a4a3686d640938081b6da4d32663297c838fdfd6cd934a3bd5ecf0dcdaf06483c028c818fb5f938c77673c98fafa6cfda8992a6ffb8d3c49215babc5f70bb88d',
    'c2b:473': '5fd3ce194faa51b9f2926239cd9866c3864571333866e7d71c96d91c8ac8e3d77acbd75d1db242ad9481a4f3233bda80554451fd315e7327714be185cd18477969638f4262640db5a5930bb25e9c8005397cbcc5f8eedbc93b91576c4ce977ca',
    'c11b:217': '616da0b3b72c4d040ac34164de7ed2b10af81a4cf5d13c81f993634e255e568bacca0401464896a37a3cbca8bcab4edc5cd11f4b1ef793bbfd27d5248962d9bd09d524ccdaa9a32ff42bc920247d85d3ce9775bbed801ba8a0bc741aeeb32889',
    'c13b:217': '5176446ffe64d1e55e72b75d467df8503149a479c14808eb2c48bcc53d22f6e2c89e11d0c934988e1a3993b4189cfc1e07ce4af755012db1f1ed3383784da2644afe68d5969c0f7fe64ef3f0b658ca5e771677618025c7cc79fd11c736245b4b',
    'c14b:297': 'b98b8e82e4ec564faf928057ce27bf614338f1ae625aab72d74af3d20e3a1284ecd89eee01d24cb370051f9b948ef4d7c0088f846751db1392d585355110e20e0f90f8e73593354bfdb8794fe6b94673fc11d47afba6fede7e395f542c664310',
}


def keystream(key, iv, skip, n):
    enc = Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()
    if skip:
        enc.update(b'\x00' * skip)
    return enc.update(b'\x00' * n)


for name, hexs in UPHEADS.items():
    blob = bytes.fromhex(hexs)
    init, rest = blob[:64], blob[64:]
    key, iv = init[8:40], init[40:56]
    # тег транспорта: init[56:64] XOR keystream[56:64]
    ks56 = keystream(key, iv, 56, 8)
    tail = bytes(a ^ b for a, b in zip(init[56:64], ks56))
    tag = tail[:4].hex()
    dc = struct.unpack('<h', tail[4:6])[0]
    # первый пакет: keystream с офсета 64
    plain = bytes(a ^ b for a, b in zip(rest, keystream(key, iv, 64, len(rest))))
    tagname = {'efefefef': 'ABRIDGED', 'eeeeeeee': 'INTERMEDIATE',
               'dddddddd': 'PADDED'}.get(tag, '???')
    print(f'{name}: tag={tag} {tagname} dc_idx={dc}')
    print(f'  first packet plain: {plain.hex()}')
    # abridged: 1-й байт = len/4
    if plain:
        b0 = plain[0]
        if b0 & 0x7f != 0x7f:
            ln = (b0 & 0x7f) * 4
            body = plain[1:1 + ln]
            if len(body) >= 4:
                print(f'  abridged frame: quickack={bool(b0 & 0x80)} len={ln} '
                      f'ctor=0x{struct.unpack_from("<I", body, 0)[0]:08x} '
              f'body[:{min(40, len(body))}]={body[:40].hex()}')
