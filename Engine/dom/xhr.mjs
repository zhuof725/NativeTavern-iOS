// XMLHttpRequest backed by fetch.
//
// The environment's XHR does not perform network I/O, and SillyTavern's older
// paths (jQuery.ajax with async:false, the tokenizer counters) need one that
// actually talks to the backend. Everything the core issues therefore flows
// through one place, which is also where the transport adds its credentials.
export function installFetchXHR(window) {
    class FetchXMLHttpRequest {
        constructor() {
            this.readyState = 0;
            this.status = 0;
            this.statusText = '';
            this.responseText = '';
            this.response = '';
            this.responseType = '';
            this.timeout = 0;
            this.withCredentials = false;
            this.upload = { addEventListener() {}, removeEventListener() {} };
            this._headers = {};
            this._responseHeaders = {};
            this._listeners = {};
            this._aborted = false;
        }
        open(method, url) {
            this._method = String(method || 'GET').toUpperCase();
            this._url = String(url);
            this.readyState = 1;
            this._emit('readystatechange');
        }
        setRequestHeader(name, value) { this._headers[name] = value; }
        getAllResponseHeaders() {
            return Object.entries(this._responseHeaders).map(([key, value]) => `${key}: ${value}`).join('\r\n');
        }
        getResponseHeader(name) {
            const key = Object.keys(this._responseHeaders).find(k => k.toLowerCase() === String(name).toLowerCase());
            return key ? this._responseHeaders[key] : null;
        }
        addEventListener(type, fn) { (this._listeners[type] ??= []).push(fn); }
        removeEventListener(type, fn) {
            this._listeners[type] = (this._listeners[type] ?? []).filter(f => f !== fn);
        }
        _emit(type) {
            const event = { type, target: this, currentTarget: this };
            for (const fn of this._listeners[type] ?? []) fn.call(this, event);
            if (typeof this[`on${type}`] === 'function') this[`on${type}`].call(this, event);
        }
        abort() {
            this._aborted = true;
            this.readyState = 4;
            this._emit('abort');
            this._emit('loadend');
        }
        async _send(body) {
            const response = await globalThis.fetch(this._url, {
                method: this._method,
                headers: this._headers,
                body: this._method === 'GET' || this._method === 'HEAD' ? undefined : body,
            });
            const text = await response.text();
            this.status = response.status;
            this.statusText = response.statusText;
            this.readyState = 2;
            this._emit('readystatechange');
            response.headers.forEach((value, key) => { this._responseHeaders[key] = value; });
            this.responseText = text;
            this.response = this.responseType === 'json' ? safeJson(text) : text;
            this.readyState = 3;
            this._emit('readystatechange');
            this.readyState = 4;
            this._emit('readystatechange');
            this._emit('load');
            this._emit('loadend');
        }
        send(body) {
            this._send(body).catch(() => {
                if (this._aborted) return;
                this.status = 0;
                this.readyState = 4;
                this._emit('error');
                this._emit('loadend');
            });
        }
    }

    window.XMLHttpRequest = FetchXMLHttpRequest;
    globalThis.XMLHttpRequest = FetchXMLHttpRequest;
    return FetchXMLHttpRequest;
}

const safeJson = (text) => {
    try { return JSON.parse(text); } catch { return null; }
};
