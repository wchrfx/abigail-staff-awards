## Voice-note upgrade for existing deployments (November 2026)

**Run `supabase/upgrade_voice_reasons.sql` in the EXISTING awards Supabase project SQL Editor.** This is a migration: do not rerun the original schema or staff import. It adds private database audio storage and updates ballot and admin RPCs. Then redeploy the latest GitHub commit in Vercel if automatic deployment did not happen.

Voters can choose a typed reason or a voice recording (up to 60 seconds, 2 MB maximum) for each award. Microphone access requires HTTPS and browser permission. Voice recordings are stored as restricted binary data in the Supabase database, not in public Storage; only the authorized admin can retrieve them after voting closes. **A person's voice may reveal their identity.** Ask participants to speak without mentioning their own names, and arrange a retention/deletion policy after awards are finalized. This is a feature upgrade requiring end-to-end testing on mobile Safari and Chrome before real voting.

---

# Abigail Foundation Staff Recognition Awards 2026

Private-code staff voting platform. Five categories; department-based eligibility; written reasons; one completed ballot per person; anonymous ballot storage; authorized admin reporting.

## Setup

1. Keep this repository **private**, especially if you later add staff-related assets. No real staff register or voting codes are committed.
2. Create a **new** Supabase project (do not reuse Secret Santa).
3. Open Supabase SQL Editor and run `supabase/schema.sql`.
4. In Supabase Authentication > Users, create the **one authorized admin** (email/password; disable public user signup). Then run this once in SQL Editor using their exact email:

       insert into public.admin_users(user_id)
       select id from auth.users where lower(email)=lower('ADMIN_EMAIL_HERE')
       on conflict do nothing;

5. Import the approved 31 staff records into `public.staff` (columns: `display_name`, `gender`, `department`). Use your staff import SQL privately in the SQL Editor; **do not commit actual staff names or codes**.
6. Vercel: import this GitHub repository, framework Vite. Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` from Supabase **Project Settings > API**. Never put a service role key in the frontend.
7. Sign in as the authorized administrator at the deployed site, set a voting start/end time, generate codes once, download their CSV and send each code privately to its intended staff member.
8. Test before issuing real codes. Do not open voting until the functional and security tests pass.

## Awards

- Overall Male — all staff vote, male nominees.
- Overall Female — all staff vote, female nominees.
- Best Technical — Technical and Non-Technical vote, Technical nominees.
- Best Non-Technical — Technical and Non-Technical vote, Non-Technical nominees.
- Best Projects — Projects vote, Projects nominees.

Every eligible category must be completed with a reason of 20–500 characters. No self-nominations.

## Privacy notes

Ballots store no voter ID or code and do not store timestamps. The code authentication table tracks completion separately. Administrators see turnout by department, not per-person voting status. Results and anonymized reasons are available in the app only after the scheduled close. The Supabase database owner retains privileged database access; absolute anonymity against database operators or external observation cannot be promised.

Six-character codes use an unambiguous 32-character alphabet and a server-side five-attempt lockout per staff identity. Keep Supabase RLS and RPC permissions enabled. For high-stakes use, add network-level rate limiting/CAPTCHA in front of the public RPC and conduct a security review.

## Local development

`npm install`
Copy `.env.example` to `.env` and enter the public Supabase URL and anon key.
`npm run dev`
