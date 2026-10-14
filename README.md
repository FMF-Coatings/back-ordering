# FMF Back Order Web App

Internal web app for recording and tracking customer back orders: parts that cannot be supplied from stock and must be special ordered by Purchasing.

Procedures: **FMF-SOP-046** (System Overview) and **FMF-SOP-047** (User Guide).

## Features

- Raise a back order with Account Number, Order Number, optional Account Name, order note, optional sales rep, and one or more lines (part number, description, quantity, unit cost, unit price, note)
- Track each line as `TO BE ORDERED`, `ORDERED` (optional ordering note) or `COMPLETED`
- Export completed lines to a PDF, then archive them (restore or purge as a Manager)
- Manage users in the app (Managers only)
- Phone-friendly card view for read-only users

## Roles

| Role | Database value | Access |
| --- | --- | --- |
| Submitter | `submitter` | See all lines, raise back orders, delete own lines while `TO BE ORDERED` |
| Viewer (sales rep) | `viewer` | Read only. Sees only back orders assigned to them |
| Manager | `editor` | Edit View: edit, change status, assign sales reps, delete, export, archive, manage users |

Roles are enforced by the database (Row Level Security), not by the page.

## Stack

- **Front end:** single static file, `index.html` (HTML, CSS, JavaScript), no build step
- **Hosting:** GitHub Pages, from the `main` branch
- **Database and sign-in:** Supabase (PostgreSQL and Auth)
- **User management:** Supabase Edge Function `manage-users`
- **PDF export:** jsPDF and jspdf-autotable, built in the browser

## Repository layout

```
index.html    Web app
schema.sql    Database: tables, functions, triggers, RLS, grants
index.ts      Source of the manage-users Edge Function (deployed in Supabase)
README.md
```

## Making changes

1. Run any database change from `schema.sql` in the Supabase SQL Editor.
2. Deploy the `manage-users` function (`index.ts`) if it changed.
3. Commit `index.html` to `main`. GitHub Pages publishes it.
4. Hard refresh (Ctrl+F5) and test as a Submitter, a Viewer and a Manager.

Deploy in that order, so the page never calls something the database does not have yet.

## Notes

- Configuration is the `SUPABASE_URL` and `SUPABASE_ANON_KEY` constants in `index.html`. Only the public (publishable) key belongs in this repository. Never commit the `service_role` key.
- `manage-users` must accept all three roles: `['submitter', 'viewer', 'editor']`.
- The `authenticated` role needs `UPDATE` on `back_orders (account_name, assigned_to)` for sales rep assignment to work.
- Viewers can see unit cost and unit price on their assigned lines.
- There is no bulk assign for sales reps. Deleting a Viewer login leaves their back orders unassigned.
- The page loads libraries from jsDelivr and fonts from Google Fonts, so both must be reachable from the user's network.
