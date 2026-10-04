# NegoTrip CRM

The Travel CRM web app. Works on a computer and installs on a phone like an app.

**Live page:** https://kamakshyanegotrip.github.io/negotrip-crm/

## Who can open it

The CRM has no sign-in of its own. It uses the NegoTrip HQ sign-in.

| Person | Access |
| --- | --- |
| **Owner** (the HQ owner) | Always |
| **Anyone else** | Only if they can see an HQ tool whose link contains `negotrip-crm` |

To give the team access, add the CRM as a tool in NegoTrip HQ using the live page link above, then share that tool or its category with a team as usual. Pausing someone in HQ also shuts them out of the CRM.

The first time someone opens the CRM, a staff record is created for them: HQ owner becomes Owner, HQ manager becomes Sales manager, HQ staff becomes Sales executive. Sales executives see their own leads and unassigned ones; everyone else sees all leads.

## What it does today

- **Dashboard:** open, hot and unassigned leads, your next tasks, leads by stage.
- **Leads:** search and filter by stage, heat and owner; add a lead by hand.
- **Lead page:** stage, owner, call and WhatsApp buttons, trip details, score with its reasons, possible duplicates (merge or dismiss), tasks, notes and full history.
- **Tasks:** open, overdue, today, later and done; add, edit, complete, reopen.
- **Customers:** one record per person or company, with their leads, travellers, preferences, marketing consent and history.
- **Team** (owner and company admins): roles, pausing access, specialities and lead limits.

Behind the screens:

- A lead that arrives twice (same phone or email) is flagged, never silently duplicated.
- Every lead is scored out of 100 from its travel date, budget, group size and source. An AI reading of the request text can move the score by at most a quarter.
- Leads from outside sources go to the next sales person in turn, matching specialities first. Leads added by hand stay with whoever added them.
- Each new lead gets a first-contact task: 15 minutes for hot, 1 hour for warm, 4 hours for cold. Overdue tasks are escalated to a manager.

## Technical notes

- Hosting: GitHub Pages (this repository, `main` branch).
- Sign-in: the Supabase project behind NegoTrip HQ. Because both apps are served from `kamakshyanegotrip.github.io`, one sign-in at HQ covers both.
- Backend: the n8n workflow `TRAVELCRM-API-001-CRM-Web-App-API` at `https://n8n.assignover.in/webhook/travelcrm-api`. Every call carries the HQ sign-in token; the workflow checks it with HQ, then runs the request through the database function `crm.api`.
- Data: the `crm` schema in the Quick Quote database. The business rules (validation, who may see what, scoring, assignment) live in database functions, so every workflow follows the same rules.
- Migrations: `db/`. Each one is applied by a `TRAVELCRM-SETUP-…` workflow that downloads the file from this repository at a pinned commit.
- In SQL kept here, never write a dollar sign directly before a quote (`$'`): n8n rewrites that sequence when it passes SQL through. Write `($)'` in patterns instead.
- The key in `index.html` is Supabase's public browser key, the same one NegoTrip HQ publishes.

| File | Purpose |
| --- | --- |
| `index.html` | The whole app |
| `manifest.webmanifest` | Name, colours and icons for installing on a phone |
| `icon.svg`, `icon-192.png`, `icon-512.png` | App icons |
| `db/001_crm_core.sql` | Core tables |
| `db/002_lead_engine.sql` | Lead engine: duplicates, scoring, assignment, tasks, customers, `crm.api` |

## n8n workflows

| Workflow | What it does |
| --- | --- |
| `TRAVELCRM-API-001-CRM-Web-App-API` | Backend for this app |
| `TRAVELCRM-WF-001-Lead-Capture-Gateway` | One protected address for leads from websites, ad forms and partners |
| `TRAVELCRM-WF-007-Task-Escalation` | Every 15 minutes, escalates overdue tasks |
| `TRAVELCRM-WF-008-AI-Lead-Qualification` | Every 10 minutes, rates new requests with Gemini (no names, phones or emails are sent) |
| `TRAVELCRM-ERR-001-Global-Error-Handler` | Records every workflow failure and queues failed background runs |
| `TRAVELCRM-SETUP-001`, `-002` | Apply the database migrations (run once) |
| `TRAVELCRM-TEST-001`, `-002` | Test harnesses; they leave no data behind |
