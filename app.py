# -*- coding: utf-8 -*-
"""OT Laundry - Windows desktop local web shell (Supabase-backed)."""
from __future__ import annotations

import os
import secrets
import time
import sys
import shutil
import json
import hashlib
import base64
from pathlib import Path
from datetime import date, timedelta, datetime, timezone
from decimal import Decimal, InvalidOperation
from functools import wraps

import requests
from flask import Flask, abort, flash, redirect, render_template, request, session, url_for
from cryptography.fernet import Fernet, InvalidToken

# RESOURCE_ROOT contains bundled templates/static files. APP_HOME is the folder
# containing the executable when frozen, while APP_DATA is writable user data.
RESOURCE_ROOT = Path(__file__).resolve().parent
ROOT = RESOURCE_ROOT
IS_VERCEL = os.getenv("VERCEL") == "1"

if getattr(sys, "frozen", False):
    APP_HOME = Path(sys.executable).resolve().parent
    if (APP_HOME / "portable.flag").exists():
        INSTANCE = APP_HOME / "data"
    else:
        local_app_data = Path(os.getenv("LOCALAPPDATA", str(Path.home() / "AppData" / "Local")))
        INSTANCE = local_app_data / "OT-Laundry"
    INSTANCE.mkdir(parents=True, exist_ok=True)
    packaged_env = INSTANCE / ".env"
    if not packaged_env.exists():
        example_env = RESOURCE_ROOT / ".env.example"
        if example_env.exists():
            shutil.copyfile(example_env, packaged_env)
elif IS_VERCEL:
    APP_HOME = RESOURCE_ROOT
    INSTANCE = Path("/tmp/ot-laundry")
else:
    APP_HOME = RESOURCE_ROOT
    INSTANCE = ROOT / "instance"
    INSTANCE.mkdir(parents=True, exist_ok=True)


def load_env(path: Path) -> None:
    """Small .env reader to avoid adding a runtime dependency."""
    if not path.exists():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


if getattr(sys, "frozen", False):
    load_env(INSTANCE / ".env")
else:
    load_env(ROOT / ".env")
SUPABASE_URL = os.getenv("SUPABASE_URL", "").rstrip("/")
SUPABASE_PUBLISHABLE_KEY = os.getenv("SUPABASE_PUBLISHABLE_KEY", "")
AUTH_FUNCTION_URL = os.getenv(
    "OT_LAUNDRY_AUTH_URL",
    f"{SUPABASE_URL}/functions/v1/ot-laundry-auth" if SUPABASE_URL else "",
)

if IS_VERCEL:
    app_secret = os.getenv("FLASK_SECRET_KEY", "")
    if len(app_secret) < 32:
        raise RuntimeError("FLASK_SECRET_KEY must be set to a stable random value (at least 32 characters) in Vercel.")
else:
    key_file = INSTANCE / "session.key"
    if not key_file.exists():
        key_file.write_text(secrets.token_urlsafe(48), encoding="utf-8")
        try:
            os.chmod(key_file, 0o600)
        except OSError:
            pass
    app_secret = key_file.read_text(encoding="utf-8").strip()

app = Flask(__name__, template_folder=str(RESOURCE_ROOT / "templates"), static_folder=str(RESOURCE_ROOT / "static"))
app.secret_key = app_secret
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax" if IS_VERCEL else "Strict",
    SESSION_COOKIE_SECURE=IS_VERCEL,
    SESSION_COOKIE_NAME="ot_laundry_session",
    PERMANENT_SESSION_LIFETIME=60 * 60 * 8,
    MAX_CONTENT_LENGTH=1024 * 1024,
    SESSION_REFRESH_EACH_REQUEST=False,
)

# Supabase tokens are encrypted before being placed in Flask's signed cookie.
_session_fernet_key = base64.urlsafe_b64encode(hashlib.sha256(app_secret.encode("utf-8")).digest())
SESSION_CIPHER = Fernet(_session_fernet_key)

HTTP = requests.Session()
HTTP.headers.update({"User-Agent": "OT-Laundry-Desktop/0.1"})

ROLE_LABELS = {
    "system_admin": "مدير النظام",
    "branch_manager": "مدير الفرع",
    "reception": "موظف استقبال",
    "operations": "موظف تشغيل",
    "delivery": "موظف تسليم",
    "accountant": "محاسب",
    "hr": "مسؤول الموارد البشرية",
}


def csrf_token() -> str:
    token = session.get("csrf_token")
    if not token:
        token = secrets.token_urlsafe(32)
        session["csrf_token"] = token
    return token


@app.context_processor
def inject_globals():
    return {"csrf_token": csrf_token, "current_profile": current_profile(), "is_vercel": IS_VERCEL}


