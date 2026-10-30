import { lstatSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute } from 'node:path';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';

const phone = z.object({ id: z.string().min(1).max(120), name: z.string().min(1).max(120),
  alias: z.string().min(1).max(80).optional(),
  registrationId: z.string().uuid().optional(), paused: z.boolean(), removed: z.boolean() }).strict();
type Phone = z.infer<typeof phone>;
export type PhoneAction = 'rename' | 'disconnect' | 'resume' | 'delete';

/** Local display and connection preferences, independent of the shared credential. */
export class PhoneDirectory {
  private records = new Map<string, Phone>();
  constructor(private path?: string) {
    if (!path) return;
    if (!isAbsolute(path)) throw new Error('Phone directory requires an absolute path.');
    let info; try { info = lstatSync(path); } catch (e) { if ((e as NodeJS.ErrnoException).code === 'ENOENT') return; throw e; }
    if (!info.isFile() || info.isSymbolicLink() || info.size > 4 * 1024 * 1024 ||
        (process.platform !== 'win32' && info.uid !== process.getuid?.())) throw new Error('Invalid phone directory.');
    const saved = z.object({ version: z.literal(1), phones: z.array(phone) }).strict().parse(JSON.parse(readFileSync(path, 'utf8')));
    if (new Set(saved.phones.map(p => p.id)).size !== saved.phones.length) throw new Error('Duplicate phone identity.');
    this.records = new Map(saved.phones.map(p => [p.id, p]));
  }
  get(id: string): Phone | undefined { const p = this.records.get(id); return p ? { ...p } : undefined; }
  list(): Phone[] { return [...this.records.values()].filter(p => !p.removed).map(p => ({ ...p })); }
  remember(id: string, name: string, registrationId?: string): 'allowed' | 'paused' | 'removed' {
    const old = this.records.get(id);
    const repairing = !!registrationId && !!old && registrationId !== old.registrationId;
    if (old?.removed && !repairing) return 'removed';
    if (old?.paused && !repairing) return 'paused';
    const next = phone.parse({ ...old, id, name,
      ...(registrationId ? { registrationId } : {}), paused: false, removed: false,
      ...(old?.removed ? { alias: undefined } : {}) });
    if (JSON.stringify(old) !== JSON.stringify(next)) this.save(new Map(this.records).set(id, next));
    return 'allowed';
  }
  update(id: string, action: PhoneAction, name?: string): void {
    const old = this.records.get(id); if (!old || old.removed) throw new Error('Unknown phone.');
    const next = { ...old };
    if (action === 'rename') {
      const value = name?.trim();
      if (!value || value.length > 80 || /[\x00-\x1f\x7f]/u.test(value)) throw new Error('Enter a phone name of up to 80 characters.');
      next.alias = value;
    } else if (action === 'disconnect') next.paused = true;
    else if (action === 'resume') next.paused = false;
    else if (action === 'delete') { next.removed = true; next.paused = true; next.alias = undefined; next.name = 'Phone'; }
    this.save(new Map(this.records).set(id, next));
  }
  private save(next: Map<string, Phone>): void {
    if (this.path) {
      const parent = dirname(this.path); mkdirSync(parent, { recursive: true, mode: 0o700 });
      const info = lstatSync(parent); if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Invalid phone directory parent.');
      const temporary = `${this.path}.${randomUUID()}.tmp`;
      try { writeFileSync(temporary, JSON.stringify({ version: 1, phones: [...next.values()] }), { flag: 'wx', mode: 0o600 }); renameSync(temporary, this.path); }
      finally { try { unlinkSync(temporary); } catch (e) { if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e; } }
    }
    this.records = next;
  }
}
