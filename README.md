# Project Atlas

Rent & cash board for small landlords and property managers (Spanish UI).
Which units paid this month, who is late, what was spent, and the net — in one page.

**Completely separate from All For One**: its own repo, its own Supabase project (`project-atlas`), its own login.

## How it is put together

- `index.html` is the whole app (static; served from GitHub Pages or any static host).
- Data lives in Supabase project `project-atlas` (`supabase/schema.sql`).
- Multi-tenant: every row carries an `org_id`. Row-level security lets a user read and write only the orgs
  they are a member of (`org_members`). Sign-up → "name your business" → `create_org()` makes the org and the
  owner membership in one step. Owners invite teammates by email with `add_member()` (the teammate must have
  signed up first).
- `index.html` carries the project URL and the publishable key in `CFG`. Both are safe to publish; data is
  protected by the sign-in + RLS.

## Tables

- `orgs` — name, currency
- `org_members` — (org, user, role owner|member)
- `properties` — a building, house or local; belongs to an org
- `units` — a rentable unit: rent, due_day, tenant, status occupied|vacant
- `payments` — a rent payment against a unit for a `period` ("2026-11"); amount, date, method
- `expenses` — a cost against the org, optionally a property/unit; category

## v0.2 (from the first questionnaire answers)

- **Banco** tab: paste bank alerts (SMS/email) or upload a statement CSV; Atlas finds credits (amount, date, name),
  proposes the unit (keywords in `units.match`, tenant name, amount = rent) and the user confirms. Each alert gets a
  fingerprint (`payments.bank_ref`, unique per org) so nothing is imported twice. Imported rows carry `source = 'bank'`.
- Contracts: `units.contract_end`; "Contratos por vencer" card on Resumen (next 90 days) and a chip on Unidades.
- Tenant history: click any unit name → every payment by month.
- "Reporte del mes" and per-payment "Recibo": printable views (browser print → PDF).
- WhatsApp reminder link per pending unit (wa.me with a prefilled message; needs the tenant's phone).
- Backgrounds: one photograph per section in `img/` (fuji, lake, falls, shore).

## Status logic (per unit, per selected month)

paid: payments ≥ rent · partial: 0 < payments < rent · late: nothing paid and today is past the due day ·
due: nothing paid, not yet late · vacant: unit marked vacant (excluded from expected rent).

## Setup from scratch

1. Create a Supabase project, run `supabase/schema.sql` in the SQL editor.
2. Authentication → Providers → Email: optionally turn off "Confirm email" so new clients can start immediately.
3. Put the project URL and publishable key in `CFG` in `index.html`.
4. Serve `index.html` (GitHub Pages: Settings → Pages → branch `main`, root).
