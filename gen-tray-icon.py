import struct, zlib

width, height = 32, 32
r, g, b, a = 0x1a, 0x73, 0xe8, 0xff

raw = b''
for _ in range(height):
    raw += b'\x00' + bytes([r, g, b, a]) * width

compressed = zlib.compress(raw)

def chunk(ctype, data):
    c = ctype + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)

png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', ihdr)
png += chunk(b'IDAT', compressed)
png += chunk(b'IEND', b'')

with open('/Users/benediktpoller/code/push2main.io/superheld/desktop/src/main/resources/tray-icon.png', 'wb') as f:
    f.write(png)

print('Done, wrote', len(png), 'bytes')
