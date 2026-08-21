#!/usr/bin/env python3
"""KongGoo 買 → 下載 → 啟用 整條鏈路的線上健康閘。

存在原因
    這條鏈跨首頁、GitHub Release、授權 API、綠界金流、production KV。
    任何一環靜默壞掉，客人會付了錢卻拿不到能用的 App 或授權碼。
    人工記得檢查不可靠；發版前跑這支腳本，整條鏈活著才放行。

每一項在防哪個曾經真的發生過的故障
    1. 頁面 200
       路由或靜態檔漏部署，/payment、/license、privacy 變成 404。
    2. /api/health 與 /api/version
       Vercel 跑到舊 commit 卻看起來「網站還在」。commit 欄位用來對指紋。
    3. 下載連結同 tag + HEAD 體積 > 50MB
       發版漏改，三平台指向不同 release tag；或打包漏掉 python-runtime，
       下載檔只剩幾百 KB 空殼（客人裝了不能用）。
    4. /api/license/verify 錯誤形狀
       不存在的授權碼曾經 500；空 body 沒擋下來。客人/App 會以為系統掛了。
    5. 付款繞過端點 production 必須 404
       /payment/process 與 /api/payment/confirm 開著就能跳過金流領授權碼。
    6. 錯誤 adminKey → 401
       admin 端點沒上鎖，任何人都能產真授權碼。
    7. /api/payment/create 輸入驗證
       缺 email 仍建單，客人關掉成功頁就永久失聯；planType 亂填不該進金流。
    8. 語系 JSON
       locale 檔漏部署，付款頁/成功頁整頁空白或 key 原樣露出。
    9. (--deep) 授權生命週期 + expiresAt = activatedAt + 365 天
       admin create-license 漏寫 durationDays 時，啟用會變成永久授權。
       同裝置重啟不得展延；換機必須 403 LICENSE_USED。
   10. (--deep) 真訂單走綠界 checkout
       gateway 漂到 polar 或 checkout 表單缺 MerchantID / CheckMacValue /
       ReturnURL / OrderResultURL，客人按了沒進綠界。
   11. (--deep) 錯誤 CheckMacValue POST /payment/success 仍要 3xx 帶 orderId
       綠界 OrderResultURL 回傳後沒把 orderId 放進 Location，
       成功頁變成「未找到授權碼」（notify 還沒到、前端也不知道查哪張單）。

用法
    python3 scripts/purchase_chain_gate.py              # 唯讀，預設
    python3 scripts/purchase_chain_gate.py --deep       # 會寫 KV，跑完自清
    python3 scripts/purchase_chain_gate.py --json       # 機器可讀 JSON
"""

from __future__ import print_function

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

TIMEOUT = 30
MIN_ASSET_BYTES = 50 * 1024 * 1024
DAY_MS = 24 * 60 * 60 * 1000
EXPIRES_TOLERANCE_MS = 5000
USER_AGENT = "KongGoo-purchase-chain-gate/1.0 (+https://konggoo.uk)"
ECPAY_AIO = "https://payment.ecpay.com.tw/Cashier/AioCheckOut/V5"
RELEASE_RE = re.compile(
    r"https://github\.com/[^/\s\"']+/[^/\s\"']+/releases/download/"
    r"([^/\s\"']+)/([^/\s\"'?]+)"
)


class Resp(object):
    def __init__(self, status, headers, body, url, error=None):
        self.status = status
        self.headers = headers
        self.body = body or b""
        self.url = url
        self.error = error

    def text(self):
        return self.body.decode("utf-8", errors="replace")

    def json(self):
        raw = self.text()
        if not raw.strip():
            return {}
        return json.loads(raw)

    def header(self, name):
        return self.headers.get(name.lower())


class HeadRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = urllib.request.HTTPRedirectHandler.redirect_request(
            self, req, fp, code, msg, headers, newurl
        )
        if new is not None:
            new.method = req.get_method()
        return new


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _opener(follow):
    if follow:
        return urllib.request.build_opener(HeadRedirectHandler)
    return urllib.request.build_opener(NoRedirectHandler)


