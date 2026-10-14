# FMF Back Order Web App

Internal web app for recording and tracking customer back orders at FMF Coatings: parts that cannot be supplied from stock and must be special ordered by Purchasing.

- **Live app:** https://fmf-coatings.github.io/back-ordering/ (Microsoft Edge on office PCs; sales reps may use a phone)
- **Procedures:** FMF-SOP-046 (System Overview) and FMF-SOP-047 (User Guide). This README is the technical companion to those SOPs. If they disagree, update whichever is wrong.
- **Owner:** Jack Thompson, IT Manager

## How it works

Back orders are raised by Sales Office staff, tracked line by line by Purchasing, then exported to a PDF record and archived.

| Status | Meaning |
| --- | --- |
| `TO BE ORDERED` | New line, not yet ordered |
| `ORDERED` | Ordered from the supplier. An optional ordering note (e.g. `OOS AT SUPPLIER`) can be added |
| `COMPLETED` | Received or dealt with. Included in the next PDF export |

Each back order has an **Account Number** and **Order Number** (both required), an optional **Account Name** and order note, an optional **Sales rep**, and one or more lines (part number, description, quantity, unit cost, unit price, line note). All text is stored in capitals.

### Roles

| Role (database value) | Who | Can do |
| --- | --- | --- |
| Submitter (`submitter`) | Sales Office | See all lines, raise back orders (optionally choosing a sales rep), delete their own lines while `TO BE ORDERED` |
| Viewer (`viewer`) | Sales reps | Read only. See only lines of back orders assigned to them. Cannot raise, change or delete anything |
| Manager (`editor`) | Purchasing | Everything above, plus in **Edit View**: edit any value, change status, assign or change the sales rep, delete lines, export to PDF, archive/restore/purge, manage users |

Notes:

- The database value for Manager is `editor`. The page labels it Manager.
- Sales reps see unit cost and unit price on their assigned lines. This is an open item for the SOP Approver to confirm.
- Back orders with no sales rep are visible to Submitters and Managers only.
- Only a Manager can assign or change a sales rep after a back order is raised, and only a user with the Viewer role can be assigned.
- Edit View is locked by default, always locks after a refresh, and Managers are signed out after 15 minutes of inactivity.

## Architecture

| Layer | Technology |
| --- | --- |
| Web page | One static file, `index.html` (HTML, CSS, JavaScript). No build step |
| Hosting | GitHub Pages, served from the `main` branch |
| Database and sign-in | Supabase (PostgreSQL and Supabase Auth), Pro plan, London region |
| Security rules | PostgreSQL Row Level Security (RLS), grants and triggers |
| User management | Supabase Edge Function `manage-users` |
| PDF export | jsPDF and jspdf-autotable, built in the browser |
| Libraries and fonts | Loaded from jsDelivr (pinned versions) and Google Fonts. If the network blocks these the app will not load or will look wrong |

The browser talks to Supabase directly using the public (publishable) key. **The database rules are the only thing protecting the data.** Hiding something in the page does not protect it.

### Sign-in

Users sign in with a username and password. The page converts the username to `username@backorders.fmfcoatings.co.uk` for Supabase Auth, so staff without email can sign in. No email is ever sent. Self-registration is switched off, and a login with no row in `profiles` can do nothing.

### Database objects the app relies on

The exact definitions live in `schema.sql` (see "Files to add" below). The page expects:

- **Tables:** `profiles` (role and display name per user), `back_orders` (including `account`, `account_name`, `order_ref`, `notes`, `assigned_to`), `product_lines`
- **Functions:** `create_back_order(...)` (blocks Viewers, validates the assignee), `list_sales_reps()` (staff only), and the role helpers `is_member()`, `is_editor()`, `is_staff()`
- **Triggers:** upper-casing of text, a check that `assigned_to` is a Viewer, and an archive guard
- **RLS:** Viewers can read a back order and its lines only where `assigned_to = auth.uid()`. Submitters and Managers read everything. Only Managers update or delete orders and lines (Submitters can delete their own `TO BE ORDERED` lines)
- **Column grants:** the `authenticated` role needs `UPDATE` on `back_orders (account_name, assigned_to)`. See the warning below

## Repository contents

| File | Status |
| --- | --- |
| `index.html` | In the repository. The whole front end |
| `README.md` | This file |
| `schema.sql` | **Not yet in the repository.** Add it (see below) |
| `supabase/functions/manage-users/index.ts` | **Not yet in the repository.** Add it (see below) |

### Files to add

FMF-SOP-046 says the repository holds the database script and the Edge Function source. As of the last check it held only `index.html`. Export both from the live Supabase project and commit them, so the system can be rebuilt from the repository.

> **Warning: missing grant.** The statement below was run by hand in the Supabase SQL Editor on 13/10/2026 and is not in any saved script. It must be part of `schema.sql`, otherwise a rebuilt database will reject sales rep assignment with "You do not have permission to do that."
>
> ```sql
> grant update (account_name, assigned_to) on public.back_orders to authenticated;
> ```

