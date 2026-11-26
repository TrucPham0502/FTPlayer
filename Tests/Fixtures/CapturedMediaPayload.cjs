// Test-fixture preprocessing only. No resolver, WebView or network client.
// Keep the historical framing/async contract independently of private sources.
async function transform(input, preFlush = value => value) {
  const decoded = Uint8Array.from(input);
  const output = Uint8Array.from(await preFlush(decoded));
  let transportStream = false;
  for (let offset = 0; offset < Math.min(188, output.length - 3 * 188); offset++) {
    if (output[offset] === 0x47 && output[offset + 188] === 0x47 &&
        output[offset + 376] === 0x47 && output[offset + 564] === 0x47) {
      transportStream = true;
      break;
    }
  }
  if (!transportStream) throw new Error('Payload is not MPEG-TS after preprocessing');
  return output;
}
module.exports = { transform };
