// Libraries the original SillyTavern frontend imports through its Webpack entry
// (public/lib.js). Upstream bundles these at startup; a phone should not run a
// bundler at launch, so this module list is prebuilt once and shipped in the app.
//
// Keep this in sync with the named exports used by public/scripts/**.
export { default as lodash } from 'lodash';
export { default as Fuse } from 'fuse.js';
export { default as Handlebars } from 'handlebars';
export { default as moment } from 'moment';
export { default as seedrandom } from 'seedrandom';
export { default as droll } from 'droll';
export { default as hljs } from 'highlight.js';
export { default as showdown } from 'showdown';
export { default as morphdom } from 'morphdom';
export { default as Bowser } from 'bowser';
export { default as DiffMatchPatch } from 'diff-match-patch';
export { default as localforage } from 'localforage';
export { default as DOMPurify } from 'dompurify';
export * as chevrotain from 'chevrotain';
export * as Popper from '@popperjs/core';
export { gzip, gzipSync } from 'fflate';
export { sha256 } from './sha256.mjs';

// Upstream also exports these; the engine only needs them present.
export const SVGInject = () => {};
export class Readability {
    parse() { return { textContent: '', content: '' }; }
}
export const isProbablyReaderable = () => false;
export const slideToggle = () => {};
export const css = { parse: () => ({}), stringify: () => '' };

export function initLibraryShims() {
    if (typeof window === 'undefined' || !window) return;
    const globals = {
        Fuse, DOMPurify, hljs, localforage, Handlebars, diff_match_patch: DiffMatchPatch,
        SVGInject, showdown, moment, Popper, droll, lodash, seedrandom, Bowser, chevrotain, morphdom,
    };
    for (const [key, value] of Object.entries(globals)) {
        if (!(key in window)) window[key] = value;
    }
}

import lodash from 'lodash';
import Fuse from 'fuse.js';
import Handlebars from 'handlebars';
import moment from 'moment';
import seedrandom from 'seedrandom';
import droll from 'droll';
import hljs from 'highlight.js';
import showdown from 'showdown';
import morphdom from 'morphdom';
import Bowser from 'bowser';
import DiffMatchPatch from 'diff-match-patch';
import localforage from 'localforage';
import DOMPurify from 'dompurify';
import * as chevrotain from 'chevrotain';
import * as Popper from '@popperjs/core';
import { gzip, gzipSync } from 'fflate';
import { sha256 } from './sha256.mjs';

export const libs = {
    lodash, Fuse, DOMPurify, hljs, localforage, Handlebars, css, Bowser, DiffMatchPatch,
    Readability, isProbablyReaderable, SVGInject, showdown, moment, seedrandom, Popper, droll,
    morphdom, slideToggle, chevrotain, gzip, sha256,
};

export default libs;
