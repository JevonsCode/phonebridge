import { spawn } from 'node:child_process';
import { join, dirname, resolve, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { lstat, realpath } from 'node:fs/promises';
import { readMacConfig } from './macos/lifecycle.mjs';

export async function mcpTarget(configFile, uid = process.getuid?.()) {
  const config = await readMacConfig(configFile, uid);
  const entry = join(config.projectRoot, 'bridge', 'dist', 'mcp.js');
  for (const path of [config.nodePath, entry]) if (!(await lstat(path)).isFile()) throw new Error('Missing installed MCP runtime.');
  const credential = config.credentialFile ?? join(dirname(configFile), 'pairing.json');
  if (!isAbsolute(credential) || /[\r\n\0]/.test(credential)) throw new Error('Invalid credential path.');
  const env = { ...process.env, PHONEBRIDGE_URL: `http://${config.hostAddress}:${config.port}`, PHONEBRIDGE_CREDENTIAL_FILE: credential, PHONEBRIDGE_DESKTOP_CONFIG: configFile };
  delete env.PHONEBRIDGE_TOKEN; delete env.NODE_OPTIONS; delete env.NODE_PATH;
  return { command: config.nodePath, args: [entry], cwd: config.projectRoot, env };
}
export async function runMcp(configFile) {
  const target = await mcpTarget(configFile);
  const child = spawn(target.command, target.args, { cwd: target.cwd, env: target.env, stdio: 'inherit' });
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
  return new Promise((done, reject) => { child.once('error', reject); child.once('exit', (code, signal) => done(code ?? (signal === 'SIGINT' ? 130 : 143))); });
}
if (process.argv[1] && await realpath(resolve(process.argv[1])).catch(() => undefined) === fileURLToPath(import.meta.url)) {
  try { if (process.argv.length !== 3) throw new Error(); process.exitCode = await runMcp(resolve(process.argv[2])); }
  catch { console.error('PhoneBridge MCP could not start. Check the current-user desktop installation and configuration.'); process.exitCode = 1; }
}
