// Minimal OpenAI-compatible mock, used to verify the engine's full generation
// path without a real provider account.
import http from 'node:http';

export function startMockModel({ reply = 'MOCK_REPLY: the pass is quiet tonight.' } = {}) {
    const server = http.createServer((request, response) => {
        let body = '';
        request.on('data', (chunk) => { body += chunk; });
        request.on('end', () => {
            if (!request.url?.includes('/chat/completions')) {
                response.writeHead(404).end();
                return;
            }
            // Record the request so tests can assert what the engine actually sent.
            server.lastRequest = { url: request.url, headers: request.headers, body: safeParse(body) };
            const payload = {
                id: 'mock-1',
                object: 'chat.completion',
                created: Math.floor(Date.now() / 1000),
                model: 'mock-model',
                choices: [{ index: 0, message: { role: 'assistant', content: reply }, finish_reason: 'stop' }],
                usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
            };
            response.writeHead(200, { 'content-type': 'application/json' });
            response.end(JSON.stringify(payload));
        });
    });
    return new Promise((resolve) => {
        server.listen(0, '127.0.0.1', () => {
            const { port } = server.address();
            resolve({
                url: `http://127.0.0.1:${port}`,
                server,
                lastRequest: () => server.lastRequest,
                close: () => new Promise((done) => server.close(() => done())),
            });
        });
    });
}

const safeParse = (text) => {
    try { return JSON.parse(text); } catch { return text; }
};