def request(method, url, json_body=None, form=None, headers=None, follow=True, timeout=TIMEOUT):
    hdrs = {"User-Agent": USER_AGENT, "Accept": "*/*"}
    if headers:
        hdrs.update(headers)
    data = None
    if json_body is not None:
        data = json.dumps(json_body).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json")
    elif form is not None:
        data = urllib.parse.urlencode(form).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded")
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        opener = _opener(follow)
        with opener.open(req, timeout=timeout) as resp:
            body = resp.read()
            headers_map = {k.lower(): v for k, v in resp.headers.items()}
            return Resp(resp.getcode(), headers_map, body, resp.geturl())
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read()
        except Exception:
            body = b""
        headers_map = {}
        if exc.headers is not None:
            headers_map = {k.lower(): v for k, v in exc.headers.items()}
        return Resp(exc.code, headers_map, body, getattr(exc, "url", url) or url)
    except Exception as exc:
        return Resp(0, {}, b"", url, error="%s: %s" % (type(exc).__name__, exc))


def urljoin(base, path):
    return urllib.parse.urljoin(base.rstrip("/") + "/", path)


# ---------------------------------------------------------------------------
# Check runner
# ---------------------------------------------------------------------------

RESULTS = []
JSON_MODE = False


def record(num, status, message):
    RESULTS.append({"id": num, "status": status, "message": message})
    if not JSON_MODE:
        print("%s  %s. %s" % (status, num, message))
        sys.stdout.flush()


def pass_(num, message):
    record(num, "PASS", message)


def fail(num, message):
    record(num, "FAIL", message)


def skip(num, message):
    record(num, "SKIP", message)


def _downgrade(num, message):
    """把已記錄的 PASS 改成 FAIL（清理失敗）；若該項還沒記過就直接 FAIL。"""
    for i in range(len(RESULTS) - 1, -1, -1):
        if RESULTS[i]["id"] == num:
            if RESULTS[i]["status"] == "PASS":
                RESULTS[i] = {"id": num, "status": "FAIL", "message": message}
                if not JSON_MODE:
                    print("FAIL  %s. %s" % (num, message))
                    sys.stdout.flush()
            return
    fail(num, message)


def net_fail(num, what, resp):
    if resp.error:
        fail(num, "%s 網路錯誤：%s" % (what, resp.error))
    else:
        fail(num, "%s HTTP %s" % (what, resp.status))
    return False


# ---------------------------------------------------------------------------
# 1–8 唯讀
# ---------------------------------------------------------------------------

def check_pages(base):
    paths = ["/", "/payment", "/license", "/privacy.html"]
    bits = []
    for path in paths:
        resp = request("GET", urljoin(base, path))
        if resp.error:
            fail(1, "%s 網路錯誤：%s" % (path, resp.error))
            return
        if resp.status != 200:
            fail(1, "%s 回 %s，預期 200" % (path, resp.status))
            return
        bits.append("%s=%s" % (path, resp.status))
    pass_(1, "首頁路徑皆 200（%s）" % ", ".join(bits))


def check_health_version(base):
    health = request("GET", urljoin(base, "/api/health"))
    if health.error or health.status != 200:
        return net_fail(2, "/api/health", health)
    try:
        h = health.json()
    except ValueError as exc:
        fail(2, "/api/health 不是合法 JSON：%s" % exc)
        return
    if h.get("status") != "ok":
        fail(2, "/api/health status=%r，預期 ok" % h.get("status"))
        return

    version = request("GET", urljoin(base, "/api/version"))
    if version.error or version.status != 200:
        return net_fail(2, "/api/version", version)
    try:
        v = version.json()
    except ValueError as exc:
        fail(2, "/api/version 不是合法 JSON：%s" % exc)
        return
    commit = v.get("commit")
    if not commit:
        fail(2, "/api/version 缺 commit 欄位：%s" % v)
        return
    pass_(2, "health ok，version commit %s" % commit)


