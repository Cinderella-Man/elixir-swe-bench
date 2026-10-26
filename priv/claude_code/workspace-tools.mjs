// Runs one workspace tool call with Pi 1.2.0's own read, bash, edit and write tools,
// through Pi's argument preparation, schema validation and execution. The Claude Code
// harness therefore gets Pi's truncation, edit matching and error text unchanged.
// stdin: one JSON line, {"name": ..., "arguments": {...}} or {"list": true}.
// stdout: the result as one JSON line. The controller's exec cannot close stdin, so the
// request ends at its newline.
import { createAllToolDefinitions } from '/opt/pi/node_modules/@earendil-works/pi-coding-agent/dist/core/tools/index.js';
import { wrapToolDefinition } from '/opt/pi/node_modules/@earendil-works/pi-coding-agent/dist/core/tools/tool-definition-wrapper.js';
import { runToolCall } from '/opt/pi/node_modules/@earendil-works/pi-agent-core/dist/index.js';

const cwd = '/workspace';
const names = ['read', 'bash', 'edit', 'write'];
// Matches the benchmark's Pi configuration: shellPath is the hang-guard watchdog and the
// model is text-only, so images are described but never sent.
const definitions = createAllToolDefinitions(cwd, {
  bash: { shellPath: '/opt/pi/bash-watchdog.mjs', exposeSessionEnvironment: false },
});
const tools = names.map((name) =>
  wrapToolDefinition(definitions[name], () => ({ cwd, model: { input: ['text'] } })));
const request = await new Promise((resolve, reject) => {
  let buffer = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    buffer += chunk;
    const end = buffer.indexOf('\n');
    if (end !== -1) {
      process.stdin.pause();
      try { resolve(JSON.parse(buffer.slice(0, end))); } catch (error) { reject(error); }
    }
  });
  process.stdin.on('end', () => reject(new Error('Incomplete tool request')));
});
const reply = (value) => process.stdout.write(JSON.stringify(value) + '\n', () => process.exit(0));

if (request.list) {
  reply(tools.map((tool) => ({
    name: tool.name, description: tool.description,
    inputSchema: JSON.parse(JSON.stringify(tool.parameters)),
  })));
} else {
  if (!(Number(process.env.EAB_BASH_TIMEOUT_SECONDS) > 0)) throw new Error('Missing bash timeout');
  const toolCall = { type: 'toolCall', id: 'eab-tool-call', name: request.name, arguments: request.arguments ?? {} };
  const assistantMessage = { role: 'assistant', content: [toolCall] };
  const { result, isError } = await runToolCall(toolCall, {
    assistantMessage, context: { systemPrompt: '', messages: [], tools }, tools,
  });
  const content = (result.content || []).filter((block) => block.type === 'text');
  reply({ content, isError: isError === true });
}
