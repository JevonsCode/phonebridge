import test from 'node:test';
import assert from 'node:assert/strict';
import { usbStatus } from '../server.mjs';

const config = { hostAddress: '127.0.0.1', port: 8767 };
const reply = (status, body) => async () => ({ status, ok: status >= 200 && status < 300, json: async () => body });

test('dashboard USB status forwards only sanitized phone fields', async () => {
  const value = await usbStatus(config, 'x'.repeat(43), { fetchImpl: reply(200, { available: true, adbFound: true, loopbackPort: 8767,
    phones: [{ serial: 'SER1', state: 'connected_usb', model: 'Pixel 9', appVersion: '0.9.0', token: 'secret' }, { serial: 3 }, null] }) });
  assert.deepEqual(value, { available: true, adbFound: true, phones: [{ serial: 'SER1', state: 'connected_usb', model: 'Pixel 9', appVersion: '0.9.0' }] });
});

test('an older background service without USB support is reported, not treated as an error', async () => {
  assert.deepEqual(await usbStatus(config, 'x'.repeat(43), { fetchImpl: reply(404, {}) }), { available: false, adbFound: false, phones: [], serviceOutdated: true });
  assert.deepEqual(await usbStatus(config, 'x'.repeat(43), { fetchImpl: async () => { throw new Error('down'); } }), { available: false, adbFound: false, phones: [] });
});
