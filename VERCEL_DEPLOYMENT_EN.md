# OT Laundry — Vercel Deployment

## 1. GitHub repository
Upload the contents of this `OT-Laundry` folder to the repository root.
Do not upload `.env`, `instance/`, session keys, or Supabase secret/service-role keys.

## 2. Vercel project
Import the GitHub repository. Keep the project root at `./` and let Vercel detect Flask.
No custom build command or output directory is required.

## 3. Environment variables
Add the following for Production and Preview:

- `SUPABASE_URL` = `https://kpqflvgrhlnfgkybmrtp.supabase.co`
- `SUPABASE_PUBLISHABLE_KEY` = the Supabase publishable key (or legacy anon key)
- `OT_LAUNDRY_AUTH_URL` = `https://kpqflvgrhlnfgkybmrtp.supabase.co/functions/v1/ot-laundry-auth`
- `FLASK_SECRET_KEY` = a long, random, stable secret (at least 32 characters)

Never use a Supabase `service_role` or secret key in this application.

## 4. Deploy and smoke test
Deploy, then open `/health`. Expected response includes `status: ok`.
Open `/login`, sign in, navigate between Dashboard, Cashier, Invoices, Finance, Reports and HR,
and test logout. Test with a non-admin account to confirm RLS and permissions.

## 5. Important operational notes
- Supabase remains the persistent database. The app does not write user data to local disk on Vercel.
- Authentication tokens are encrypted before being stored in the signed, HTTP-only Flask session cookie.
  `FLASK_SECRET_KEY` must remain unchanged across instances and deployments; rotating it signs out all users.
- Vercel serves the stylesheet from `public/css/app.css`.
- WhatsApp opens a prepared chat; the user still presses Send. Browser printing depends on the client device/browser.
- The Windows desktop build uses `requirements-desktop.txt`; Vercel installs only runtime dependencies.
- Verify real workflows after deployment. A successful build alone does not prove invoice, payroll, printer, or WhatsApp behavior.
