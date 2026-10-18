'use strict';

const fs = require('fs');
const path = require('path');

const LANGS = [
    { code: 'zh-TW', path: '/', ogLocale: 'zh_TW', label: '繁中' },
    { code: 'ja', path: '/ja/', ogLocale: 'ja_JP', label: '日本語' },
    { code: 'ko', path: '/ko/', ogLocale: 'ko_KR', label: '한국어' },
    { code: 'en', path: '/en/', ogLocale: 'en_US', label: 'EN' },
    { code: 'zh-CN', path: '/zh-CN/', ogLocale: 'zh_CN', label: '简中' }
];

const KEYWORDS = {
    ja: 'iPhone 位置情報 変更, GPS シミュレーター, ポケモンGO 位置情報, ピクミンブルーム 位置情報, KongGoo',
    ko: '아이폰 위치 변경, GPS 시뮬레이터, 포켓몬고 GPS, 픽민 블룸 위치, KongGoo',
    en: 'iOS location simulator, iPhone GPS spoofer, Pikmin Bloom GPS, Pokemon GO location, KongGoo',
    'zh-CN': 'iOS 定位模拟器, iPhone GPS 位置修改, 宝可梦 Pokémon GO 定位, Pikmin Bloom 位置, KongGoo'
};
const ALTERNATE_NAMES = {
    'zh-TW': ['摃菇', 'KongGoo iOS GPS Simulator', 'iOS 定位模擬器', '寶可夢飛人工具', 'Pokemon GO GPS Spoofer'],
    ja: ['KongGoo', '摃菇', 'iPhone位置情報シミュレーター'],
    ko: ['KongGoo', '摃菇', '아이폰 위치 시뮬레이터'],
    en: ['摃菇', 'KongGoo iOS GPS Simulator', 'iOS location simulator'],
    'zh-CN': ['摃菇', 'KongGoo iOS GPS Simulator', 'iOS 定位模拟器', '宝可梦定位工具', 'Pokemon GO GPS Spoofer']
};
const APPROX_PRICES = {
    ja: ['≈ ¥3,300 / 年', '≈ ¥8,300'],
    ko: ['≈ ₩30,000 / 년', '≈ ₩76,000']
};

function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);
}
function plainText(value) { return String(value).replace(/<[^>]*>/g, '').replace(/&amp;/g, '&').trim(); }
function betweenMarkers(template, startMarker, endMarker, replacement) {
    const start = template.indexOf(startMarker);
    const end = template.indexOf(endMarker);
    if (start < 0 || end < start) throw new Error(`Missing or reversed markers ${startMarker}`);
    return template.slice(0, start) + replacement + template.slice(end + endMarker.length);
}
function jsonScript(value) { return JSON.stringify(value).replace(/</g, '\\u003c'); }

