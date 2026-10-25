import { lstat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { spawn } from 'node:child_process';

/** Best-effort maintenance never blocks phone status or tears down a live MCP session. */
export function startLauncherMaintenance(configFile, { readConfig, intervalMs = 30000, run = spawn, platform = process.platform } = {}) {
  if (platform !== 'win32') return { tick: async () => false, close: async () => {} };
  let pending, stopping = false;
  const tick = () => {
    if (stopping) return Promise.resolve(false);
    if (pending) return pending;
    pending = (async () => {
      const marker = join(dirname(configFile), 'bin', 'PhoneBridgeMcp.pending.json');
      const info = await lstat(marker).catch(error => { if (error.code === 'ENOENT') return undefined; throw error; });
      if (!info?.isFile() || info.isSymbolicLink() || info.size > 32768) return false;
      const config = await readConfig();
      const helper = join(config.projectRoot, 'desktop', 'install-mcp-launcher.ps1');
      const helperInfo = await lstat(helper);
      if (!helperInfo.isFile() || helperInfo.isSymbolicLink()) return false;
      await new Promise((done, reject) => {
        const child = run(join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
          ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', helper, '--resume', configFile],
          { windowsHide: true, stdio: 'ignore' });
        const timer = setTimeout(() => { child.kill(); done(); }, 12000);
        child.once('error', error => { clearTimeout(timer); reject(error); });
        child.once('exit', () => { clearTimeout(timer); done(); });
      });
      return true;
    })().catch(() => false).finally(() => { pending = undefined; });
    return pending;
  };
  const timer = setInterval(() => { void tick(); }, intervalMs);
  timer.unref();
  void tick();
  return { tick, async close() { stopping = true; clearInterval(timer); await pending; } };
}
