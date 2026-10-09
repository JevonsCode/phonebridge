import test from 'node:test';
import assert from 'node:assert/strict';
import { validateHubUrl } from '../src/hub-url.js';

test('HTTP MCP targets must be loopback or a literal IP owned by this computer', () => {
  const local = ['192.168.1.10', 'fe80::1234'];
  for (const value of ['http://127.0.0.1:8765', 'http://[::1]:8765', 'http://localhost:8765', 'http://192.168.1.10:8765', 'https://remote.example:8765']) assert.doesNotThrow(() => validateHubUrl(new URL(value), local));
  for (const value of ['http://192.168.1.11:8765', 'http://remote.example:8765', 'http://0.0.0.0:8765', 'ftp://localhost', 'http://user:pass@localhost', 'http://localhost/path', 'http://localhost/?secret=x']) assert.throws(() => validateHubUrl(new URL(value), local));
  assert.throws(() => validateHubUrl(new URL('http://192.168.1.10:8765'), []), 'an address no longer owned must be refused');
});
