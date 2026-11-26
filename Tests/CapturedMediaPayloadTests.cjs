const assert = require('node:assert/strict');
const test = require('node:test');
const { transform } = require(process.env.CAPTURED_PAYLOAD_MODULE || './Fixtures/CapturedMediaPayload.cjs');
function transportStream(prefix) {
  const bytes = new Uint8Array(prefix + 188 * 5);
  for (let packet = 0; packet < 5; packet++) bytes[prefix + packet * 188] = 0x47;
  return bytes;
}
test('plain MPEG-TS is forwarded unchanged', async () => {
  const bytes = transportStream(0);
  assert.deepEqual(Buffer.from(await transform(bytes)), Buffer.from(bytes));
});
test('V1 partial first packet is accepted without altering media bytes', async () => {
  const bytes = transportStream(159);
  assert.deepEqual(Buffer.from(await transform(bytes)), Buffer.from(bytes));
});
test('awaits the original preFlush callback before checking the payload', async () => {
  const bytes = transportStream(71);
  let completed = false;
  const output = await transform(bytes, async input => {
    await new Promise(resolve => setImmediate(resolve));
    completed = true;
    return input.subarray(71);
  });
  assert.equal(completed, true);
  assert.deepEqual(Buffer.from(output), Buffer.from(bytes.subarray(71)));
});
test('invalid payload is rejected', async () => {
  await assert.rejects(transform(new Uint8Array(1024)), /MPEG-TS/);
});
