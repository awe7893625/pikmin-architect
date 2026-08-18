const PLAN_DURATION_DAYS = { annual: 365, lifetime: null };

/**
 * 取得授權方案對應的天數
 * @param {string} planType - 授權方案類型
 * @returns {number|null} 天數或 null
 */
function planDurationDays(planType) {
  if (Object.prototype.hasOwnProperty.call(PLAN_DURATION_DAYS, planType)) {
    return PLAN_DURATION_DAYS[planType];
  }
  return null;
}

/**
 * 計算授權到期時間
 * @param {Object} license - 授權物件
 * @param {string} activatedAtIso - 啟用時間 ISO 字串
 * @returns {string|null} 到期時間 ISO 字串或 null
 */
function computeExpiresAt(license, activatedAtIso) {
  const durationDays = license && license.durationDays;
  if (!durationDays) return null;

  const base = new Date(activatedAtIso);
  if (Number.isNaN(base.getTime())) return null;

  const expires = new Date(base.getTime() + durationDays * 24 * 60 * 60 * 1000);
  return expires.toISOString();
}

/**
 * 檢查授權是否已過期
 * @param {Object} license - 授權物件
 * @param {Date} now - 當前時間預設為 new Date()
 * @returns {boolean} 是否過期
 */
function isLicenseExpired(license, now = new Date()) {
  if (!license || !license.expiresAt) return false;

  const expires = new Date(license.expiresAt);
  if (Number.isNaN(expires.getTime())) return false;

  return expires.getTime() <= now.getTime();
}

/**
 * 正規化 email
 * @param {string} value - 原始 email
 * @returns {string} 正規化後 email
 */
function normalizeEmail(value) {
  return String(value || '').trim().toLowerCase();
}

/**
 * 驗證 email 格式
 * @param {string} value - email
 * @returns {boolean} 是否有效
 */
function isValidEmail(value) {
  const normalized = normalizeEmail(value);
  if (normalized.length === 0 || normalized.length > 254) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(normalized);
}

/**
 * 掩碼 email
 * @param {string} value - email
 * @returns {string} 掩碼後 email
 */
function maskEmail(value) {
  const normalized = normalizeEmail(value);
  const atIndex = normalized.indexOf('@');
  if (atIndex <= 0) return '***';

  const localPart = normalized.substring(0, atIndex);
  const domainPart = normalized.substring(atIndex);
  const head = localPart.substring(0, Math.min(2, localPart.length));
  const maskedLocal = head + '*'.repeat(Math.max(1, localPart.length - head.length));

  return maskedLocal + domainPart;
}

module.exports = {
  PLAN_DURATION_DAYS,
  planDurationDays,
  computeExpiresAt,
  isLicenseExpired,
  normalizeEmail,
  isValidEmail,
  maskEmail
};