def _asset_size(url):
    """HEAD（跟隨轉址）；沒有 Content-Length 再 Range GET，絕不整檔下載。"""
    head = request("HEAD", url, follow=True)
    if not head.error and head.status == 200:
        length = head.header("content-length")
        if length and length.isdigit() and int(length) > 0:
            return head.status, int(length), None
    ranged = request(
        "GET",
        url,
        headers={"Range": "bytes=0-0"},
        follow=True,
    )
    if ranged.error:
        if head.error:
            return 0, 0, head.error
        return head.status, 0, "HEAD 無 Content-Length，Range GET 失敗：%s" % ranged.error
    cr = ranged.header("content-range") or ""
    # Content-Range: bytes 0-0/168888888
    m = re.search(r"/(\d+)\s*$", cr)
    if m:
        return ranged.status, int(m.group(1)), None
    length = ranged.header("content-length")
    if length and length.isdigit() and int(length) > 1:
        return ranged.status, int(length), None
    return ranged.status or head.status, 0, "無法取得體積（HEAD %s Length=%s, Range %s Content-Range=%s）" % (
        head.status, head.header("content-length"), ranged.status, cr or "-"
    )


def _platform_order(url):
    name = url.lower()
    if "arm64" in name or "aarch64" in name:
        return 0
    if "win" in name or name.endswith(".exe"):
        return 2
    return 1


def check_downloads(base):
    resp = request("GET", urljoin(base, "/"))
    if resp.error or resp.status != 200:
        return net_fail(3, "首頁", resp)
    html = resp.text()
    found = []
    seen = set()
    for match in RELEASE_RE.finditer(html):
        tag, filename = match.group(1), match.group(2)
        url = match.group(0).split("?")[0]
        if url in seen:
            continue
        seen.add(url)
        found.append((tag, filename, url))
    if not found:
        fail(3, "首頁找不到任何 GitHub release 下載連結")
        return
    tags = sorted(set(t for t, _, _ in found))
    if len(tags) != 1:
        fail(3, "下載連結指向多個 tag：%s（%s）" % (
            ", ".join(tags),
            "; ".join("%s→%s" % (t, f) for t, f, _ in found),
        ))
        return

    found.sort(key=lambda item: _platform_order(item[2]))
    sizes = []
    for tag, filename, url in found:
        status, nbytes, err = _asset_size(url)
        if err:
            fail(3, "%s HEAD 失敗：%s" % (filename, err))
            return
        if status not in (200, 206):
            fail(3, "%s HTTP %s，預期 200" % (filename, status))
            return
        if nbytes <= MIN_ASSET_BYTES:
            fail(3, "%s 體積 %s bytes（%.1f MB），預期 > 50MB（疑似空殼包）" % (
                filename, nbytes, nbytes / (1024.0 * 1024.0)
            ))
            return
        sizes.append(int(round(nbytes / (1024.0 * 1024.0))))
    mb = "/".join(str(s) for s in sizes)
    pass_(3, "下載連結 %d 個同 tag %s，體積 %s MB" % (len(found), tags[0], mb))


def check_verify(base):
    missing = request(
        "POST",
        urljoin(base, "/api/license/verify"),
        json_body={"licenseKey": "KGOO-FFFF-FFFF-DEAD"},
    )
    if missing.error:
        return net_fail(4, "verify 不存在授權碼", missing)
    if missing.status != 200:
        fail(4, "不存在授權碼回 %s，預期 200（不能 500）" % missing.status)
        return
    try:
        data = missing.json()
    except ValueError as exc:
        fail(4, "verify 回應不是 JSON：%s" % exc)
        return
    if data.get("valid") is not False:
        fail(4, "不存在授權碼 valid=%r，預期 false：%s" % (data.get("valid"), data))
        return

    empty = request("POST", urljoin(base, "/api/license/verify"), json_body={})
    if empty.error:
        return net_fail(4, "verify 空 body", empty)
    if empty.status != 400:
        fail(4, "空 body 回 %s，預期 400" % empty.status)
        return
    try:
        edata = empty.json()
    except ValueError as exc:
        fail(4, "空 body 回應不是 JSON：%s" % exc)
        return
    if edata.get("code") != "BAD_REQUEST":
        fail(4, "空 body code=%r，預期 BAD_REQUEST：%s" % (edata.get("code"), edata))
        return
    pass_(4, "不存在授權碼 valid=false；空 body 400 BAD_REQUEST")


