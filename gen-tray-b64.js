const zlib = require('zlib');
const w = 32, h = 32;
const row = Buffer.alloc(1 + w * 4);
row[0] = 0;
for (let i = 0; i < w; i++) {
  row[1 + i * 4] = 0x1a;
  row[2 + i * 4] = 0x73;
  row[3 + i * 4] = 0xe8;
  row[4 + i * 4] = 0xff;
}
let raw = Buffer.alloc(0);
for (let i = 0; i < h; i++) raw = Buffer.concat([raw, row]);
const compressed = zlib.deflateSync(raw);

function calcCrc(buf) {
  let c = 0xffffffff;
  for (const b of buf) {
    c ^= b;
    for (let j = 0; j < 8; j++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(calcCrc(td));
  return Buffer.concat([len, td, crc]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(w, 0);
ihdr.writeUInt32BE(h, 4);
ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const png = Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', compressed), chunk('IEND', Buffer.alloc(0))]);
process.stdout.write(png.toString('base64'));
