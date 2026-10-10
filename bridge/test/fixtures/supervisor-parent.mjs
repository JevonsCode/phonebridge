import { DesktopSupervisor } from '../../dist/supervisor.js';
const supervisor = new DesktopSupervisor({ token: process.env.PHONEBRIDGE_TOKEN, port: 0 });
const url = await supervisor.start();
process.send({ url, pid: supervisor.managedProcessId });
process.on('disconnect', () => void supervisor.close().then(() => process.exit(0)));