def check_payment_bypass(base):
    process = request("GET", urljoin(base, "/payment/process?orderId=x"), follow=False)
    if process.error:
        return net_fail(5, "GET /payment/process", process)
    if process.status != 404:
        fail(5, "GET /payment/process?orderId=x 回 %s，預期 404（production 必須關閉繞過）" % process.status)
        return
    confirm = request(
        "POST",
        urljoin(base, "/api/payment/confirm"),
        json_body={"orderId": "x"},
        follow=False,
    )
    if confirm.error:
        return net_fail(5, "POST /api/payment/confirm", confirm)
    if confirm.status != 404:
        fail(5, "POST /api/payment/confirm 回 %s，預期 404" % confirm.status)
        return
    pass_(5, "process 與 confirm 皆 404（production 付款繞過已關）")


def check_admin_lock(base):
    resp = request(
        "POST",
        urljoin(base, "/api/admin/create-license"),
        json_body={"adminKey": "definitely-not-the-admin-key"},
    )
    if resp.error:
        return net_fail(6, "create-license 錯誤金鑰", resp)
    if resp.status != 401:
        fail(6, "錯誤 adminKey 回 %s，預期 401" % resp.status)
        return
    pass_(6, "錯誤 adminKey 回 401（admin 有上鎖）")


def check_payment_create_validation(base):
    no_email = request(
        "POST",
        urljoin(base, "/api/payment/create"),
        json_body={"planType": "annual"},
    )
    if no_email.error:
        return net_fail(7, "create 缺 email", no_email)
    if no_email.status != 400:
        fail(7, "缺 email 回 %s，預期 400" % no_email.status)
        return
    try:
        d1 = no_email.json()
    except ValueError as exc:
        fail(7, "缺 email 回應不是 JSON：%s" % exc)
        return
    if d1.get("code") != "INVALID_EMAIL":
        fail(7, "缺 email code=%r，預期 INVALID_EMAIL：%s" % (d1.get("code"), d1))
        return

    bad_plan = request(
        "POST",
        urljoin(base, "/api/payment/create"),
        json_body={"planType": "not-a-plan", "email": "gate-test@example.com"},
    )
    if bad_plan.error:
        return net_fail(7, "create 亂填 planType", bad_plan)
    if bad_plan.status != 400:
        fail(7, "亂填 planType 回 %s，預期 400" % bad_plan.status)
        return
    try:
        d2 = bad_plan.json()
    except ValueError as exc:
        fail(7, "亂填 planType 回應不是 JSON：%s" % exc)
        return
    if d2.get("code") != "BAD_REQUEST":
        fail(7, "亂填 planType code=%r，預期 BAD_REQUEST：%s" % (d2.get("code"), d2))
        return
    pass_(7, "缺 email → 400 INVALID_EMAIL；planType 亂填 → 400 BAD_REQUEST")


def check_locales(base):
    for lang in ("zh-TW", "en"):
        resp = request("GET", urljoin(base, "/api/locale/%s" % lang))
        if resp.error:
            return net_fail(8, "/api/locale/%s" % lang, resp)
        if resp.status != 200:
            fail(8, "/api/locale/%s 回 %s，預期 200" % (lang, resp.status))
            return
        try:
            data = resp.json()
        except ValueError as exc:
            fail(8, "/api/locale/%s 不是合法 JSON：%s" % (lang, exc))
            return
        if not isinstance(data, dict) or not data:
            fail(8, "/api/locale/%s JSON 形狀異常：%r" % (lang, type(data).__name__))
            return
    pass_(8, "zh-TW 與 en 皆 200 合法 JSON")


# ---------------------------------------------------------------------------
# --deep 9–11（寫 KV，必須清乾淨）
# ---------------------------------------------------------------------------