function createSeoRenderer({ publicDir, localesDir, siteUrl = 'https://konggoo.uk' }) {
    const cache = new Map();
    let templateCache;
    const baseUrl = siteUrl.replace(/\/$/, '');
    function load(code) {
        if (cache.has(code)) return cache.get(code);
        const lang = LANGS.find((entry) => entry.code === code);
        if (!lang) return null;
        if (templateCache === undefined) templateCache = fs.readFileSync(path.join(publicDir, 'index.html'), 'utf8');
        const template = templateCache;
        const locale = JSON.parse(fs.readFileSync(path.join(localesDir, `${code}.json`), 'utf8'));
        const record = { lang, template, locale };
        cache.set(code, record);
        return record;
    }
    function render(code) {
        const record = load(code);
        if (!record) throw new Error(`Unsupported language: ${code}`);
        const { lang, locale } = record;
        const self = `${baseUrl}${lang.path}`;
        let html = record.template.replace(/<html\b([^>]*)\blang="[^"]*"([^>]*)>/i, `<html$1lang="${escapeHtml(code)}"$2>`);

        html = html.replace(/<([a-z][\w:-]*)\b([^>]*\bdata-i18n="([^"]+)"[^>]*)>([\s\S]*?)<\/\1\s*>/gi,
            (whole, tag, attrs, key, inner) => Object.prototype.hasOwnProperty.call(locale, key)
                ? `<${tag}${attrs}>${escapeHtml(locale[key])}</${tag}>` : whole);
        html = html.replace(/(<input\b[^>]*\bid="demo-search"[^>]*\bplaceholder=")[^"]*(")/i,
            (whole, before, after) => locale.showcase_search ? `${before}${escapeHtml(locale.showcase_search)}${after}` : whole);

        const keywords = code === 'zh-TW'
            ? 'iOS 定位模擬器, iOS GPS 模擬, iPhone 定位修改, GPS spoof iOS, 位置模擬器, iPhone GPS 修改, 免越獄定位, 寶可夢飛人, Pokemon GO 飛人, Pokemon GO GPS, 寶可夢定位修改, 寶可夢外掛, PokeGo 位置, KongGoo, 摃菇, GPS faker, location simulator, 아이폰 위치 변경, 포켓몬고 GPS'
            : KEYWORDS[code];
        const alternates = LANGS.map((item) => `    <link rel="alternate" hreflang="${item.code}" href="${escapeHtml(baseUrl + item.path)}">`).join('\n') +
            `\n    <link rel="alternate" hreflang="x-default" href="${escapeHtml(baseUrl + '/')}">`;
        const otherLocales = LANGS.filter((item) => item.code !== code)
            .map((item) => `    <meta property="og:locale:alternate" content="${item.ogLocale}">`).join('\n');
        const head = `<!--SEO:HEAD-->\n    <meta name="google-site-verification" content="viPFlClvYG80IBjMMqtl9ErtKg-Bpw3ZgNWjsrFSli8" />\n    <title>${escapeHtml(locale.meta_title)}</title>\n    <meta name="description" content="${escapeHtml(locale.meta_desc)}">\n    <meta name="keywords" content="${escapeHtml(keywords)}">\n    <meta property="og:title" content="${escapeHtml(locale.meta_title)}">\n    <meta property="og:description" content="${escapeHtml(locale.meta_desc)}">\n    <meta property="og:type" content="website">\n    <link rel="canonical" href="${escapeHtml(self)}">\n${alternates}\n    <meta property="og:url" content="${escapeHtml(self)}">\n    <meta property="og:site_name" content="KongGoo">\n    <meta property="og:locale" content="${lang.ogLocale}">\n${otherLocales}\n    <meta property="og:image" content="${baseUrl}/og-image.png">\n    <meta property="og:image:width" content="1200">\n    <meta property="og:image:height" content="630">\n    <meta name="twitter:card" content="summary_large_image">\n    <meta name="twitter:title" content="${escapeHtml(locale.meta_title)}">\n    <meta name="twitter:description" content="${escapeHtml(locale.meta_desc)}">\n    <meta name="twitter:image" content="${baseUrl}/og-image.png">\n${code === 'ko' ? '    <!-- naver-site-verification: add <meta name="naver-site-verification" content="..."> here once Naver Search Advisor issues the code -->\n' : ''}    <!--/SEO:HEAD-->`;
        html = betweenMarkers(html, '<!--SEO:HEAD-->', '<!--/SEO:HEAD-->', head);

        const currency = code === 'zh-TW' ? 'TWD' : 'USD';
        const annual = code === 'zh-TW' ? '690' : '22';
        const lifetime = code === 'zh-TW' ? '1750' : '55';
        const appData = {
            '@context': 'https://schema.org', '@type': 'SoftwareApplication', name: 'KongGoo', alternateName: ALTERNATE_NAMES[code],
            description: locale.meta_desc, applicationCategory: 'UtilitiesApplication', operatingSystem: 'macOS, Windows',
            softwareVersion: '1.2.0', datePublished: '2026-02-15', downloadUrl: `${self}#download`,
            screenshot: `${baseUrl}/og-image.png`, image: `${baseUrl}/og-image.png`, url: self, inLanguage: code,
            featureList: ['feat_search_title', 'feat_tp_title', 'feat_route_title', 'feat_fav_title', 'feat_cross_title', 'feat_easy_title'].map((key) => locale[key]),
            author: { '@type': 'Organization', name: 'KongGoo' },
            offers: [
                { '@type': 'Offer', name: locale.price_annual_title, price: annual, priceCurrency: currency, availability: 'https://schema.org/InStock' },
                { '@type': 'Offer', name: locale.price_lifetime_title, price: lifetime, priceCurrency: currency, availability: 'https://schema.org/InStock' }
            ]
        };
        const faqItems = [];
        for (let i = 1; i <= 6; i++) {
            let answer = locale[`faq_a${i}`];
            if (i === 1) answer += ' xattr -cr /Applications/KongGoo.app ' + locale.faq_a1_after;
            faqItems.push({ '@type': 'Question', name: plainText(locale[`faq_q${i}`]), acceptedAnswer: { '@type': 'Answer', text: plainText(answer) } });
        }
        const faqData = { '@context': 'https://schema.org', '@type': 'FAQPage', mainEntity: faqItems };
        const jsonld = `<!--SEO:JSONLD-->\n    <script type="application/ld+json">${jsonScript(appData)}</script>\n    <script type="application/ld+json">${jsonScript(faqData)}</script>\n    <!--/SEO:JSONLD-->`;
        html = betweenMarkers(html, '<!--SEO:JSONLD-->', '<!--/SEO:JSONLD-->', jsonld);

        html = html.replace(/<a class="lang-btn(?: active)?" href="([^"]+)" hreflang="([^"]+)" lang="([^"]+)" data-lang="([^"]+)" onclick="rememberLang\('[^']+'\)" style="([^"]+)">([^<]+)<\/a>/g,
            (whole, href, hreflang, language, dataLang, style) => {
                const active = dataLang === code;
                const activeStyle = style.replace(/background:(?:var\(--accent\)|transparent);color:(?:#fff|var\(--text-2\))/, `background:${active ? 'var(--accent)' : 'transparent'};color:${active ? '#fff' : 'var(--text-2)'}`);
                return `<a class="lang-btn${active ? ' active' : ''}" href="${href}" hreflang="${hreflang}" lang="${language}" data-lang="${dataLang}" onclick="rememberLang('${dataLang}')" style="${activeStyle}">${whole.match(/>([^<]+)<\/a>$/)[1]}</a>`;
            });
        const approx = APPROX_PRICES[code];
        if (approx) {
            html = html.replace('<div class="price-krw" id="krw-annual"></div>', `<div class="price-krw show" id="krw-annual">${approx[0]}</div>`);
            html = html.replace('<div class="price-krw" id="krw-lifetime"></div>', `<div class="price-krw show" id="krw-lifetime">${approx[1]}</div>`);
        }
        return html;
    }
    return { render, has: (code) => LANGS.some((entry) => entry.code === code) };
}

module.exports = { LANGS, createSeoRenderer };
