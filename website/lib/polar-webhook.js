const crypto = require('crypto');

function verifyWebhookSignature({ secret, headers, rawBody, nowMs = Date.now() }) {
    const lookup = (name) => {
        if (!headers) return undefined;
        if (typeof headers.get === 'function') return headers.get(name);
        const key = Object.keys(headers).find((item) => item.toLowerCase() === name);
        return key ? headers[key] : undefined;
    };
    const id = lookup('webhook-id');
    const timestamp = lookup('webhook-timestamp');
    const signature = lookup('webhook-signature');
    if (!secret || !id || !timestamp || !signature || rawBody == null) return { ok: false, reason: 'MISSING_HEADERS' };
    if (!/^\d+$/.test(String(timestamp))) return { ok: false, reason: 'BAD_TIMESTAMP' };
    const seconds = Number(timestamp);
    if (!Number.isFinite(seconds)) return { ok: false, reason: 'BAD_TIMESTAMP' };
    if (Math.abs(nowMs / 1000 - seconds) > 300) return { ok: false, reason: 'STALE' };
    const body = Buffer.isBuffer(rawBody) ? rawBody.toString('utf8') : String(rawBody);
    const signed = `${id}.${timestamp}.${body}`;
    const candidates = [Buffer.from(secret, 'utf8')];
    if (secret.startsWith('whsec_')) {
        const decoded = Buffer.from(secret.slice(6), 'base64');
        if (decoded.length) candidates.push(decoded);
    }
    const signatures = String(signature).split(/\s+/).map((part) => part.match(/^v1,([A-Za-z0-9+/=]+)$/)).filter(Boolean).map((match) => Buffer.from(match[1], 'base64'));
    for (const candidate of candidates) {
        const expected = crypto.createHmac('sha256', candidate).update(signed).digest();
        for (const provided of signatures) {
            if (provided.length === expected.length && crypto.timingSafeEqual(provided, expected)) return { ok: true };
        }
    }
    return { ok: false, reason: 'BAD_SIGNATURE' };
}

module.exports = { verifyWebhookSignature };