def kv_del(kv_url, kv_token, key):
    resp = request(
        "POST",
        kv_url,
        json_body=["DEL", key],
        headers={"Authorization": "Bearer %s" % kv_token},
    )
    if resp.error:
        return False, "KV DEL %s 網路錯誤：%s" % (key, resp.error)
    if resp.status != 200:
        return False, "KV DEL %s HTTP %s %s" % (key, resp.status, resp.text()[:200])
    return True, None


def check_license_lifecycle(base, admin_key, kv_url, kv_token):
    license_key = None
    device_a = "gate-a-%s-%s" % (os.getpid(), os.urandom(4).hex())
    device_b = "gate-b-%s-%s" % (os.getpid(), os.urandom(4).hex())
    created = False
    try:
        created_resp = request(
            "POST",
            urljoin(base, "/api/admin/create-license"),
            json_body={"adminKey": admin_key},
        )
        if created_resp.error:
            return net_fail(9, "create-license", created_resp)
        if created_resp.status != 200:
            fail(9, "create-license 回 %s：%s" % (created_resp.status, created_resp.text()[:300]))
            return
        try:
            created_data = created_resp.json()
        except ValueError as exc:
            fail(9, "create-license 不是 JSON：%s" % exc)
            return
        license_key = created_data.get("licenseKey")
        if not license_key:
            fail(9, "create-license 沒回 licenseKey：%s" % created_data)
            return
        created = True

        verified = request(
            "POST",
            urljoin(base, "/api/license/verify"),
            json_body={"licenseKey": license_key},
        )
        if verified.error:
            return net_fail(9, "verify 未啟用", verified)
        if verified.status != 200:
            fail(9, "未啟用 verify 回 %s" % verified.status)
            return
        try:
            vdata = verified.json()
        except ValueError as exc:
            fail(9, "verify 不是 JSON：%s" % exc)
            return
        if vdata.get("valid") is not True:
            fail(9, "未啟用 verify valid=%r，預期 true：%s" % (vdata.get("valid"), vdata))
            return

        first = request(
            "POST",
            urljoin(base, "/api/license/activate"),
            json_body={"deviceId": device_a, "licenseKey": license_key},
        )
        if first.error:
            return net_fail(9, "啟用 device A", first)
        if first.status != 200:
            fail(9, "device A 啟用回 %s：%s" % (first.status, first.text()[:300]))
            return
        try:
            adata = first.json()
        except ValueError as exc:
            fail(9, "啟用回應不是 JSON：%s" % exc)
            return
        activated_at = adata.get("activatedAt")
        expires_at = adata.get("expiresAt")
        if not expires_at:
            fail(9, "啟用後缺 expiresAt（admin 端點漏寫 durationDays 的迴歸）：%s" % adata)
            return
        if not activated_at:
            fail(9, "啟用後缺 activatedAt：%s" % adata)
            return
        try:
            act = datetime.strptime(activated_at.replace("Z", "+0000")[:19], "%Y-%m-%dT%H:%M:%S")
            exp = datetime.strptime(expires_at.replace("Z", "+0000")[:19], "%Y-%m-%dT%H:%M:%S")
            delta_ms = (exp - act).total_seconds() * 1000
        except (ValueError, TypeError) as exc:
            fail(9, "無法解析效期 activatedAt=%r expiresAt=%r：%s" % (activated_at, expires_at, exc))
            return
        if abs(delta_ms - 365 * DAY_MS) > EXPIRES_TOLERANCE_MS:
            fail(9, "expiresAt 不是 activatedAt+365 天（實際 %.2f 天）" % (delta_ms / DAY_MS))
            return

        again = request(
            "POST",
            urljoin(base, "/api/license/activate"),
            json_body={"deviceId": device_a, "licenseKey": license_key},
        )
        if again.error:
            return net_fail(9, "device A 再啟用", again)
        if again.status != 200:
            fail(9, "device A 再啟用回 %s：%s" % (again.status, again.text()[:300]))
            return
        try:
            again_data = again.json()
        except ValueError as exc:
            fail(9, "再啟用回應不是 JSON：%s" % exc)
            return
        if again_data.get("expiresAt") != expires_at:
            fail(9, "同裝置再啟用展延了效期 %s → %s" % (expires_at, again_data.get("expiresAt")))
            return

        other = request(
            "POST",
            urljoin(base, "/api/license/activate"),
            json_body={"deviceId": device_b, "licenseKey": license_key},
        )
        if other.error:
            return net_fail(9, "device B 啟用", other)
        if other.status != 403:
            fail(9, "device B 啟用回 %s，預期 403 LICENSE_USED：%s" % (other.status, other.text()[:300]))
            return
        try:
            odata = other.json()
        except ValueError as exc:
            fail(9, "device B 回應不是 JSON：%s" % exc)
            return
        if odata.get("code") != "LICENSE_USED":
            fail(9, "device B code=%r，預期 LICENSE_USED：%s" % (odata.get("code"), odata))
            return

        status = request(
            "POST",
            urljoin(base, "/api/license/status"),
            json_body={"licenseKey": license_key, "deviceId": device_b},
        )
        if status.error:
            return net_fail(9, "status device B", status)
        if status.status != 200:
            fail(9, "status device B 回 %s：%s" % (status.status, status.text()[:300]))
            return
        try:
            sdata = status.json()
        except ValueError as exc:
            fail(9, "status 不是 JSON：%s" % exc)
            return
        if sdata.get("valid") is not False:
            fail(9, "status device B valid=%r，預期 false：%s" % (sdata.get("valid"), sdata))
            return
        pass_(9, "授權生命週期：verify→啟用 365 天→重啟不展延→跨機 403 LICENSE_USED")
    finally:
        if created and license_key:
            keys = ["license:%s" % license_key, "device:%s" % device_a, "device:%s" % device_b]
            errors = []
            for key in keys:
                ok, err = kv_del(kv_url, kv_token, key)
                if not ok:
                    errors.append(err)
            if errors:
                _downgrade(9, "生命週期通過但 KV 清理失敗：%s" % "; ".join(errors))