def store_auth(auth: dict) -> None:
    raw = json.dumps(auth, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    session["ot_auth_blob"] = SESSION_CIPHER.encrypt(raw).decode("ascii")


def current_auth() -> dict | None:
    blob = session.get("ot_auth_blob")
    if not blob:
        return None
    try:
        auth = json.loads(SESSION_CIPHER.decrypt(blob.encode("ascii")).decode("utf-8"))
        return auth if isinstance(auth, dict) else None
    except (InvalidToken, ValueError, TypeError, UnicodeDecodeError):
        session.pop("ot_auth_blob", None)
        return None


def current_profile() -> dict | None:
    auth = current_auth()
    return auth.get("profile") if auth else None


def login_required(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        if not current_auth():
            return redirect(url_for("login"))
        return fn(*args, **kwargs)
    return wrapped


def csrf_protect():
    sent = request.form.get("csrf_token", "")
    expected = session.get("csrf_token", "")
    if not sent or not expected or not secrets.compare_digest(sent, expected):
        abort(400, description="انتهت صلاحية النموذج. حدّث الصفحة وحاول مرة أخرى.")


def function_call(payload: dict, access_token: str | None = None, timeout: int = 25) -> tuple[dict, int]:
    if not AUTH_FUNCTION_URL or not SUPABASE_PUBLISHABLE_KEY:
        return {"error": "APP_NOT_CONFIGURED"}, 503
    headers = {
        "apikey": SUPABASE_PUBLISHABLE_KEY,
        "Content-Type": "application/json",
    }
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"
    try:
        response = HTTP.post(AUTH_FUNCTION_URL, json=payload, headers=headers, timeout=timeout)
        try:
            data = response.json()
        except ValueError:
            data = {"error": "INVALID_SERVER_RESPONSE"}
        return data, response.status_code
    except requests.RequestException:
        return {"error": "NETWORK_ERROR"}, 503


def csrf_checked(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        if request.method == "POST":
            csrf_protect()
        return fn(*args, **kwargs)
    return wrapped


@app.get("/health")
def health():
    return {"app": "OT Laundry", "status": "ok", "auth_configured": bool(AUTH_FUNCTION_URL and SUPABASE_PUBLISHABLE_KEY)}


@app.route("/login", methods=["GET", "POST"])
@csrf_checked
def login():
    if current_auth():
        return redirect(url_for("dashboard"))
    error = None
    if request.method == "POST":
        username = request.form.get("username", "").strip().lower()
        password = request.form.get("password", "")
        if not username or not password:
            error = "اكتب اسم المستخدم وكلمة المرور."
        else:
            data, status = function_call({"action": "login", "username": username, "password": password})
            if status == 200 and data.get("session") and data.get("profile"):
                auth_data = data["session"]
                session.clear()
                store_auth({
                    "access_token": auth_data.get("access_token"),
                    "refresh_token": auth_data.get("refresh_token"),
                    "expires_at": time.time() + int(auth_data.get("expires_in", 3600)),
                    "profile": data["profile"],
                })
                session["csrf_token"] = secrets.token_urlsafe(32)
                session.permanent = True
                return redirect(url_for("dashboard"))
            error_map = {
                "APP_NOT_CONFIGURED": "إعدادات الاتصال غير مكتملة. راجع ملف .env.",
                "NETWORK_ERROR": "تعذر الاتصال بالإنترنت أو بخدمة تسجيل الدخول.",
                "AUTH_SERVICE_NOT_CONFIGURED": "خدمة الدخول لم يتم إعدادها بعد.",
            }
            error = error_map.get(data.get("error"), "اسم المستخدم أو كلمة المرور غير صحيحة.")
    return render_template("login.html", error=error)


@app.route("/first-setup", methods=["GET", "POST"])
@csrf_checked
def first_setup():
    if current_auth():
        return redirect(url_for("dashboard"))
    error = None
    if request.method == "POST":
        payload = {
            "action": "bootstrap_admin",
            "bootstrap_code": request.form.get("bootstrap_code", ""),
            "username": request.form.get("username", "").strip().lower(),
            "password": request.form.get("password", ""),
            "full_name": request.form.get("full_name", "").strip(),
            "branch_code": request.form.get("branch_code", "MAIN").strip().upper(),
            "branch_name": request.form.get("branch_name", "الفرع الرئيسي").strip(),
        }
        data, status = function_call(payload)
        if status == 200 and data.get("session") and data.get("profile"):
            auth_data = data["session"]
            session.clear()
            store_auth({
                "access_token": auth_data.get("access_token"),
                "refresh_token": auth_data.get("refresh_token"),
                "expires_at": time.time() + int(auth_data.get("expires_in", 3600)),
                "profile": data["profile"],
            })
            session["csrf_token"] = secrets.token_urlsafe(32)
            session.permanent = True
            return redirect(url_for("dashboard"))
        error = {
            "BOOTSTRAP_NOT_AUTHORIZED": "رمز التهيئة غير صحيح.",
            "BOOTSTRAP_ALREADY_COMPLETED": "تم إنشاء المدير الأول بالفعل. استخدم شاشة الدخول.",
            "AUTH_USER_CREATION_FAILED": "تعذر إنشاء حساب الدخول. تحقق من اسم المستخدم وكلمة المرور.",
        }.get(data.get("error"), "فشل الإعداد الأولي. راجع الاتصال والبيانات ثم حاول مرة أخرى.")
    return render_template("first_setup.html", error=error)


def active_access_token() -> str | None:
    auth = current_auth()
    if not auth:
        return None
    if time.time() < auth["expires_at"] - 90:
        return auth["access_token"]
    refresh_token = auth.get("refresh_token")
    if not refresh_token:
        return None
    try:
        response = HTTP.post(
            f"{SUPABASE_URL}/auth/v1/token?grant_type=refresh_token",
            json={"refresh_token": refresh_token},
            headers={"apikey": SUPABASE_PUBLISHABLE_KEY, "Content-Type": "application/json"},
            timeout=20,
        )
        data = response.json()
        if response.ok and data.get("access_token"):
            auth.update({
                "access_token": data["access_token"],
                "refresh_token": data.get("refresh_token", refresh_token),
                "expires_at": time.time() + int(data.get("expires_in", 3600)),
            })
            store_auth(auth)
            return auth["access_token"]
    except (requests.RequestException, ValueError):
        pass
    return None



def supabase_rows(table: str, query: dict | None = None) -> list[dict]:
    """Read branch-scoped rows through the user's JWT; RLS remains authoritative."""
    token = active_access_token()
    if not token:
        raise RuntimeError("SESSION_EXPIRED")
    params = query or {"select": "*"}
    try:
        response = HTTP.get(
            f"{SUPABASE_URL}/rest/v1/{table}",
            params=params,
            headers={
                "apikey": SUPABASE_PUBLISHABLE_KEY,
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
            },
            timeout=20,
        )
        if response.status_code == 401:
            raise RuntimeError("SESSION_EXPIRED")
        response.raise_for_status()
        data = response.json()
        return data if isinstance(data, list) else []
    except requests.RequestException as exc:
        raise RuntimeError("DATA_SERVICE_UNAVAILABLE") from exc




def supabase_request(method: str, path: str, payload=None, params=None, prefer=None):
    """Call Supabase REST/RPC using the current user's JWT; never uses service_role."""
    token = active_access_token()
    if not token:
        raise RuntimeError("SESSION_EXPIRED")
    headers = {
        "apikey": SUPABASE_PUBLISHABLE_KEY,
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    if prefer:
        headers["Prefer"] = prefer
    try:
        response = HTTP.request(
            method, f"{SUPABASE_URL}/rest/v1/{path}",
            json=payload, params=params, headers=headers, timeout=30
        )
        if response.status_code == 401:
            raise RuntimeError("SESSION_EXPIRED")
        try:
            data = response.json() if response.content else {}
        except ValueError:
            data = {"error": "INVALID_SERVER_RESPONSE"}
        if not response.ok:
            message = data.get("message") or data.get("details") or data.get("hint") or data.get("error") or "DATA_SERVICE_ERROR"
            raise RuntimeError(f"SUPABASE:{response.status_code}:{message}")
        return data
    except requests.RequestException as exc:
        raise RuntimeError("DATA_SERVICE_UNAVAILABLE") from exc


def post_csrf_valid():
    sent = request.headers.get("X-CSRF-Token") or request.form.get("csrf_token", "")
    expected = session.get("csrf_token", "")
    return bool(sent and expected and secrets.compare_digest(sent, expected))




@app.route("/catalog", methods=["GET", "POST"])
@login_required
@csrf_checked
def catalog():
    profile = current_profile() or {}
    branch_id = profile.get("branch_id")
    if not branch_id:
        abort(403, description="حساب المستخدم غير مرتبط بفرع.")
    if request.method == "POST":
        action = request.form.get("action", "")
        try:
            if action == "category":
                payload = {"branch_id":branch_id,"name":request.form.get("name","").strip(),"name_en":request.form.get("name_en","").strip() or None,"sort_order":int(request.form.get("sort_order") or 0),"is_active":True}
                if not payload["name"]: raise ValueError("اكتب اسم القسم.")
                supabase_request("POST","garment_categories",payload=payload,prefer="return=minimal")
            elif action == "garment":
                payload = {"branch_id":branch_id,"category_id":request.form.get("category_id"),"name":request.form.get("name","").strip(),"name_en":request.form.get("name_en","").strip() or None,"icon_key":request.form.get("icon_key","laundry"),"is_active":True}
                if not payload["category_id"] or not payload["name"]: raise ValueError("اختار القسم واكتب اسم القطعة.")
                supabase_request("POST","garment_types",payload=payload,prefer="return=minimal")
            elif action == "service":
                payload = {"branch_id":branch_id,"name":request.form.get("name","").strip(),"name_en":request.form.get("name_en","").strip() or None,"is_active":True}
                if not payload["name"]: raise ValueError("اكتب اسم الخدمة.")
                supabase_request("POST","services",payload=payload,prefer="return=minimal")
            elif action == "combination":
                raw_price = request.form.get("price", "").strip()
                price = None if raw_price == "" else float(raw_price)
                if price is not None and (price < 0 or price > 999999999): raise ValueError("السعر يجب أن يكون صفرًا أو أكبر.")
                payload = {"branch_id":branch_id,"garment_type_id":request.form.get("garment_type_id"),"service_id":request.form.get("service_id"),"default_price":price,"is_available":True}
                if not payload["garment_type_id"] or not payload["service_id"]: raise ValueError("اختار القطعة والخدمة.")
                supabase_request("POST","garment_services",payload=payload,prefer="return=minimal")
            elif action == "price":
                combo_id = request.form.get("garment_service_id", "").strip()
                raw_price = request.form.get("price", "").strip()
                if not combo_id or raw_price == "": raise ValueError("اختار القطعة والخدمة واكتب السعر.")
                price = float(raw_price)
                if price < 0 or price > 999999999: raise ValueError("السعر يجب أن يكون صفرًا أو أكبر.")
                supabase_request("POST", "rpc/set_garment_service_price", payload={"p_garment_service_id":combo_id,"p_price":price})
            elif action == "cash_account":
                payload = {"branch_id":branch_id,"code":request.form.get("code","").strip().upper(),"name":request.form.get("name","").strip(),"account_type":request.form.get("account_type","cash"),"opening_balance":"0","is_active":True}
                if not payload["code"] or not payload["name"]: raise ValueError("أدخل كود واسم الخزينة.")
                supabase_request("POST","cash_accounts",payload=payload,prefer="return=minimal")
            else:
                raise ValueError("طلب غير معروف.")
            flash("تم الحفظ بنجاح.", "success")
        except ValueError as exc:
            flash(str(exc), "error")
        except RuntimeError as exc:
            msg=str(exc)
            if msg=="SESSION_EXPIRED":
                return redirect(url_for("logout"))
            flash("تعذر الحفظ. تأكد من صلاحية إدارة الأصناف وأن البيانات غير مكررة.", "error")
        return redirect(url_for("catalog"))
    try:
        categories=supabase_rows("garment_categories",{"select":"id,name,name_en,sort_order,is_active","branch_id":f"eq.{branch_id}","order":"sort_order.asc,name.asc"})
        garments=supabase_rows("garment_types",{"select":"id,name,name_en,category_id,is_active,icon_key","branch_id":f"eq.{branch_id}","order":"name.asc"})
        services=supabase_rows("services",{"select":"id,name,name_en,is_active","branch_id":f"eq.{branch_id}","order":"name.asc"})
        combos=supabase_rows("garment_services",{"select":"id,garment_type_id,service_id,default_price,is_available","branch_id":f"eq.{branch_id}"})
        cash_accounts=supabase_rows("cash_accounts",{"select":"id,code,name,account_type,is_active","branch_id":f"eq.{branch_id}","order":"name.asc"})
    except RuntimeError as exc:
        if str(exc)=="SESSION_EXPIRED": return redirect(url_for("logout"))
        abort(502,description="تعذر تحميل إعدادات الأصناف والخزائن.")
    return render_template("catalog.html",categories=categories,garments=garments,services=services,combos=combos,cash_accounts=cash_accounts)


@app.get("/invoices")
@login_required
def invoices():
    profile = current_profile() or {}
    branch_id = profile.get("branch_id")
    try:
        rows = supabase_rows(
            "invoices",
            {"select":"id,invoice_number,customer_name_snapshot,customer_phone_snapshot,status,subtotal,discount_amount,total_amount,received_at",
             "branch_id":f"eq.{branch_id}","order":"received_at.desc","limit":"100"}
        )
    except RuntimeError as exc:
        if str(exc) == "SESSION_EXPIRED":
            return redirect(url_for("logout"))
        abort(502, description="تعذر تحميل الفواتير.")
    return render_template("invoices.html", invoices=rows)


@app.get("/invoices/<invoice_id>/delivery-receipt")
@login_required
def delivery_receipt(invoice_id):
    """Dedicated delivery receipt, available only after the invoice is delivered."""
    profile = current_profile() or {}
    branch_id = profile.get("branch_id")
    try:
        rows = supabase_rows("invoices", {
            "select":"id,invoice_number,customer_name_snapshot,customer_phone_snapshot,status,total_amount,received_at,delivered_at,notes",
            "id":f"eq.{invoice_id}", "branch_id":f"eq.{branch_id}", "limit":"1"
        })
        if not rows:
            abort(404)
        invoice = rows[0]
        if invoice.get("status") != "delivered":
            abort(409, description="إيصال التسليم متاح بعد تأكيد تسليم الفاتورة فقط.")
        items = supabase_rows("invoice_items", {
            "select":"garment_name_snapshot,service_name_snapshot,quantity,unit_price,line_total",
            "invoice_id":f"eq.{invoice_id}", "branch_id":f"eq.{branch_id}", "order":"sort_order.asc"
        })
        payments = supabase_rows("payments", {
            "select":"amount,payment_status", "invoice_id":f"eq.{invoice_id}",
            "branch_id":f"eq.{branch_id}"
        })
    except RuntimeError as exc:
        if str(exc) == "SESSION_EXPIRED":
            return redirect(url_for("logout"))
        abort(502, description="تعذر تحميل إيصال التسليم.")
    paid = sum(float(x.get("amount") or 0) for x in payments if x.get("payment_status") == "posted")
    total = float(invoice.get("total_amount") or 0)
    return render_template("delivery_receipt.html", invoice=invoice, items=items,
                           paid=paid, balance=max(0, total-paid),
                           quantity=sum(int(x.get("quantity") or 0) for x in items))


@app.get("/invoices/<invoice_id>")
@login_required
def invoice_detail(invoice_id):
    profile = current_profile() or {}
    branch_id = profile.get("branch_id")
    try:
        rows = supabase_rows("invoices", {
            "select":"id,invoice_number,customer_name_snapshot,customer_phone_snapshot,status,subtotal,discount_amount,total_amount,received_at,notes",
            "id":f"eq.{invoice_id}","branch_id":f"eq.{branch_id}","limit":"1"
        })
        if not rows:
            abort(404)
        items = supabase_rows("invoice_items", {
            "select":"id,garment_name_snapshot,service_name_snapshot,quantity,unit_price,line_total,work_status,item_notes",
            "invoice_id":f"eq.{invoice_id}","branch_id":f"eq.{branch_id}","order":"sort_order.asc"
        })
        payments = supabase_rows("payments", {
            "select":"id,payment_number,amount,payment_method,payment_status,paid_at,reference_number",
            "invoice_id":f"eq.{invoice_id}","branch_id":f"eq.{branch_id}","order":"paid_at.asc"
        })
        cash_accounts = supabase_rows("cash_accounts", {
            "select":"id,name,account_type","branch_id":f"eq.{branch_id}","is_active":"eq.true","order":"name.asc"
        })
        status_history = supabase_rows("invoice_status_history", {
            "select":"old_status,new_status,reason,changed_at","invoice_id":f"eq.{invoice_id}","branch_id":f"eq.{branch_id}","order":"changed_at.desc"
        })
    except RuntimeError as exc:
        if str(exc) == "SESSION_EXPIRED":
            return redirect(url_for("logout"))
        abort(502, description="تعذر تحميل تفاصيل الفاتورة.")
    paid = sum(float(x.get("amount") or 0) for x in payments if x.get("payment_status") == "posted")
    balance = max(0, float(rows[0].get("total_amount") or 0) - paid)
    return render_template("invoice_detail.html", invoice=rows[0], items=items, payments=payments,
                           cash_accounts=cash_accounts, paid=paid, balance=balance, status_history=status_history)


@app.post("/api/invoices/<invoice_id>/payments")
@login_required
def api_record_payment(invoice_id):
    if not post_csrf_valid():
        return {"error":"CSRF_INVALID","message":"Your session has expired."}, 400
    body = request.get_json(silent=True) or {}
    try:
        amount = float(body.get("amount", 0))
        if amount <= 0 or amount > 999999999:
            raise ValueError()
    except (TypeError, ValueError):
        return {"error":"INVALID_AMOUNT","message":"أدخل مبلغًا صحيحًا أكبر من صفر."}, 400
    payload = {
        "p_invoice_id": invoice_id,
        "p_cash_account_id": body.get("cash_account_id"),
        "p_amount": amount,
        "p_payment_method": body.get("payment_method", "cash"),
        "p_reference": body.get("reference", ""),
        "p_notes": body.get("notes", ""),
        "p_idempotency_key": body.get("idempotency_key") or secrets.token_urlsafe(24),
    }
    try:
        result = supabase_request("POST", "rpc/record_invoice_payment", payload=payload)
        return {"ok": True, "payment": result}, 201
    except RuntimeError as exc:
        msg = str(exc)
        if msg == "SESSION_EXPIRED": return {"error":"SESSION_EXPIRED"}, 401
        if "PAYMENT_EXCEEDS_BALANCE" in msg: return {"error":"PAYMENT_EXCEEDS_BALANCE","message":"المبلغ أكبر من المتبقي على الفاتورة."}, 409
        if "FORBIDDEN" in msg: return {"error":"FORBIDDEN","message":"You do not have permission to record payments."}, 403
        if "CASH_ACCOUNT_INVALID" in msg: return {"error":"CASH_ACCOUNT_INVALID","message":"اختر خزينة نشطة صحيحة."}, 400
        return {"error":"PAYMENT_FAILED","message":"Payment could not be recorded. No financial transaction was posted."}, 502


@app.post("/api/invoice-items/<item_id>/work-status")
@login_required
def api_update_work_status(item_id):
    if not post_csrf_valid():
        return {"error":"CSRF_INVALID","message":"Your session has expired."}, 400
    body=request.get_json(silent=True) or {}
    status=str(body.get("work_status") or "")
    if status not in ("pending","in_progress","completed"):
        return {"error":"INVALID_WORK_STATUS","message":"Invalid work status."}, 400
    try:
        result=supabase_request("POST","rpc/update_invoice_item_work_status",payload={
            "p_item_id":item_id,"p_work_status":status,"p_reason":str(body.get("reason") or "")
        })
        return {"ok":True,"result":result},200
    except RuntimeError as exc:
        msg=str(exc)
        if msg=="SESSION_EXPIRED": return {"error":"SESSION_EXPIRED"},401
        if "FORBIDDEN" in msg: return {"error":"FORBIDDEN","message":"You do not have permission to update workflow status."},403
        if "INVOICE_LOCKED" in msg: return {"error":"INVOICE_LOCKED","message":"الفاتورة مغلقة أو تم تسليمها."},409
        return {"error":"WORKFLOW_FAILED","message":"Could not update item status."},502

@app.post("/api/invoices/<invoice_id>/deliver")
@login_required
def api_deliver_invoice(invoice_id):
    if not post_csrf_valid():
        return {"error":"CSRF_INVALID","message":"Your session has expired."},400
    body=request.get_json(silent=True) or {}
    try:
        result=supabase_request("POST","rpc/deliver_laundry_invoice",payload={
            "p_invoice_id":invoice_id,"p_reason":str(body.get("reason") or "")
        })
        return {"ok":True,"result":result},200
    except RuntimeError as exc:
        msg=str(exc)
        if msg=="SESSION_EXPIRED": return {"error":"SESSION_EXPIRED"},401
        if "FORBIDDEN" in msg: return {"error":"FORBIDDEN","message":"You do not have permission to record delivery."},403
        if "INVOICE_NOT_READY" in msg or "ITEMS_NOT_COMPLETED" in msg:
            return {"error":"NOT_READY","message":"The invoice cannot be delivered until all items are completed."},409
        return {"error":"DELIVERY_FAILED","message":"Could not record delivery."},502

@app.post("/api/invoices")
@login_required
def api_create_invoice():
    if not post_csrf_valid():
        return {"error":"CSRF_INVALID","message":"Your session has expired. حدّث الصفحة وحاول مرة أخرى."}, 400
    if not current_profile() or not current_profile().get("branch_id"):
        return {"error":"BRANCH_REQUIRED"}, 403
    body = request.get_json(silent=True) or {}
    items = body.get("items")
    if not isinstance(items, list) or not items:
        return {"error":"ITEMS_REQUIRED","message":"Add at least one item."}, 400
    if len(items) > 100:
        return {"error":"TOO_MANY_ITEMS","message":"The maximum is 100 invoice items."}, 400
    payload = {
        "p_customer_name": str(body.get("customer_name") or ""),
        "p_customer_phone": str(body.get("customer_phone") or ""),
        "p_items": items,
        "p_discount_type": body.get("discount_type", "value"),
        "p_discount_value": body.get("discount_value", 0),
        "p_notes": str(body.get("notes") or ""),
        "p_idempotency_key": str(body.get("idempotency_key") or secrets.token_urlsafe(24)),
    }
    try:
        result = supabase_request("POST", "rpc/create_laundry_invoice", payload=payload)
        return {"ok":True,"invoice":result}, 201
    except RuntimeError as exc:
        msg = str(exc)
        if msg == "SESSION_EXPIRED":
            return {"error":"SESSION_EXPIRED","message":"انتهت الجلسة، سجّل الدخول مرة أخرى."}, 401
        if "FORBIDDEN" in msg:
            return {"error":"FORBIDDEN","message":"You do not have permission to create invoices."}, 403
        if "INVALID_OR_UNAVAILABLE_SERVICE" in msg:
            return {"error":"CATALOG_CHANGED","message":"إحدى الخدمات لم تعد متاحة. حدّث الكاشير وحاول مرة أخرى."}, 409
        if "SERVICE_PRICE_REQUIRED" in msg:
            return {"error":"SERVICE_PRICE_REQUIRED","message":"A service price is missing. Open Catalog & Services and set the price first."}, 409
        return {"error":"INVOICE_CREATE_FAILED","message":"تعذر حفظ الفاتورة. راجع الأصناف والخدمات والصلاحيات ثم حاول مرة أخرى."}, 502


@app.get("/")
@login_required
def dashboard():
    profile = current_profile() or {}
    return render_template("dashboard.html", profile=profile)


@app.get("/cashier")
@login_required
def cashier():
    profile = current_profile() or {}
    branch_id = profile.get("branch_id")
    if not branch_id:
        abort(403, description="حساب المستخدم غير مرتبط بفرع.")
    try:
        categories = supabase_rows("garment_categories", {"select":"id,name,name_en,sort_order", "branch_id":f"eq.{branch_id}", "is_active":"eq.true", "order":"sort_order.asc,name.asc"})
        garments = supabase_rows("garment_types", {"select":"id,name,name_en,category_id,icon_key,sort_order", "branch_id":f"eq.{branch_id}", "is_active":"eq.true", "order":"sort_order.asc,name.asc"})
        services = supabase_rows("services", {"select":"id,name,name_en,sort_order", "branch_id":f"eq.{branch_id}", "is_active":"eq.true", "order":"sort_order.asc,name.asc"})
        combinations = supabase_rows("garment_services", {"select":"id,garment_type_id,service_id,default_price", "branch_id":f"eq.{branch_id}", "is_available":"eq.true"})
        prices = supabase_rows("service_prices", {"select":"garment_service_id,price,effective_from,effective_to", "branch_id":f"eq.{branch_id}", "order":"effective_from.desc"})
    except RuntimeError as exc:
        if str(exc) == "SESSION_EXPIRED":
            return redirect(url_for("logout"))
        abort(502, description="تعذر تحميل الأصناف والخدمات. تأكد من الاتصال والصلاحيات.")
    return render_template("cashier.html", categories=categories, garments=garments, services=services, combinations=combinations, prices=prices)


@app.route("/users", methods=["GET", "POST"])
@login_required
@csrf_checked
def users():
    token = active_access_token()
    if not token:
        return redirect(url_for("logout"))
    if request.method == "POST":
        payload = {
            "action": "create_user",
            "username": request.form.get("username", "").strip().lower(),
            "full_name": request.form.get("full_name", "").strip(),
            "password": request.form.get("password", ""),
            "role_code": request.form.get("role_code", ""),
            "branch_id": request.form.get("branch_id", ""),
        }
        data, status = function_call(payload, token)
        if status == 200:
            flash("تم إنشاء حساب المستخدم بنجاح.", "success")
        else:
            messages = {
                "USERNAME_ALREADY_EXISTS": "اسم المستخدم مستخدم بالفعل.",
                "FORBIDDEN": "ليس لديك صلاحية تنفيذ العملية.",
                "FORBIDDEN_ROLE_ASSIGNMENT": "لا يمكنك إنشاء حساب بهذا الدور.",
                "INVALID_USER_DETAILS": "راجع البيانات: اسم المستخدم 3–32 حرفًا إنجليزيًا/أرقامًا، وكلمة المرور 8 أحرف على الأقل.",
            }
            flash(messages.get(data.get("error"), "تعذر إنشاء المستخدم. راجع البيانات وحاول مرة أخرى."), "error")
        return redirect(url_for("users"))
    data, status = function_call({"action": "list_users"}, token)
    if status != 200:
        if status == 401:
            return redirect(url_for("logout"))
        abort(403 if status == 403 else 502, description="تعذر تحميل المستخدمين أو لا توجد صلاحية.")
    return render_template("users.html", users=data.get("users", []), roles=data.get("roles", []), branches=data.get("branches", []))


@app.post("/users/<user_id>/status")
@login_required
@csrf_checked
def user_status(user_id):
    token = active_access_token()
    if not token:
        return redirect(url_for("logout"))
    active = request.form.get("is_active") == "1"
    data, status = function_call({"action": "set_active", "user_id": user_id, "is_active": active}, token)
    flash("تم تحديث حالة الحساب." if status == 200 else "تعذر تحديث حالة الحساب.", "success" if status == 200 else "error")
    return redirect(url_for("users"))


@app.post("/users/<user_id>/password")
@login_required
@csrf_checked
def user_password(user_id):
    token = active_access_token()
    if not token:
        return redirect(url_for("logout"))
    data, status = function_call({"action": "set_password", "user_id": user_id, "password": request.form.get("password", "")}, token)
    flash("تم تغيير كلمة المرور." if status == 200 else "تعذر تغيير كلمة المرور.", "success" if status == 200 else "error")
    return redirect(url_for("users"))


@app.post("/users/<user_id>/username")
@login_required
@csrf_checked
def user_username(user_id):
    token = active_access_token()
    if not token:
        return redirect(url_for("logout"))
    data, status = function_call({"action": "set_username", "user_id": user_id, "username": request.form.get("username", "")}, token)
    flash("تم تحديث اسم المستخدم." if status == 200 else "تعذر تحديث اسم المستخدم.", "success" if status == 200 else "error")
    return redirect(url_for("users"))



@app.route("/finance", methods=["GET", "POST"])
@login_required
@csrf_checked
def finance():
    from decimal import Decimal, InvalidOperation
    profile = current_profile() or {}
    branch_id = profile.get("branch_id")
    if not branch_id:
        abort(403, description="حساب المستخدم غير مرتبط بفرع.")

    if request.method == "POST":
        action = request.form.get("action", "")
        try:
            if action == "cash_account":
                code = request.form.get("code", "").strip().upper()
                name = request.form.get("name", "").strip()
                account_type = request.form.get("account_type", "cash")
                if not code or not name:
                    raise ValueError("أدخل كود واسم الخزينة.")
                if account_type not in ("cash", "bank", "visa", "electronic"):
                    raise ValueError("نوع الخزينة غير صحيح.")
                supabase_request("POST", "cash_accounts", payload={
                    "branch_id": branch_id, "code": code, "name": name,
                    "account_type": account_type, "opening_balance": "0", "is_active": True
                }, prefer="return=minimal")
                flash("تم إنشاء الخزينة. رصيدها يبدأ من صفر.", "success")
            elif action == "expense_category":
                name = request.form.get("name", "").strip()
                if not name:
                    raise ValueError("اكتب اسم تصنيف المصروف.")
                supabase_request("POST", "expense_categories", payload={
                    "branch_id": branch_id, "name": name, "is_active": True
                }, prefer="return=minimal")
                flash("تم إضافة تصنيف المصروف.", "success")
            elif action == "expense":
                amount = Decimal(request.form.get("amount", "0").strip())
                if not amount.is_finite() or amount <= 0:
                    raise ValueError("أدخل مبلغًا صحيحًا أكبر من صفر.")
                result = supabase_request("POST", "rpc/create_laundry_expense", payload={
                    "p_category_id": request.form.get("category_id") or None,
                    "p_description": request.form.get("description", "").strip(),
                    "p_amount": str(amount),
                    "p_cash_account_id": request.form.get("cash_account_id"),
                    "p_expense_date": request.form.get("expense_date") or None,
                    "p_notes": request.form.get("notes", "").strip() or None,
                })
                status = (result or {}).get("approval_status") if isinstance(result, dict) else None
                flash("تم تسجيل المصروف وخصمه من الخزينة." if status == "approved" else "تم تسجيل المصروف وهو في انتظار الاعتماد.", "success")
            elif action == "approve_expense":
                supabase_request("POST", "rpc/approve_laundry_expense", payload={
                    "p_expense_id": request.form.get("expense_id"), "p_approve": True,
                    "p_reason": request.form.get("reason", "").strip() or None
                })
                flash("تم اعتماد المصروف وتسجيل حركة الخروج.", "success")
            elif action == "reject_expense":
                supabase_request("POST", "rpc/approve_laundry_expense", payload={
                    "p_expense_id": request.form.get("expense_id"), "p_approve": False,
                    "p_reason": request.form.get("reason", "").strip() or None
                })
                flash("تم رفض المصروف دون التأثير على رصيد الخزينة.", "success")
            elif action == "transfer":
                amount = Decimal(request.form.get("amount", "0").strip())
                if not amount.is_finite() or amount <= 0:
                    raise ValueError("أدخل مبلغ تحويل صحيح أكبر من صفر.")
                supabase_request("POST", "rpc/transfer_laundry_cash", payload={
                    "p_from_account_id": request.form.get("from_account_id"),
                    "p_to_account_id": request.form.get("to_account_id"),
                    "p_amount": str(amount),
                    "p_reason": request.form.get("reason", "").strip() or None,
                })
                flash("تم التحويل بين الخزائن وتسجيل طرفي الحركة.", "success")
            else:
                raise ValueError("نوع العملية غير معروف.")
        except (ValueError, InvalidOperation) as exc:
            flash(str(exc) or "راجع المبلغ المدخل.", "error")
        except RuntimeError as exc:
            msg = str(exc)
            if msg == "SESSION_EXPIRED":
                return redirect(url_for("logout"))
            if "INSUFFICIENT_CASH" in msg:
                flash("الرصيد المتاح في الخزينة لا يكفي لتنفيذ العملية.", "error")
            elif "FORBIDDEN" in msg or "42501" in msg:
                flash("ليس لديك الصلاحية اللازمة لتنفيذ هذه العملية.", "error")
            elif "CASH_ACCOUNT_INVALID" in msg:
                flash("اختر خزينة نشطة وصحيحة.", "error")
            elif "CATEGORY_INVALID" in msg:
                flash("تصنيف المصروف غير صحيح.", "error")
            elif "EXPENSE_NOT_PENDING" in msg:
                flash("هذا المصروف ليس في حالة انتظار الاعتماد.", "error")
            else:
                flash("تعذر تنفيذ العملية. لم يتم اعتماد حركة مالية غير مكتملة.", "error")
        return redirect(url_for("finance"))

    try:
        accounts = supabase_rows("cash_accounts", {
            "select": "id,code,name,account_type,opening_balance,is_active",
            "branch_id": f"eq.{branch_id}", "order": "name.asc"
        })
        transactions = supabase_rows("cash_transactions", {
            "select": "id,cash_account_id,transaction_type,direction,amount,reference,description,created_at",
            "branch_id": f"eq.{branch_id}", "order": "created_at.desc", "limit": "100"
        })
        balance_rows = supabase_request("POST", "rpc/get_laundry_cash_balances", payload={})
        categories = supabase_rows("expense_categories", {
            "select": "id,name,is_active", "branch_id": f"eq.{branch_id}", "order": "name.asc"
        })
        expenses = supabase_rows("expenses", {
            "select": "id,expense_number,category_id,description,amount,cash_account_id,expense_date,approval_status,notes,created_at",
            "branch_id": f"eq.{branch_id}", "order": "created_at.desc", "limit": "100"
        })
    except RuntimeError as exc:
        if str(exc) == "SESSION_EXPIRED":
            return redirect(url_for("logout"))
        abort(502, description="تعذر تحميل بيانات الخزائن والمصروفات. راجع صلاحيات العرض والاتصال.")

    balances = {row.get("cash_account_id"): Decimal(str(row.get("balance") or "0"))
                for row in (balance_rows if isinstance(balance_rows, list) else [])}
    account_map = {a["id"]: a for a in accounts}
    for account in accounts:
        balances.setdefault(account["id"], Decimal(str(account.get("opening_balance") or "0")))
    category_map = {c["id"]: c["name"] for c in categories}
    for expense in expenses:
        expense["category_name"] = category_map.get(expense.get("category_id"), "بدون تصنيف")
        expense["account_name"] = account_map.get(expense.get("cash_account_id"), {}).get("name", "—")
    for tx in transactions:
        tx["account_name"] = account_map.get(tx.get("cash_account_id"), {}).get("name", "—")
    total_balance = sum(balances.values(), Decimal("0"))
    return render_template("finance.html", accounts=accounts, balances=balances,
                           categories=[c for c in categories if c.get("is_active")],
                           expenses=expenses, transactions=transactions,
                           total_balance=total_balance)


@app.get("/reports")
@login_required
def reports():
    """Branch-scoped operational and cash reports; values come from posted records."""
    profile = current_profile() or {}
    branch_id = profile.get("branch_id")
    if not branch_id:
        abort(403, description="حساب المستخدم غير مرتبط بفرع.")

    today = date.today()
    default_start = today.replace(day=1)
    try:
        start_date = date.fromisoformat(request.args.get("from", default_start.isoformat()))
        end_date = date.fromisoformat(request.args.get("to", today.isoformat()))
        if end_date < start_date:
            raise ValueError("نهاية الفترة تسبق بدايتها.")
        if (end_date - start_date).days > 366:
            raise ValueError("الفترة القصوى للتقرير سنة واحدة.")
    except ValueError as exc:
        flash(str(exc) or "تاريخ التقرير غير صحيح.", "error")
        start_date, end_date = default_start, today

    try:
        data = supabase_request("POST", "rpc/get_laundry_reports", payload={
            "p_from": start_date.isoformat(), "p_to": end_date.isoformat()
        })
    except RuntimeError as exc:
        if str(exc) == "SESSION_EXPIRED":
            return redirect(url_for("logout"))
        if "FORBIDDEN" in str(exc) or "42501" in str(exc):
            abort(403, description="لا تملك صلاحية عرض التقارير المالية والتشغيلية.")
        abort(502, description="تعذر تحميل التقارير. تحقق من الاتصال والصلاحيات.")

    from decimal import Decimal
    money = lambda value: Decimal(str(value or "0"))
    invoice_count = int(data.get("invoice_count") or 0)
    invoice_value = money(data.get("invoice_value"))
    collected = money(data.get("collected"))
    expense_total = money(data.get("expense_total"))
    net_cash = collected - expense_total
    payment_count = int(data.get("payment_count") or 0)
    expense_count = int(data.get("expense_count") or 0)
    status_labels = {"received":"مستلمة", "in_progress":"قيد التشغيل", "ready":"جاهزة", "delivered":"تم التسليم", "cancelled":"ملغاة"}
    pipeline_data = data.get("pipeline") or {}
    pipeline_counts = {key: int(pipeline_data.get(key) or 0) for key in ("received", "in_progress", "ready", "delivered", "cancelled")}
    daily_rows = data.get("daily") or []
    max_daily = max([max(money(v.get("collected")), money(v.get("expenses"))) for v in daily_rows] or [Decimal("0")])
    for row in daily_rows:
        row["collected"] = money(row.get("collected"))
        row["expenses"] = money(row.get("expenses"))
        row["collected_width"] = float(row["collected"] / max_daily * 100) if max_daily else 0
        row["expenses_width"] = float(row["expenses"] / max_daily * 100) if max_daily else 0
    recent_expenses = data.get("recent_expenses") or []
    return render_template("reports.html", start_date=start_date.isoformat(), end_date=end_date.isoformat(),
        invoice_count=invoice_count, invoice_value=invoice_value, collected=collected,
        expense_total=expense_total, net_cash=net_cash, pipeline_counts=pipeline_counts,
        status_labels=status_labels, daily_rows=daily_rows, recent_expenses=recent_expenses,
        payment_count=payment_count, expense_count=expense_count)


# Human resources, attendance, leave and payroll
def write_hr_audit(action: str, entity_table: str, entity_id: str | None = None, values: dict | None = None) -> None:
    """Best-effort UI audit event; financial payroll events are audited atomically in SQL RPCs."""
    profile = current_profile() or {}
    try:
        supabase_request("POST", "audit_logs", payload={
            "branch_id": profile.get("branch_id"), "actor_user_id": profile.get("id"),
            "action": action, "entity_table": entity_table, "entity_id": str(entity_id) if entity_id else None,
            "new_values": values or {},
        }, prefer="return=minimal")
    except RuntimeError:
        # The primary HR transaction is already committed; never pretend it was rolled back.
        pass

@app.route("/hr", methods=["GET", "POST"])
@login_required
@csrf_checked
def hr_home():
    profile = current_profile() or {}
    branch_id = profile.get("branch_id")
    if not branch_id:
        abort(403, description="حساب المستخدم غير مرتبط بفرع.")
    if request.method == "POST":
        action = request.form.get("action", "")
        try:
            if action == "department":
                name = request.form.get("name", "").strip()
                if not name:
                    raise ValueError("اكتب اسم القسم.")
                created = supabase_request("POST", "departments", payload={"branch_id": branch_id, "name": name, "is_active": True}, prefer="return=representation")
                write_hr_audit("department_created", "departments", (created[0].get("id") if isinstance(created, list) and created else None), {"name": name})
                flash("تمت إضافة القسم.", "success")
            elif action == "shift":
                name = request.form.get("name", "").strip()
                start_time = request.form.get("start_time", "")
                end_time = request.form.get("end_time", "")
                grace = int(request.form.get("grace_minutes", "0"))
                if not name or not start_time or not end_time or grace < 0 or grace > 240:
                    raise ValueError("راجع اسم الوردية ومواعيدها وفترة السماح.")
                created = supabase_request("POST", "shifts", payload={"branch_id": branch_id, "name": name, "start_time": start_time, "end_time": end_time, "grace_minutes": grace, "is_active": True}, prefer="return=representation")
                write_hr_audit("shift_created", "shifts", (created[0].get("id") if isinstance(created, list) and created else None), {"name": name})
                flash("تمت إضافة الوردية.", "success")
            elif action == "employee":
                full_name = request.form.get("full_name", "").strip()
                employee_code = request.form.get("employee_code", "").strip().upper()
                salary = Decimal(request.form.get("base_salary", "0").strip())
                if not full_name or not employee_code or not salary.is_finite() or salary < 0:
                    raise ValueError("أدخل اسم الموظف وكوده وراتبًا أساسيًا صحيحًا.")
                payload = {
                    "branch_id": branch_id, "full_name": full_name, "employee_code": employee_code,
                    "phone": request.form.get("phone", "").strip() or None,
                    "national_id": request.form.get("national_id", "").strip() or None,
                    "department_id": request.form.get("department_id") or None,
                    "job_title": request.form.get("job_title", "").strip() or None,
                    "hire_date": request.form.get("hire_date") or None,
                    "base_salary": str(salary), "employment_status": "active",
                    "address": request.form.get("address", "").strip() or None,
                    "notes": request.form.get("notes", "").strip() or None,
                }
                created = supabase_request("POST", "employees", payload=payload, prefer="return=representation")
                write_hr_audit("employee_created", "employees", (created[0].get("id") if isinstance(created, list) and created else None), {"employee_code": employee_code, "full_name": full_name})
                flash("تم تسجيل الموظف.", "success")
            elif action == "advance":
                amount = Decimal(request.form.get("amount", "0").strip())
                if not amount.is_finite() or amount <= 0:
                    raise ValueError("أدخل مبلغ سلفة صحيحًا أكبر من صفر.")
                supabase_request("POST", "rpc/issue_employee_advance", payload={
                    "p_employee_id": request.form.get("employee_id"),
                    "p_cash_account_id": request.form.get("cash_account_id"),
                    "p_amount": str(amount), "p_reason": request.form.get("reason", "").strip() or None,
                    "p_advance_date": request.form.get("advance_date") or None,
                })
                flash("تم صرف السلفة وتسجيل حركة خروج من الخزينة.", "success")
            elif action == "repay_advance":
                amount = Decimal(request.form.get("amount", "0").strip())
                if not amount.is_finite() or amount <= 0:
                    raise ValueError("أدخل مبلغ سداد صحيحًا أكبر من صفر.")
                supabase_request("POST", "rpc/repay_employee_advance", payload={
                    "p_advance_id": request.form.get("advance_id"),
                    "p_cash_account_id": request.form.get("cash_account_id"),
                    "p_amount": str(amount), "p_repayment_date": request.form.get("repayment_date") or None,
                    "p_notes": request.form.get("notes", "").strip() or None,
                })
                flash("تم تسجيل سداد السلفة وإضافة المبلغ إلى الخزينة.", "success")
            else:
                raise ValueError("نوع العملية غير معروف.")
        except (ValueError, InvalidOperation) as exc:
            flash(str(exc) or "راجع البيانات المدخلة.", "error")
        except RuntimeError as exc:
            msg = str(exc)
            if msg == "SESSION_EXPIRED":
                return redirect(url_for("logout"))
            if "INSUFFICIENT_CASH" in msg:
                flash("رصيد الخزينة لا يكفي لتنفيذ العملية.", "error")
            elif "FORBIDDEN" in msg or "42501" in msg:
                flash("ليس لديك صلاحية تنفيذ العملية.", "error")
            elif "EMPLOYEE_INVALID" in msg:
                flash("الموظف غير نشط أو لا يتبع هذا الفرع.", "error")
            elif "REPAYMENT_EXCEEDS_BALANCE" in msg:
                flash("مبلغ السداد أكبر من الرصيد المتبقي للسلفة.", "error")
            elif "ADVANCE_NOT_OPEN" in msg:
                flash("السلفة غير مفتوحة أو تم سدادها بالكامل.", "error")
            elif "CASH_ACCOUNT_INVALID" in msg:
                flash("اختر خزينة نشطة وصحيحة.", "error")
            else:
                flash("تعذر تنفيذ العملية. راجع البيانات والصلاحيات.", "error")
        return redirect(url_for("hr_home"))

    try:
        employees = supabase_rows("employees", {"select":"id,employee_code,full_name,phone,department_id,job_title,hire_date,base_salary,employment_status", "branch_id":f"eq.{branch_id}", "order":"full_name.asc"})
        departments = supabase_rows("departments", {"select":"id,name,is_active", "branch_id":f"eq.{branch_id}", "order":"name.asc"})
        shifts = supabase_rows("shifts", {"select":"id,name,start_time,end_time,grace_minutes,is_active", "branch_id":f"eq.{branch_id}", "order":"start_time.asc"})
        advances = supabase_rows("employee_advances", {"select":"id,employee_id,amount,advance_date,status,reason", "branch_id":f"eq.{branch_id}", "status":"in.(open,partially_repaid)", "order":"advance_date.desc"})
        repayments = supabase_rows("advance_repayments", {"select":"advance_id,amount", "branch_id":f"eq.{branch_id}"})
        accounts = supabase_rows("cash_accounts", {"select":"id,name,opening_balance,is_active", "branch_id":f"eq.{branch_id}", "is_active":"eq.true", "order":"name.asc"})
    except RuntimeError as exc:
        if str(exc) == "SESSION_EXPIRED":
            return redirect(url_for("logout"))
        abort(502, description="تعذر تحميل بيانات الموارد البشرية. تحقق من صلاحياتك والاتصال.")
    dept_map = {d["id"]: d["name"] for d in departments}
    emp_map = {e["id"]: e for e in employees}
    repaid_map = {}
    for row in repayments:
        repaid_map[row["advance_id"]] = repaid_map.get(row["advance_id"], Decimal("0")) + Decimal(str(row["amount"]))
    for adv in advances:
        adv["employee_name"] = emp_map.get(adv["employee_id"], {}).get("full_name", "—")
        adv["remaining"] = Decimal(str(adv["amount"])) - repaid_map.get(adv["id"], Decimal("0"))
    for emp in employees:
        emp["department_name"] = dept_map.get(emp.get("department_id"), "بدون قسم")
    return render_template("hr.html", employees=employees, departments=departments, shifts=shifts,
                           advances=advances, accounts=accounts, active_employees=[e for e in employees if e.get("employment_status")=="active"])


@app.route("/hr/attendance", methods=["GET", "POST"])
@login_required
@csrf_checked
def hr_attendance():
    profile = current_profile() or {}
    branch_id = profile.get("branch_id")
    if not branch_id:
        abort(403, description="حساب المستخدم غير مرتبط بفرع.")
    work_date = request.form.get("work_date") if request.method == "POST" else request.args.get("date")
    try:
        selected_date = date.fromisoformat(work_date) if work_date else date.today()
    except ValueError:
        selected_date = date.today()
    if request.method == "POST":
        employee_id = request.form.get("employee_id")
        status = request.form.get("attendance_status", "present")
        if status not in ("present", "absent", "late", "leave", "holiday"):
            flash("حالة الحضور غير صحيحة.", "error")
            return redirect(url_for("hr_attendance", date=selected_date.isoformat()))
        try:
            payload = {
                "branch_id": branch_id, "employee_id": employee_id, "work_date": selected_date.isoformat(),
                "attendance_status": status, "shift_id": request.form.get("shift_id") or None,
                "notes": request.form.get("notes", "").strip() or None,
                "recorded_by": (current_profile() or {}).get("id"),
            }
            for field in ("check_in", "check_out"):
                raw = request.form.get(field, "").strip()
                if raw:
                    from datetime import datetime
                    local_tz = datetime.now().astimezone().tzinfo
                    payload[field] = datetime.combine(selected_date, datetime.strptime(raw, '%H:%M').time()).replace(tzinfo=local_tz).isoformat()
                else:
                    payload[field] = None
            existing = supabase_rows("attendance", {"select":"id", "branch_id":f"eq.{branch_id}", "employee_id":f"eq.{employee_id}", "work_date":f"eq.{selected_date.isoformat()}", "limit":"1"})
            if existing:
                supabase_request("PATCH", "attendance", payload=payload, params={"id":f"eq.{existing[0]['id']}"}, prefer="return=minimal")
                attendance_id = existing[0]["id"]
            else:
                created = supabase_request("POST", "attendance", payload=payload, prefer="return=representation")
                attendance_id = created[0].get("id") if isinstance(created, list) and created else None
            write_hr_audit("attendance_saved", "attendance", attendance_id, {"employee_id": employee_id, "work_date": selected_date.isoformat(), "status": status})
            flash("تم حفظ سجل الحضور.", "success")
        except (ValueError, RuntimeError) as exc:
            if str(exc) == "SESSION_EXPIRED":
                return redirect(url_for("logout"))
            flash("تعذر حفظ الحضور. تحقق من صلاحية الموارد البشرية والوردية.", "error")
        return redirect(url_for("hr_attendance", date=selected_date.isoformat()))
    try:
        employees = supabase_rows("employees", {"select":"id,employee_code,full_name,department_id,employment_status", "branch_id":f"eq.{branch_id}", "employment_status":"eq.active", "order":"full_name.asc"})
        shifts = supabase_rows("shifts", {"select":"id,name,start_time,end_time", "branch_id":f"eq.{branch_id}", "is_active":"eq.true", "order":"start_time.asc"})
        attendance = supabase_rows("attendance", {"select":"id,employee_id,attendance_status,check_in,check_out,shift_id,notes", "branch_id":f"eq.{branch_id}", "work_date":f"eq.{selected_date.isoformat()}"})
    except RuntimeError as exc:
        if str(exc) == "SESSION_EXPIRED": return redirect(url_for("logout"))
        abort(502, description="تعذر تحميل الحضور والانصراف.")
    att_map = {a["employee_id"]: a for a in attendance}
    for emp in employees:
        emp["attendance"] = att_map.get(emp["id"], {})
    return render_template("attendance.html", employees=employees, shifts=shifts, selected_date=selected_date.isoformat())


@app.route("/hr/leaves", methods=["GET", "POST"])
@login_required
@csrf_checked
def hr_leaves():
    profile = current_profile() or {}; branch_id = profile.get("branch_id")
    if not branch_id: abort(403, description="حساب المستخدم غير مرتبط بفرع.")
    if request.method == "POST":
        action = request.form.get("action")
        try:
            if action == "request":
                start = date.fromisoformat(request.form.get("start_date", "")); end = date.fromisoformat(request.form.get("end_date", ""))
                if end < start: raise ValueError("تاريخ نهاية الإجازة يسبق بدايتها.")
                created = supabase_request("POST", "leave_requests", payload={
                    "branch_id":branch_id,"employee_id":request.form.get("employee_id"),"leave_type":request.form.get("leave_type"),
                    "start_date":start.isoformat(),"end_date":end.isoformat(),"reason":request.form.get("reason","").strip() or None,
                    "status":"pending","requested_by":profile.get("id")
                }, prefer="return=representation")
                write_hr_audit("leave_requested", "leave_requests", (created[0].get("id") if isinstance(created, list) and created else None), {"employee_id": request.form.get("employee_id"), "start_date": start.isoformat(), "end_date": end.isoformat()})
                flash("تم تسجيل طلب الإجازة.", "success")
            elif action in ("approve", "reject"):
                supabase_request("PATCH", "leave_requests", payload={"status":"approved" if action=="approve" else "rejected", "decided_by":profile.get("id"), "decided_at":datetime.now(timezone.utc).isoformat()}, params={"id":f"eq.{request.form.get('leave_id')}"}, prefer="return=minimal")
                write_hr_audit("leave_" + action, "leave_requests", request.form.get("leave_id"), {"status": "approved" if action=="approve" else "rejected"})
                flash("تم تحديث قرار طلب الإجازة.", "success")
            else: raise ValueError("عملية غير معروفة.")
        except (ValueError, RuntimeError) as exc:
            if str(exc)=="SESSION_EXPIRED": return redirect(url_for("logout"))
            flash("تعذر تنفيذ طلب الإجازة. تحقق من البيانات والصلاحيات.", "error")
        return redirect(url_for("hr_leaves"))
    try:
        employees = supabase_rows("employees", {"select":"id,employee_code,full_name", "branch_id":f"eq.{branch_id}", "order":"full_name.asc"})
        leaves = supabase_rows("leave_requests", {"select":"id,employee_id,leave_type,start_date,end_date,reason,status,created_at", "branch_id":f"eq.{branch_id}", "order":"created_at.desc", "limit":"100"})
    except RuntimeError as exc:
        if str(exc)=="SESSION_EXPIRED": return redirect(url_for("logout"))
        abort(502, description="تعذر تحميل طلبات الإجازات.")
    emap={e["id"]:e for e in employees}
    for leave in leaves: leave["employee_name"]=emap.get(leave["employee_id"],{}).get("full_name","—")
    return render_template("leaves.html", employees=employees, leaves=leaves)


@app.route("/hr/payroll", methods=["GET", "POST"])
@login_required
@csrf_checked
def hr_payroll():
    profile=current_profile() or {}; branch_id=profile.get("branch_id")
    if not branch_id: abort(403, description="حساب المستخدم غير مرتبط بفرع.")
    if request.method=="POST":
        try:
            start_date=date.fromisoformat(request.form.get("start_date", ""))
            end_date=date.fromisoformat(request.form.get("end_date", ""))
            if end_date < start_date or (end_date-start_date).days > 366:
                raise ValueError("راجع فترة المسير؛ يجب ألا تتجاوز 366 يومًا.")
            employees=supabase_rows("employees", {"select":"id,base_salary", "branch_id":f"eq.{branch_id}", "employment_status":"eq.active"})
            summary=supabase_request("POST", "rpc/get_attendance_payroll_summary", payload={"p_start_date":start_date.isoformat(),"p_end_date":end_date.isoformat()})
            attendance_map={row["employee_id"]:row for row in (summary or {}).get("employees", [])}
            adjustments=[]
            for emp in employees:
                eid=emp["id"]
                additions=Decimal(request.form.get(f"add_{eid}","0") or "0")
                deductions=Decimal(request.form.get(f"ded_{eid}","0") or "0")
                advance_deduction=Decimal(request.form.get(f"adv_{eid}","0") or "0")
                if any(not x.is_finite() or x<0 for x in (additions,deductions,advance_deduction)):
                    raise ValueError("قيم الإضافات والخصومات يجب أن تكون أرقامًا موجبة أو صفرًا.")
                auto=attendance_map.get(eid,{})
                adjustments.append({"employee_id":eid,"additions":str(additions),"deductions":str(deductions),"advances_deduction":str(advance_deduction),
                    "attendance_present_days":int(auto.get("present_days",0)),"attendance_absent_days":int(auto.get("absent_days",0)),
                    "attendance_late_minutes":int(auto.get("late_minutes",0)),"attendance_overtime_minutes":int(auto.get("overtime_minutes",0)),
                    "attendance_absence_deduction":str(auto.get("absence_deduction",0)),"attendance_late_deduction":str(auto.get("late_deduction",0)),
                    "attendance_overtime_addition":str(auto.get("overtime_addition",0)),"notes":request.form.get(f"note_{eid}","").strip()})
            result=supabase_request("POST", "rpc/create_payroll_period", payload={
                "p_period_name":request.form.get("period_name","" ).strip(),
                "p_start_date":start_date.isoformat(),"p_end_date":end_date.isoformat(),"p_adjustments":adjustments})
            flash("تم إنشاء مسير الرواتب مع احتساب الحضور والتأخير والإضافي والغياب تلقائيًا. راجعه ثم اعتمده.", "success")
            return redirect(url_for("hr_payroll_detail", period_id=result.get("payroll_period_id")))
        except (ValueError, InvalidOperation) as exc:
            flash(str(exc) or "راجع قيم الرواتب.", "error")
        except RuntimeError as exc:
            if str(exc)=="SESSION_EXPIRED": return redirect(url_for("logout"))
            msg=str(exc)
            if "ADVANCE_DEDUCTION_EXCEEDS_BALANCE" in msg: flash("خصم السلف أكبر من الرصيد المستحق على الموظف.","error")
            elif "PERIOD_EXISTS" in msg: flash("اسم مسير الرواتب مستخدم بالفعل.","error")
            elif "NEGATIVE_NET_SALARY" in msg: flash("صافي راتب أحد الموظفين أصبح أقل من صفر.","error")
            elif "FORBIDDEN" in msg or "42501" in msg: flash("ليس لديك صلاحية إدارة الرواتب.","error")
            else: flash("تعذر إنشاء المسير. تأكد من وجود سجلات الحضور والورديات وصلاحيات الرواتب.","error")
        return redirect(url_for("hr_payroll"))
    try:
        employees=supabase_rows("employees", {"select":"id,employee_code,full_name,base_salary", "branch_id":f"eq.{branch_id}", "employment_status":"eq.active", "order":"full_name.asc"})
        periods=supabase_rows("payroll_periods", {"select":"id,period_name,start_date,end_date,status,created_at", "branch_id":f"eq.{branch_id}", "order":"created_at.desc", "limit":"50"})
        rules=supabase_request("POST", "rpc/get_payroll_attendance_rules", payload={})
        preview=None
        preview_from=request.args.get("from",""); preview_to=request.args.get("to","")
        if preview_from and preview_to:
            date.fromisoformat(preview_from); date.fromisoformat(preview_to)
            preview=supabase_request("POST", "rpc/get_attendance_payroll_summary", payload={"p_start_date":preview_from,"p_end_date":preview_to})
    except (RuntimeError, ValueError) as exc:
        if str(exc)=="SESSION_EXPIRED": return redirect(url_for("logout"))
        abort(502, description="تعذر تحميل مسيرات الرواتب أو احتساب الحضور. تحقق من صلاحيات الرواتب.")
    return render_template("payroll.html", employees=employees, periods=periods, rules=rules, preview=preview, preview_from=preview_from, preview_to=preview_to)


@app.route("/hr/payroll-rules", methods=["GET", "POST"])
@login_required
@csrf_checked
def hr_payroll_rules():
    if request.method == "POST":
        try:
            values=[Decimal(request.form.get(k,"0")) for k in ("monthly_work_days","daily_work_hours","overtime_multiplier","late_deduction_multiplier","absence_deduction_multiplier")]
            if any(not v.is_finite() for v in values): raise ValueError("أدخل أرقامًا صحيحة في جميع الحقول.")
            supabase_request("POST","rpc/set_payroll_attendance_rules",payload={
                "p_monthly_work_days":str(values[0]),"p_daily_work_hours":str(values[1]),"p_overtime_multiplier":str(values[2]),
                "p_late_deduction_multiplier":str(values[3]),"p_absence_deduction_multiplier":str(values[4])})
            flash("تم حفظ قواعد احتساب الرواتب.","success")
            return redirect(url_for("hr_payroll_rules"))
        except (ValueError,InvalidOperation) as exc:
            flash(str(exc) or "راجع القيم المدخلة.","error")
        except RuntimeError as exc:
            if str(exc)=="SESSION_EXPIRED": return redirect(url_for("logout"))
            flash("تعذر حفظ القواعد. تحقق من صلاحية إدارة الرواتب.","error")
    try:
        rules=supabase_request("POST","rpc/get_payroll_attendance_rules",payload={})
    except RuntimeError as exc:
        if str(exc)=="SESSION_EXPIRED": return redirect(url_for("logout"))
        abort(502,description="تعذر تحميل قواعد الرواتب.")
    return render_template("payroll_rules.html",rules=rules)


@app.route("/hr/payroll/<period_id>", methods=["GET", "POST"])
@login_required
@csrf_checked
def hr_payroll_detail(period_id):
    profile=current_profile() or {}; branch_id=profile.get("branch_id")
    if not branch_id: abort(403, description="حساب المستخدم غير مرتبط بفرع.")
    if request.method=="POST":
        action=request.form.get("action")
        try:
            if action=="approve":
                supabase_request("POST", "rpc/approve_payroll_period", payload={"p_period_id":period_id})
                flash("تم اعتماد مسير الرواتب.","success")
            elif action=="pay":
                amount=Decimal(request.form.get("amount","0"))
                if not amount.is_finite() or amount<=0: raise ValueError("أدخل مبلغ صرف صحيحًا.")
                supabase_request("POST", "rpc/pay_payroll_item", payload={
                    "p_payroll_item_id":request.form.get("item_id"),"p_cash_account_id":request.form.get("cash_account_id"),
                    "p_amount":str(amount),"p_reference":request.form.get("reference","").strip() or None
                })
                flash("تم تسجيل صرف الراتب وربط الحركة بالخزينة.","success")
            else: raise ValueError("عملية غير معروفة.")
        except (ValueError, InvalidOperation) as exc: flash(str(exc) or "راجع مبلغ الصرف.","error")
        except RuntimeError as exc:
            if str(exc)=="SESSION_EXPIRED": return redirect(url_for("logout"))
            msg=str(exc)
            if "INSUFFICIENT_CASH" in msg: flash("رصيد الخزينة لا يكفي.","error")
            elif "PAYROLL_NOT_APPROVED" in msg: flash("يجب اعتماد المسير قبل الصرف.","error")
            elif "PAYMENT_EXCEEDS_SALARY_BALANCE" in msg: flash("المبلغ أكبر من المتبقي للموظف.","error")
            elif "FORBIDDEN" in msg or "42501" in msg: flash("ليس لديك صلاحية إدارة الرواتب.","error")
            else: flash("تعذر تنفيذ عملية الرواتب.","error")
        return redirect(url_for("hr_payroll_detail",period_id=period_id))
    try:
        periods=supabase_rows("payroll_periods", {"select":"id,period_name,start_date,end_date,status,created_at", "id":f"eq.{period_id}", "branch_id":f"eq.{branch_id}", "limit":"1"})
        if not periods: abort(404)
        items=supabase_rows("payroll_items", {"select":"id,employee_id,basic_salary,additions,deductions,advances_deduction,net_salary,notes,attendance_present_days,attendance_absent_days,attendance_late_minutes,attendance_overtime_minutes,attendance_absence_deduction,attendance_late_deduction,attendance_overtime_addition", "payroll_period_id":f"eq.{period_id}", "branch_id":f"eq.{branch_id}", "order":"created_at.asc"})
        employees=supabase_rows("employees", {"select":"id,employee_code,full_name,job_title", "branch_id":f"eq.{branch_id}"})
        accounts=supabase_rows("cash_accounts", {"select":"id,name,is_active", "branch_id":f"eq.{branch_id}", "is_active":"eq.true"})
        item_ids=[i["id"] for i in items]
        payments=supabase_rows("salary_payments", {"select":"payroll_item_id,amount,paid_at,reference", "branch_id":f"eq.{branch_id}", "payroll_item_id":"in.("+",".join(item_ids)+")"}) if item_ids else []
    except RuntimeError as exc:
        if str(exc)=="SESSION_EXPIRED": return redirect(url_for("logout"))
        abort(502, description="تعذر تحميل تفاصيل مسير الرواتب.")
    emap={e["id"]:e for e in employees}; paid_map={}
    for p in payments: paid_map[p["payroll_item_id"]]=paid_map.get(p["payroll_item_id"],Decimal("0"))+Decimal(str(p["amount"]))
    for item in items:
        item["employee"]=emap.get(item["employee_id"],{})
        item["paid"]=paid_map.get(item["id"],Decimal("0"))
        item["remaining"]=Decimal(str(item["net_salary"]))-item["paid"]
    return render_template("payroll_detail.html", period=periods[0], items=items, accounts=accounts,
                           total_net=sum((Decimal(str(i["net_salary"])) for i in items),Decimal("0")),
                           total_paid=sum((i["paid"] for i in items),Decimal("0")))


@app.get("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.errorhandler(400)
def bad_request(error):
    return render_template("error.html", code=400, message=getattr(error, "description", "طلب غير صالح.")), 400


@app.errorhandler(403)
def forbidden(error):
    return render_template("error.html", code=403, message=getattr(error, "description", "غير مسموح لك بتنفيذ هذا الإجراء.")), 403


@app.errorhandler(409)
def conflict(error):
    return render_template("error.html", code=409, message=getattr(error, "description", "لا يمكن تنفيذ العملية في الحالة الحالية.")), 409


@app.errorhandler(502)
def upstream_error(error):
    return render_template("error.html", code=502, message=getattr(error, "description", "تعذر الاتصال بالخدمة.")), 502


if __name__ == "__main__":
    # Loopback only: do not expose the local desktop service to the LAN.
    app.run(host="127.0.0.1", port=8765, debug=False, threaded=True)
