// Records which node_modules packages the engine actually loads at startup.
// Used to decide what must ship inside the app bundle.
import { register } from 'node:module';
import { fileURLToPath } from 'node:url';

register(new URL('./trace-hook.mjs', import.meta.url).href);
await import(fileURLToPath(new URL('../Engine/boot.mjs', import.meta.url)));