def _checkout_fields(html):
    action = None
    m = re.search(r'<form[^>]*\saction=["\']([^"\']+)["\']', html, re.I)
    if m:
        action = m.group(1)
    names = set(re.findall(r'name=["\']([^"\']+)["\']', html, re.I))
    return action, names


def check_order_and_success_redirect(base, kv_url, kv_token):
    order_id = None
    created = False
    try:
        created_resp = request(
            "POST",
            urljoin(base, "/api/payment/create"),
            json_body={
                "planType": "annual",
                "email": "gate-test@example.com",
                "lang": "zh-TW",
            },
        )
        if created_resp.error:
            net_fail(10, "payment/create", created_resp)
            skip(11, "無訂單，跳過 /payment/success 迴歸")
            return
        if created_resp.status != 200:
            fail(10, "payment/create 回 %s：%s" % (created_resp.status, created_resp.text()[:300]))
            skip(11, "無訂單，跳過 /payment/success 迴歸")
            return
        try:
            data = created_resp.json()
        except ValueError as exc:
            fail(10, "payment/create 不是 JSON：%s" % exc)
            skip(11, "無訂單，跳過 /payment/success 迴歸")
            return
        order_id = data.get("orderId")
        gateway = data.get("gateway")
        payment_url = data.get("paymentUrl") or ""
        if not order_id:
            fail(10, "payment/create 沒回 orderId：%s" % data)
            skip(11, "無訂單，跳過 /payment/success 迴歸")
            return
        created = True
        if gateway != "ecpay":
            fail(10, "gateway=%r，預期 ecpay：%s" % (gateway, data))
        elif "/payment/ecpay-checkout" not in payment_url:
            fail(10, "paymentUrl=%r，預期指向 /payment/ecpay-checkout" % payment_url)
        else:
            checkout = request("GET", urljoin(base, payment_url))
            if checkout.error:
                net_fail(10, "ecpay-checkout", checkout)
            elif checkout.status != 200:
                fail(10, "ecpay-checkout 回 %s：%s" % (checkout.status, checkout.text()[:200]))
            else:
                action, names = _checkout_fields(checkout.text())
                required = ("MerchantID", "CheckMacValue", "ReturnURL", "OrderResultURL")
                if action != ECPAY_AIO:
                    fail(10, "表單 action=%r，預期 %s" % (action, ECPAY_AIO))
                else:
                    missing = [f for f in required if f not in names]
                    if missing:
                        fail(10, "checkout 表單缺欄位：%s" % ", ".join(missing))
                    else:
                        pass_(10, "gateway=ecpay，checkout action 綠界 V5，含 %s" % "/".join(required))

        success = request(
            "POST",
            urljoin(base, "/payment/success"),
            form={
                "CustomField1": order_id,
                "RtnCode": "1",
                "CheckMacValue": "DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF",
            },
            follow=False,
        )
        if success.error:
            net_fail(11, "POST /payment/success", success)
        elif not (300 <= success.status < 400):
            fail(11, "錯誤 CheckMacValue POST /payment/success 回 %s，預期 3xx" % success.status)
        else:
            location = success.header("location") or ""
            if not location:
                fail(11, "3xx 但沒有 Location（status=%s）" % success.status)
            else:
                parsed = urllib.parse.urlparse(urllib.parse.urljoin(base, location))
                qs = urllib.parse.parse_qs(parsed.query)
                got_order = (qs.get("orderId") or [None])[0]
                if got_order != order_id:
                    fail(11, "Location=%r 未帶 orderId=%s" % (location, order_id))
                else:
                    pass_(11, "錯誤 CheckMacValue → %s Location 帶 orderId" % success.status)
    finally:
        if created and order_id:
            ok, err = kv_del(kv_url, kv_token, "order:%s" % order_id)
            if not ok:
                _downgrade(10, "訂單流程通過但 KV 清理失敗：%s" % err)


