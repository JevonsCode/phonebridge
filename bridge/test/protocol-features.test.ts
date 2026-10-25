import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { BridgeError, parseCommand } from '../src/protocol.js';

test('clipboard, selectors, image taps and explicit renewal preserve their documented wire parameters', () => {
  const valid: Array<[string, Record<string, unknown>]> = [
    ['get_clipboard', {}], ['set_clipboard', { text: 'https://example.org/分享' }], ['set_clipboard', { text: '' }], ['set_clipboard', { text: '文'.repeat(5000) }],
    ['tap', { x: 1, y: 2 }], ['tap', { selector: { text: '发布笔记' } }],
    ['tap', { selector: { descriptionContains: 'Share', className: 'android.widget.Button', index: 1 } }],
    ['tap', { imageX: 40, imageY: 60, screenshotId: 'screenshot-1' }],
    ['renew_control', { controlId: randomUUID() }],
    ...['paste', 'copy', 'cut', 'select_all'].map(action => ['node_action', { nodeId: 'snapshot:1', action }] as [string, Record<string, unknown>]),
    ['node_action', { selector: { resourceId: 'app:id/input', textContains: 'Ready' }, action: 'paste' }],
  ];
  for (const [method, params] of valid) assert.deepEqual(parseCommand({ method, params }).params, params);
});

test('tap modes and node targets are exclusive, complete and never silently select an empty selector', () => {
  const invalid: Array<[string, Record<string, unknown>]> = [
    ['tap', {}], ['tap', { x: 1 }], ['tap', { y: 2 }],
    ['tap', { x: 1, y: 2, selector: { text: 'Send' } }],
    ['tap', { imageX: 1, imageY: 2 }], ['tap', { screenshotId: 's' }],
    ['tap', { imageX: 1, imageY: 2, screenshotId: 's', x: 3, y: 4 }],
    ['tap', { imageX: 1, imageY: 2, screenshotId: 's', selector: { text: 'Send' } }],
    ['tap', { imageX: -1, imageY: 2, screenshotId: 's' }],
    ['tap', { selector: {} }], ['tap', { selector: { index: 0 } }],
    ['tap', { selector: { text: '' } }], ['tap', { selector: { text: 'Send', index: -1 } }],
    ['tap', { selector: { text: 'Send', extra: 'ignored?' } }],
    ['node_action', { action: 'paste' }],
    ['node_action', { action: 'paste', nodeId: 'node-1', selector: { text: 'Input' } }],
    ['get_clipboard', { text: 'ignored?' }],
  ];
  for (const [method, params] of invalid) assert.throws(() => parseCommand({ method, params }), (error: BridgeError) => error.code === 'INVALID_PARAMS', JSON.stringify({ method, params }));
  assert.throws(() => parseCommand({ method: 'renew_control', params: { controlId: randomUUID() }, controlId: randomUUID() }), (error: BridgeError) => error.code === 'INVALID_PARAMS');
});
