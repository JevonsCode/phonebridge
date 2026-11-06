import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
const t = new StdioClientTransport({ command: "C:/Users/jevons/.phonebridge/bin/PhoneBridgeMcp.exe", args: [], env: process.env });
const c = new Client({ name: "jarvis", version: "1" }); await c.connect(t);
const [,, name, json] = process.argv;
if (!name) { const l = await c.listTools(); console.log(l.tools.map(x=>x.name+": "+JSON.stringify(x.inputSchema.properties||{})).join("\n")); }
else { const r = await c.callTool({ name, arguments: JSON.parse(process.env.PBARGS||json||"{}") }); for (const p of r.content) { if (p.type==="image") { const fs=await import("fs"); fs.writeFileSync(process.env.TEMP+"/pb.png", Buffer.from(p.data,"base64")); console.log("[image saved]"); } else console.log(p.text); } }
await c.close();


