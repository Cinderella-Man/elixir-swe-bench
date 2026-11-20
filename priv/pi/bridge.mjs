// Transport only: Pi owns its agent loop and tools. Elixir owns endpoint access
// and budgets. JSON lines over docker exec let the workspace stay network=none.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const config = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const root = dirname(fileURLToPath(import.meta.url));
const pending = new Map();
let sequence = 0;
let child;
const emit = (frame) => process.stdout.write(JSON.stringify(frame) + '\n');
const fail = (error) => {
  emit({type: 'fatal', message: String(error.message || error)});
  if (child?.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
  process.exit(1);
};
process.on('uncaughtException', fail);
process.on('unhandledRejection', fail);
if (!(config.bash_timeout_seconds > 0)) fail(new Error('Missing bash timeout'));

// Pi's events are per-token deltas and messages, kept within the controller's 16 MiB line
// limit. A controller record carries a whole model reply as streamed: one reply may fill
// the context window (ADR 0016), and its stream runs to 200-odd bytes per token, so a
// 262,144-token window needs about 64 MiB. Replies are capped only below V8's string limit.
const EVENT_LIMIT = 16 * 1024 * 1024;
const REPLY_LIMIT = 500 * 1024 * 1024;

function lines(stream, limit, callback) {
  let parts = [];
  let size = 0;
  stream.setEncoding('utf8');
  stream.on('data', (data) => {
    // Search only the new data, so a long record is read in linear time.
    let start = 0;
    let end;
    while ((end = data.indexOf('\n', start)) !== -1) {
      parts.push(data.slice(start, end));
      const line = parts.join('');
      parts = [];
      size = 0;
      start = end + 1;
      if (line.trim()) callback(JSON.parse(line));
    }
    if (start < data.length) {
      parts.push(data.slice(start));
      size += data.length - start;
    }
    if (size > limit) throw new Error('Oversized protocol record');
  });
  stream.on('end', () => { if (parts.join('').trim()) fail(new Error('Incomplete protocol record')); });
}

lines(process.stdin, REPLY_LIMIT, (reply) => {
  const response = pending.get(reply.id);
  if (!response) throw new Error('Unknown model request');
  pending.delete(reply.id);
  response.writeHead(reply.status, {'content-type': reply.content_type});
  response.end(reply.body);
});
process.stdin.on('end', () => fail(new Error('Controller disconnected')));

const server = createServer(async (request, response) => {
  let size = 0;
  const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 16 * 1024 * 1024) { response.writeHead(413).end(); return; }
    chunks.push(chunk);
  }
  const id = String(++sequence);
  pending.set(id, response);
  emit({type: 'request', id, method: request.method,
    path: new URL(request.url, 'http://localhost').pathname,
    body: JSON.parse(Buffer.concat(chunks).toString('utf8'))});
});
server.requestTimeout = 0;
server.listen(0, '127.0.0.1', () => {
  const agentDir = mkdtempSync(join(tmpdir(), 'eab-pi-'));
  const providerName = config.provider || 'benchmark';
  const provider = config.models.providers[providerName];
  provider.baseUrl = `http://127.0.0.1:${server.address().port}${config.api_prefix}`;
  writeFileSync(join(agentDir, 'models.json'), JSON.stringify(config.models));
  writeFileSync(join(agentDir, 'settings.json'), JSON.stringify(config.settings));
  // One Pi process runs per isolated workspace. Keep this model-visible path
  // stable across fresh attempts; only private Pi configuration needs a random directory.
  const prompt = join(tmpdir(), 'eab-ticket.md');
  const instructions = join(agentDir, 'instructions.md');
  writeFileSync(prompt, config.prompt);
  writeFileSync(instructions, config.instructions);
  child = spawn(process.execPath, [
    join(root, 'node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js'),
    '--mode', 'json', '--no-session', '--provider', providerName, '--model', config.model,
    '--tools', 'read,bash,edit,write',
    '--no-extensions', '--no-mcp', '--no-skills', '--no-prompt-templates',
    '--no-themes', '--no-approve', '--offline',
    '--append-system-prompt', instructions, `@${prompt}`
  ], {
    cwd: process.cwd(), detached: true, stdio: ['ignore', 'pipe', 'pipe'],
    env: {...process.env, PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: '1', PI_TELEMETRY: '0',
      EAB_BASH_TIMEOUT_SECONDS: String(config.bash_timeout_seconds)}
  });
  child.on('error', fail);
  lines(child.stdout, EVENT_LIMIT, (event) => emit({type: 'event', event}));
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (text) => emit({type: 'diagnostic', text}));
  child.on('close', (code, signal) => {
    emit({type: 'exit', code, signal});
    server.closeAllConnections();
    server.close();
    process.stdin.destroy();
    process.exitCode = code ?? 1;
  });
});
