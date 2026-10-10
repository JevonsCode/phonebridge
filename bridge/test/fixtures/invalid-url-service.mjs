import { PhoneHub } from '../../src/hub.ts';
import { DesktopSupervisor } from '../../src/supervisor.ts';
import { MemoryOperationJournal } from '../../src/operation-journal.ts';

const service = process.env.TEST_SERVICE === 'hub'
  ? new PhoneHub({ token: process.env.PHONEBRIDGE_TOKEN, port: 0, journal: new MemoryOperationJournal() })
  : new DesktopSupervisor({ token: process.env.PHONEBRIDGE_TOKEN, port: 0, autoStart: false });
const url = await service.start();
process.send({ url });
process.on('disconnect', () => void service.close().finally(() => process.exit(0)));
