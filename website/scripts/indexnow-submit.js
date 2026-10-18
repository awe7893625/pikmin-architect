const fs = require('fs');
const path = require('path');

const PUBLIC_DIR = path.join(__dirname, '..', 'public');

function parseSitemap(xml) {
    return [...String(xml).matchAll(/<loc>\s*([\s\S]*?)\s*<\/loc>/gi)].map((match) => match[1].trim()).filter(Boolean);
}

function findKey(publicDir = PUBLIC_DIR, keyOverride = process.env.INDEXNOW_KEY) {
    if (keyOverride) return keyOverride;
    const filename = fs.readdirSync(publicDir).find((name) => /^[0-9a-f]{32}\.txt$/.test(name));
    return filename ? filename.slice(0, -4) : null;
}

function buildPayload(urlList, key, host = 'konggoo.uk') {
    return { host, key, keyLocation: `https://${host}/${key}.txt`, urlList: [...urlList] };
}

async function main() {
    const urls = parseSitemap(fs.readFileSync(path.join(PUBLIC_DIR, 'sitemap.xml'), 'utf8'));
    const key = findKey();
    if (!key) throw new Error('IndexNow key not found');
    const payload = buildPayload(urls, key);
    if (process.argv.includes('--dry-run')) {
        console.log(JSON.stringify({ host: payload.host, keyLocation: payload.keyLocation, urlCount: payload.urlList.length, urlList: payload.urlList }, null, 2));
        return;
    }
    const response = await fetch('https://api.indexnow.org/indexnow', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
        body: JSON.stringify(payload)
    });
    const text = await response.text();
    console.log(`HTTP ${response.status}`);
    console.log(text);
    if (response.status !== 200 && response.status !== 202) process.exitCode = 1;
}

if (require.main === module) main().catch((error) => { console.error(error.message); process.exitCode = 1; });

module.exports = { parseSitemap, findKey, buildPayload };
