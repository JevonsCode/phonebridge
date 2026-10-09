import http from 'node:http';
import { randomBytes } from 'node:crypto';
import QRCode from 'qrcode';
import { validateToken } from './protocol.js';

/** This URI only fills the phone form. It never grants phone permissions. */
export function pairingUri(endpoint: string, token: string): string {
  validateToken(token);
  const url = new URL(endpoint);
  if (!['ws:', 'wss:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.search || url.hash || url.pathname !== '/device' || endpoint.length > 1024) {
    throw new Error('Pairing endpoint must be a ws/wss /device URL without credentials, query or fragment.');
  }
  return `phonebridge://pair?${new URLSearchParams({ v: '1', endpoint: url.href, token })}`;
}

/** Loopback-only, uncached display available while the hub runs. */
export async function startPairingDisplay(endpoint: string, token: string): Promise<{ url: string; close: () => Promise<void> }> {
  const qr = await QRCode.toDataURL(pairingUri(endpoint, token), { width: 480, margin: 4, errorCorrectionLevel: 'M' });
  const path = `/pair/${randomBytes(24).toString('base64url')}`;
  let authority = '';
  const html = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>PhoneBridge 配对</title><style>body{font:18px system-ui,sans-serif;max-width:680px;margin:32px auto;padding:0 24px;background:#f5f7fb;color:#162334}h1{font-size:30px}img{width:min(100%,480px);height:auto}p{line-height:1.7}.note{color:#526174;font-size:15px}</style><h1>连接你的手机</h1><p>打开 PhoneBridge，点击「扫码配对」，扫描下方二维码。</p><img alt="PhoneBridge 私人配对二维码" src="${qr}"><p>手机检查地址并确认连接。默认只读；操作开关由你在手机上开启。</p><p class="note">二维码含配对密钥，请勿分享或截图上传。此页面在电脑端服务运行期间一直有效；更换密钥才会撤销旧二维码。使用记住配对时，重启不会撤销授权。手机与电脑需在可互通的网络。</p></html>`;
  const server = http.createServer((req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Content-Security-Policy', "default-src 'none'; img-src data:; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'");
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    if (req.method !== 'GET' || req.url !== path || req.headers.host !== authority || req.headers.origin || (req.headers['sec-fetch-site'] && !['none', 'same-origin'].includes(String(req.headers['sec-fetch-site'])))) {
      res.writeHead(404); res.end(); return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Pairing display did not bind.');
  authority = `127.0.0.1:${address.port}`;
  return { url: `http://${authority}${path}`, close: () => new Promise<void>((resolve, reject) => { server.close(error => error ? reject(error) : resolve()); server.closeAllConnections(); }) };
}
