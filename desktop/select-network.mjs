import { localNetworks } from './network.mjs';
const best = localNetworks()[0];
if (!best) process.exitCode = 1; else console.log(best.address);
