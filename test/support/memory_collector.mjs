// Deterministic stream fixture: no hardware or model requests.
const mode = process.argv[2];
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const sample = (n, gpu, ram) => ({
  type: 'sample', at: `2026-10-18T00:00:0${n}Z`, monotonic_ms: n * 1000,
  vram_bytes: gpu, service_ram_bytes: ram, process_rss_bytes: ram, combined_bytes: gpu + ram,
  gpus: [{uuid: 'gpu-test', name: 'Fixture', capacity_bytes: 1000, used_bytes: gpu}]
});
let buffer = '', started = false;
process.stdin.setEncoding('utf8');
process.stdin.on('data', text => {
  buffer += text;
  while (buffer.includes('\n')) {
    buffer = buffer.slice(buffer.indexOf('\n') + 1);
    if (!started) {
      started = true;
      if (mode === 'ssh_error') {
        process.stdout.write('Host key verification failed.\r\n');
        process.exit(255);
      }
      if (mode === 'startup_error') {
        emit({type: 'error', message: 'Model identity changed'});
        process.exit(1);
      }
      emit({type: 'ready', identity: {host: 'fixture', service: 'model.service',
        model_artifact: 'fixture-Q4_K_M.gguf', context_tokens: 262144, backend: 'strata',
        backend_version: 'fixture', cpu: 'fixture', kv_cache: 'int8'}});
      emit(sample(1, 100, 20));
      if (mode === 'disconnect') process.exit(1);
    } else {
      emit(sample(mode === 'gap' ? 8 : 2, 30, 80));
      emit({type: 'stopped'});
      process.exit(0);
    }
  }
});