The `manage-users` function must allow all three roles: `const ROLES = ['submitter', 'viewer', 'editor'];`. If it only allows `viewer` and `editor`, adding or re-roling users fails with "Bad role".

## Setting up from scratch

Use this if the Supabase project has to be rebuilt. It assumes `schema.sql` and the Edge Function source are in the repository.

1. **Create a Supabase project** (Pro plan, London region).
2. **Switch off self-registration:** Authentication, Providers, Email. Disable sign-ups. Turn off email confirmation, because users have no real mailbox.
3. **Run `schema.sql`** in the SQL Editor. It is designed to be safe to re-run.
4. **Deploy the `manage-users` Edge Function** (Dashboard, Edge Functions) with the source from the repository.
5. **Create the first Manager.** Create the login in Authentication, Users, then insert a `profiles` row for it with role `editor` and a display name. After that, Managers add everyone else from the Users screen.
6. **Point the page at the project.** In `index.html` set `SUPABASE_URL` and `SUPABASE_ANON_KEY` (the publishable key).
7. **Enable GitHub Pages:** repository Settings, Pages, deploy from the `main` branch, root folder.
8. **Check it** with the test below before telling users.

## Making changes

1. Edit `index.html` and commit to `main`. GitHub Pages publishes automatically, usually within a minute or two.
2. For database changes, run the updated `schema.sql` in the Supabase SQL Editor, then commit the file.
3. For user-management changes, deploy the updated function in the Supabase dashboard, then commit the source.
4. **Order matters.** Deploy database changes first, then the Edge Function, then `index.html`. A page that calls a function or column the database does not have yet will error.
5. After a deploy, hard refresh (Ctrl+F5) before testing. A stale page or a stale Supabase schema cache causes confusing errors. If you add columns outside the dashboard's table editor, run `notify pgrst, 'reload schema';`.
6. Test as a **Submitter**, a **Viewer** and a **Manager** before telling users.
7. Record anything that changes behaviour in the revision history of FMF-SOP-046 and FMF-SOP-047.

### Test checklist for roles

- **Viewer:** sees no New back order box, no Sales rep column, no padlock. Sees only assigned back orders. To check it in SQL, impersonate the user inside a transaction and roll back:

  ```sql
  begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"<viewer user id>"}';
  select count(*) from back_orders;    -- only assigned orders
  select count(*) from product_lines;  -- only their lines
  rollback;
  ```

- **Submitter:** can raise a back order, can pick a sales rep, can delete only their own `TO BE ORDERED` lines.
- **Manager:** can edit, change status, assign a sales rep, export, archive, restore, purge and manage users. Cannot delete themselves, change their own role or remove the last Manager.

## Data lifecycle

1. A Submitter or Manager raises a back order. Lines start as `TO BE ORDERED`.
2. Purchasing sets lines to `ORDERED` (optional note) and then `COMPLETED`.
3. A Manager exports completed lines. The page builds a PDF in the browser, downloads it, then archives those lines (hidden from normal views).
4. Archived lines can be restored. **Purge** permanently deletes archived lines and cannot be undone. Only purge once the PDF has been filed in the Purchasing records location.

The PDF is the permanent record of completed lines.

## Security

- This repository is **public** so GitHub Pages can serve it. `index.html` contains only the Supabase project address and the publishable key, which are designed to be public.
- **Never commit** the Supabase `service_role` key, database password or any other secret. The service key lives only inside Supabase, where the Edge Function reads it.
- Never paste real user passwords, exported data or PDFs into issues or commits.
- Do not weaken the RLS policies or column grants without re-running the role tests above.
- Passwords are held by Supabase and are never visible to IT. A Manager sees a new password only once, when it is created or reset.
- The only personal data held is staff names and usernames.

## Backup and continuity

- Supabase Pro includes automatic daily backups. Confirm the retention period under Database, Backups.
- The page can be rebuilt from this repository at any time. The database can only be rebuilt from the repository once `schema.sql` and the Edge Function source have been added.
- One person (the IT Manager) currently holds administrator access to GitHub and Supabase. A deputy administrator has been requested from the SOP Approver.

## Known limitations

- Reps see unit cost and unit price on assigned lines. Hiding them from Viewers needs a database change as well as a page change, because hiding a column in the page does not stop the data being sent.
- Bulk assignment of sales reps does not exist. Back orders raised before the sales rep feature have no rep until a Manager assigns one.
- Deleting a Viewer login un-assigns their back orders. Reassign them or they will be visible to no rep.
- On a phone, read-only lines show as tap-to-expand cards. Edit View is still a wide table, and the Export and Users buttons are hidden.
- The page depends on jsDelivr and Google Fonts being reachable from the user's network.

## Support

Locked-out users should contact the IT Manager or a Purchasing Manager. Purchasing Managers can reset passwords. Faults with the page, hosting or database go to the IT Manager.