def run_deep(base):
    admin_key = os.environ.get("ADMIN_KEY") or ""
    kv_url = os.environ.get("KV_REST_API_URL") or ""
    kv_token = os.environ.get("KV_REST_API_TOKEN") or ""

    if not admin_key:
        skip(9, "SKIP：缺 ADMIN_KEY")
    elif not kv_url or not kv_token:
        skip(9, "SKIP：缺 KV_REST_API_URL / KV_REST_API_TOKEN")
    else:
        check_license_lifecycle(base, admin_key, kv_url, kv_token)

    if not kv_url or not kv_token:
        reason = "SKIP：缺 KV_REST_API_URL / KV_REST_API_TOKEN"
        if not admin_key and not kv_url and not kv_token:
            # 沒帶任何 deep 憑證時，跟規格範例對齊，三項都講缺 ADMIN_KEY
            reason = "SKIP：缺 ADMIN_KEY"
        skip(10, reason)
        skip(11, reason)
        return
    check_order_and_success_redirect(base, kv_url, kv_token)


def summarize():
    passed = sum(1 for r in RESULTS if r["status"] == "PASS")
    failed = sum(1 for r in RESULTS if r["status"] == "FAIL")
    skipped = sum(1 for r in RESULTS if r["status"] == "SKIP")
    line = "%d passed, %d failed, %d skipped" % (passed, failed, skipped)
    payload = {
        "base": os.environ.get("KONGGOO_BASE", "https://konggoo.uk").rstrip("/"),
        "checks": RESULTS,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "exit": 1 if failed else 0,
    }
    if JSON_MODE:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(line)
    return 1 if failed else 0


def main():
    global JSON_MODE
    parser = argparse.ArgumentParser(description="KongGoo 買→下載→啟用 鏈路健康閘")
    parser.add_argument("--deep", action="store_true", help="額外做會寫入 KV 的檢查，跑完自清")
    parser.add_argument("--json", action="store_true", help="輸出機器可讀 JSON")
    args = parser.parse_args()
    JSON_MODE = args.json
    base = (os.environ.get("KONGGOO_BASE") or "https://konggoo.uk").rstrip("/")

    check_pages(base)
    check_health_version(base)
    check_downloads(base)
    check_verify(base)
    check_payment_bypass(base)
    check_admin_lock(base)
    check_payment_create_validation(base)
    check_locales(base)
    if args.deep:
        run_deep(base)
    return summarize()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        sys.exit(1)
