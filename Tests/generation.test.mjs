// Proves the engine can produce a real model reply by running upstream's own
// generation path, with a local OpenAI-compatible mock standing in for a provider.
import path from 'node:path';
import { startMockModel } from './support/mock-model.mjs';
import { installResolversAndBoot } from './support/engine-harness.mjs';

const results = [];
const check = (name, pass, detail = '') => {
    results.push({ name, pass });
    console.log(`${pass ? 'PASS' : 'FAIL'} ${name}${detail ? ' :: ' + detail : ''}`);
};

const model = await startMockModel();
const harness = await installResolversAndBoot();

try {
    // Point upstream at the mock provider, exactly as the settings UI would.
    await harness.call('settings.update', {
        patch: {
            chat_completion_source: 'custom',
            custom_url: model.url,
            custom_model: 'mock-model',
            openai_max_context: 8192,
            openai_max_tokens: 300,
            stream_openai: false,
        },
    });

    await harness.call('character.setName', { name: 'Seraphina' });
    await harness.call('chat.load', {
        messages: [{ name: 'User', is_user: true, mes: 'Anything on the road tonight?' }],
    });

    const reply = await harness.call('generate.reply', { type: 'normal' });
    const text = (reply?.messages ?? []).map((m) => m.content).join('\n');
    check('generation produced a reply', text.includes('MOCK_REPLY'), text.slice(0, 80));

    const request = model.lastRequest();
    check('engine called the model', !!request, request?.url ?? 'no request');
    const sent = request?.body?.messages ?? [];
    check('request carried upstream-built messages', Array.isArray(sent) && sent.length > 0, `${sent.length} messages`);
    check('request included the chat turn', JSON.stringify(sent).includes('road tonight'));
} finally {
    await model.close();
    await harness.shutdown();
}

const failed = results.filter(r => !r.pass).length;
console.log(`\nSUMMARY: ${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
