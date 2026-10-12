import { lstat, mkdir, readFile, writeFile, link, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';

export async function installMcpLauncher(stateDirectory, uid = process.getuid?.()) {
  const directory = join(stateDirectory, 'bin');
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const stat = await lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid || (stat.mode & 0o077)) throw new Error('Invalid stable MCP directory.');
  const destination = join(directory, 'phonebridge-mcp');
  const source = await readFile(new URL('./phonebridge-mcp.sh', import.meta.url), 'utf8');
  try {
    const info = await lstat(destination);
    if (!info.isFile() || info.isSymbolicLink() || info.uid !== uid || (info.mode & 0o077) || await readFile(destination, 'utf8') !== source) throw new Error('An unrecognized stable MCP launcher was preserved.');
    return destination;
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const temporary = destination + '.tmp-' + randomBytes(8).toString('hex');
  try {
    await writeFile(temporary, source, { flag: 'wx', mode: 0o700 });
    await link(temporary, destination); // Exclusive atomic publication, no partial shell script.
  } finally { await unlink(temporary).catch(() => {}); }
  return destination;
}
