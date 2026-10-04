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

- Dashboard: lead totals and leads by stage.
- Leads: search, filter by stage, add a lead by hand.

## Technical notes

- Hosting: GitHub Pages (this repository, `main` branch).
- Sign-in: the Supabase project behind NegoTrip HQ. Because both apps are served from `kamakshyanegotrip.github.io`, one sign-in at HQ covers both.
- Backend: the n8n workflow `TRAVELCRM-API-001-CRM-Web-App-API` at `https://n8n.assignover.in/webhook/travelcrm-api`. Every call carries the HQ sign-in token; the workflow checks it with HQ before touching any data.
- Data: the `crm` schema in the Quick Quote database.
- The key in `index.html` is Supabase's public browser key, the same one NegoTrip HQ publishes.

| File | Purpose |
| --- | --- |
| `index.html` | The whole app |
| `manifest.webmanifest` | Name, colours and icons for installing on a phone |
| `icon.svg`, `icon-192.png`, `icon-512.png` | App icons |
