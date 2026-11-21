// Minimal DOM for running SillyTavern's original frontend modules headlessly.
//
// The upstream modules are written against a browser page. They need a real
// enough DOM to parse index.html, resolve selectors, and attach handlers — but
// no rendering. SwiftUI owns the visible UI; this DOM is inert scaffolding that
// lets the original logic run unmodified.
import fs from 'node:fs';
import path from 'node:path';
import { Window } from 'happy-dom';

export function loadDomEnvironment({ url, coreRoot }) {
    const htmlPath = path.join(coreRoot, 'public/index.html');
    const html = fs.readFileSync(htmlPath, 'utf8');

    const window = new Window({
        url,
        width: 1440,
        height: 900,
        settings: {
            disableJavaScriptFileLoading: true,
            disableCSSFileLoading: true,
            disableComputedStyleRendering: true,
            disableErrorCapturing: true,
            navigation: { disableChildFrameNavigation: true, disableMainFrameNavigation: true },
        },
    });
    window.document.write(html);

    const g = globalThis;
    const define = (key, value) =>
        Object.defineProperty(g, key, { value, writable: true, configurable: true, enumerable: true });

    define('window', window);
    define('document', window.document);
    define('navigator', window.navigator);
    define('location', window.location);
    define('history', window.history);

    const copy = [
        'localStorage', 'sessionStorage', 'HTMLElement', 'Element', 'Node', 'Event', 'CustomEvent',
        'MouseEvent', 'KeyboardEvent', 'DOMParser', 'FormData', 'Blob', 'File', 'FileReader',
        'ResizeObserver', 'IntersectionObserver', 'MutationObserver', 'URL', 'Headers', 'Request',
        'Response', 'TextEncoder', 'TextDecoder', 'HTMLCanvasElement', 'CSS', 'DragEvent',
        'WheelEvent', 'FocusEvent', 'InputEvent', 'PointerEvent', 'TouchEvent', 'EventTarget',
        'DocumentFragment', 'Text', 'Comment', 'Range', 'Selection', 'ProgressEvent',
        'XMLSerializer', 'HTMLOptionElement',
    ];
    for (const key of copy) {
        if (window[key] !== undefined) define(key, window[key]);
    }

    define('getComputedStyle', window.getComputedStyle.bind(window));
    define('requestAnimationFrame', (callback) => setTimeout(() => callback(Date.now()), 16));
    define('cancelAnimationFrame', (id) => clearTimeout(id));
    define('alert', () => {});
    const matchMedia = (query) => ({
        matches: false, media: query, addListener() {}, removeListener() {},
        addEventListener() {}, removeEventListener() {},
    });
    define('matchMedia', matchMedia);
    window.matchMedia = matchMedia;

    // Constructors a real page has but some DOM implementations omit.
    for (const [name, factory] of Object.entries(LEGACY_CONSTRUCTORS)) {
        if (typeof window[name] === 'undefined') {
            define(name, factory(window));
            window[name] = g[name];
        }
    }
    // Inert media APIs: no playback or capture happens in the engine.
    if (typeof g.URL.createObjectURL !== 'function') {
        define('URL', g.URL ?? window.URL);
    }
    try { g.URL.createObjectURL = () => 'blob:engine'; g.URL.revokeObjectURL = () => {}; } catch {}

    return { window, html };
}

const LEGACY_CONSTRUCTORS = {
    Option: (window) => function Option(text = '', value = '', defaultSelected = false, selected = false) {
        const element = window.document.createElement('option');
        element.text = text;
        element.value = value;
        element.defaultSelected = defaultSelected;
        element.selected = selected;
        return element;
    },
    Image: (window) => function Image(width, height) {
        const element = window.document.createElement('img');
        if (width !== undefined) element.width = width;
        if (height !== undefined) element.height = height;
        return element;
    },
    Audio: (window) => function Audio(src) {
        const element = window.document.createElement('audio');
        if (src) element.src = src;
        return element;
    },
};
