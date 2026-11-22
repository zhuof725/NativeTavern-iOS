// Streaming OpenAI-compatible mock, to verify the core's SSE path headlessly.
import http from 'node:http';

export function startStreamingMockModel({ chunks = ['MOCK', '_STREAM', '_REPLY'] } = {}) {
    const server = http.createServer((request, response) => {
        let body = '';
        request.on('data', (chunk) => { body += chunk; });
        request.on('end', () => {
            if (!request.url?.includes('/chat/completions')) {
                response.writeHead(404).end();
                return;
            }
            server.lastRequest = { url: request.url, headers: request.headers, body: safeParse(body) };
            response.writeHead(200, {
                'content-type': 'text/event-stream',
                'cache-control': 'no-cache',
                connection: 'keep-alive',
            });
            for (const content of chunks) {
                response.write(`data: ${JSON.stringify({
                    id: 'mock-stream',
                    object: 'chat.completion.chunk',
                    created: Math.floor(Date.now() / 1000),
                    model: 'mock-model',
                    choices: [{ index: 0, delta: { content }, finish_reason: null }],
                })}\n\n`);
            }
            response.write(`data: ${JSON.stringify({
                id: 'mock-stream',
                object: 'chat.completion.chunk',
                created: Math.floor(Date.now() / 1000),
                model: 'mock-model',
                choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
            })}\n\n`);
            response.write('data: [DONE]\n\n');
            response.end();
        });
    });
    return new Promise((resolve) => {
        server.listen(0, '127.0.0.1', () => {
            const { port } = server.address();
            resolve({
                url: `http://127.0.0.1:${port}`,
                close: () => new Promise((done) => server.close(() => done())),
                lastRequest: () => server.lastRequest,
            });
        });
    });
}

const safeParse = (text) => {
    try { return JSON.parse(text); } catch { return text; }
};
