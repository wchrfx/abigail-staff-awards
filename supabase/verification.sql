-- Run AFTER schema.sql and the private staff import, in the NEW awards project.
-- Read-only checks: should report 31 staff, 11 Technical, 10 Non-Technical, 10 Projects.
select count(*) as total_staff from public.staff;
select department, count(*) as staff_count
from public.staff group by department order by department;
select display_name,gender,department from public.staff
where normalized_name='nakintu jane mary';
select count(*) as duplicate_normalized_names
from (select normalized_name from public.staff group by normalized_name having count(*)>1) x;
select exists(select 1 from public.admin_users) as admin_is_configured;
select opens_at,closes_at from public.award_settings where id=true;

-- Every staff member should receive exactly 3 (Projects) or 4 (Technical/Non-Technical)
-- nomination categories; actual categories are enforced in the functions.
select department,case when department='Projects' then 3 else 4 end as categories_per_voter,count(*) as people
from public.staff group by department order by department;

-- Never test vote submission on real users; test in a separate disposable Supabase project
-- using fictional staff, codes and scheduled voting before opening the real event.