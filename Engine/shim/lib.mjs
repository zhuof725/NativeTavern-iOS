// Node-compatible replacement for SillyTavern's webpack-bundled public/lib.js.
// Uses the real upstream libraries wherever the frontend logic actually depends on them.
import lodash from 'lodash';
import Fuse from 'fuse.js';
import Handlebars from 'handlebars';
import moment from 'moment';
import seedrandom from 'seedrandom';
import droll from 'droll';
import * as chevrotain from 'chevrotain';
import hljs from 'highlight.js';
import showdown from 'showdown';
import morphdom from 'morphdom';
import Bowser from 'bowser';
import DiffMatchPatch from 'diff-match-patch';
import localforage from 'localforage';
import DOMPurify from 'dompurify';
import * as Popper from '@popperjs/core';
import { gzip, gzipSync } from 'fflate';
import { sha256 } from 'js-sha256';

const SVGInject = () => {};
const Readability = class { parse() { return { textContent: '', content: '' }; } };
const isProbablyReaderable = () => false;
const slideToggle = () => {};
const css = { parse: () => ({}), stringify: () => '' };

export {
    lodash, Fuse, Handlebars, moment, seedrandom, droll, chevrotain, hljs, showdown,
    morphdom, Bowser, DiffMatchPatch, localforage, DOMPurify, Popper, gzip, gzipSync,
    sha256, SVGInject, Readability, isProbablyReaderable, slideToggle, css,
};

export const libs = {
    lodash, Fuse, DOMPurify, hljs, localforage, Handlebars, css, Bowser, DiffMatchPatch,
    Readability, isProbablyReaderable, SVGInject, showdown, moment, seedrandom, Popper, droll,
    morphdom, slideToggle, chevrotain, gzip, sha256,
};

// Mirrors public/lib.js: expose the libraries on the browser global.
export function initLibraryShims() {
    if (typeof window === 'undefined' || !window) return;
    const map = {
        Fuse, DOMPurify, hljs, localforage, Handlebars, diff_match_patch: DiffMatchPatch,
        SVGInject, showdown, moment, Popper, droll, lodash, seedrandom, Bowser, chevrotain,
        morphdom,
    };
    for (const [key, value] of Object.entries(map)) {
        if (!(key in window)) window[key] = value;
    }
}

export default libs;
