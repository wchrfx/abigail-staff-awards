-- Abigail Foundation Staff Recognition 2026
-- Run in a NEW Supabase project's SQL Editor. Never run against the Secret Santa project.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.staff (
  id uuid primary key default gen_random_uuid(),
  display_name text not null check (length(trim(display_name)) between 3 and 120),
  normalized_name text generated always as (lower(trim(regexp_replace(display_name, '\s+', ' ', 'g')))) stored unique,
  gender text not null check (gender in ('Male','Female')),
  department text not null check (department in ('Technical','Non-Technical','Projects'))
);

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table if not exists public.voter_credentials (
  staff_id uuid primary key references public.staff(id) on delete cascade,
  code_hash text not null,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  has_voted boolean not null default false
);

-- Deliberately no voter ID, IP, session ID or created_at timestamp in anonymous ballots.
create table if not exists public.ballots (
  id uuid primary key default gen_random_uuid(),
  category text not null check (category in ('overall_male','overall_female','technical','nontechnical','projects')),
  nominee_id uuid not null references public.staff(id) on delete restrict,
  reason text not null check (length(trim(reason)) between 20 and 500)
);

create table if not exists public.award_settings (
  id boolean primary key default true check (id),
  opens_at timestamptz not null default (now() + interval '365 days'),
  closes_at timestamptz not null default (now() + interval '366 days'),
  check (closes_at > opens_at)
);
insert into public.award_settings (id) values (true) on conflict (id) do nothing;

alter table public.staff enable row level security;
alter table public.admin_users enable row level security;
alter table public.voter_credentials enable row level security;
alter table public.ballots enable row level security;
alter table public.award_settings enable row level security;
revoke all on public.staff,public.admin_users,public.voter_credentials,public.ballots,public.award_settings from anon,authenticated;

-- Only the authorized Supabase Auth admin may run the administrative RPCs.
create or replace function public.is_awards_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.admin_users where user_id = auth.uid()) $$;

create or replace function public.admin_staff()
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_awards_admin() then raise exception 'Unauthorized administrator'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',s.id,'name',s.display_name,'gender',s.gender,'department',s.department,
      'has_code',c.staff_id is not null
    ) order by s.display_name)
    from public.staff s left join public.voter_credentials c on c.staff_id=s.id
  ),'[]'::jsonb);
end $$;

create or replace function public.admin_overview()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare a record; totals jsonb;
begin
  if not public.is_awards_admin() then raise exception 'Unauthorized administrator'; end if;
  select * into a from public.award_settings where id=true;
  select coalesce(jsonb_agg(jsonb_build_object('department',department,'registered',registered,'issued',issued,'submitted',submitted)),'[]'::jsonb)
  into totals from (
    select s.department,count(*) registered,count(c.staff_id) issued,
           count(*) filter (where c.has_voted) submitted
    from public.staff s left join public.voter_credentials c on c.staff_id=s.id
    group by s.department order by s.department
  ) x;
  return jsonb_build_object('opens_at',a.opens_at,'closes_at',a.closes_at,'departments',totals);
end $$;

create or replace function public.admin_set_window(p_opens_at timestamptz,p_closes_at timestamptz)
returns jsonb language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_awards_admin() then raise exception 'Unauthorized administrator'; end if;
  if p_opens_at is null or p_closes_at is null or p_closes_at<=p_opens_at then
    raise exception 'Voting close must be after voting open';
  end if;
  if exists(select 1 from public.ballots) then
    raise exception 'Voting dates cannot be changed after ballots have been submitted';
  end if;
  update public.award_settings set opens_at=p_opens_at,closes_at=p_closes_at where id=true;
  return jsonb_build_object('ok',true);
end $$;

-- Generate codes only for staff without codes. Show plaintext ONCE to admin.
create or replace function public.admin_generate_codes()
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare r record; v_code text; v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        bytes bytea; j int; result jsonb := '[]'::jsonb;
begin
  if not public.is_awards_admin() then raise exception 'Unauthorized administrator'; end if;
  if exists(select 1 from public.ballots) then raise exception 'Cannot issue new batch after voting has begun'; end if;
  for r in select s.id,s.display_name from public.staff s
           left join public.voter_credentials c on c.staff_id=s.id
           where c.staff_id is null order by s.display_name
  loop
    loop
      bytes:=extensions.gen_random_bytes(6);
      v_code:='';
      for j in 0..5 loop
        v_code:=v_code||substr(v_alphabet,(get_byte(bytes,j)%length(v_alphabet))+1,1);
      end loop;
      exit when not exists (select 1 from public.voter_credentials
          where extensions.crypt(v_code,code_hash)=code_hash);
    end loop;
    insert into public.voter_credentials(staff_id,code_hash)
      values(r.id,extensions.crypt(v_code,extensions.gen_salt('bf')));
    result:=result||jsonb_build_array(jsonb_build_object('name',r.display_name,'code',v_code));
  end loop;
  return result;
end $$;

create or replace function public.admin_reissue_code(p_staff_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare v_name text; v_code text; v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        bytes bytea; j int;
begin
  if not public.is_awards_admin() then raise exception 'Unauthorized administrator'; end if;
  if exists(select 1 from public.ballots) then
    raise exception 'For ballot anonymity, codes cannot be reissued once voting has begun';
  end if;
  select display_name into v_name from public.staff where id=p_staff_id;
  if v_name is null then raise exception 'Staff member not found'; end if;
  loop
    bytes:=extensions.gen_random_bytes(6); v_code:='';
    for j in 0..5 loop
      v_code:=v_code||substr(v_alphabet,(get_byte(bytes,j)%length(v_alphabet))+1,1);
    end loop;
    exit when not exists(select 1 from public.voter_credentials where extensions.crypt(v_code,code_hash)=code_hash);
  end loop;
  insert into public.voter_credentials(staff_id,code_hash)
    values(p_staff_id,extensions.crypt(v_code,extensions.gen_salt('bf')))
  on conflict (staff_id) do update set code_hash=excluded.code_hash,failed_attempts=0,locked_until=null;
  return jsonb_build_object('name',v_name,'code',v_code);
end $$;

-- Return a generic invalid-code response; DO NOT raise on bad credentials,
-- because an exception would roll back the failed-attempt counter.
create or replace function public.check_voter(p_name text,p_code text)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare s record; settings record; opts jsonb; entries jsonb:='[]'::jsonb;
        cat text; labels text[]; categories text[];
begin
  select a.* into settings from public.award_settings a where a.id=true;
  if now() < settings.opens_at or now() >= settings.closes_at then
    return jsonb_build_object('ok',false,'error','Voting is not currently open.');
  end if;
  select st.id,st.display_name,st.gender,st.department,c.code_hash,c.has_voted,c.failed_attempts,c.locked_until
  into s from public.staff st join public.voter_credentials c on c.staff_id=st.id
  where st.normalized_name=lower(trim(regexp_replace(coalesce(p_name,''),'\s+',' ','g')))
  for update of c;
  if not found then return jsonb_build_object('ok',false,'error','Name or private code is incorrect.'); end if;
  if s.locked_until is not null and s.locked_until > now() then
    return jsonb_build_object('ok',false,'error','Too many attempts. Try again after 15 minutes.');
  end if;
  if extensions.crypt(upper(trim(coalesce(p_code,''))),s.code_hash)<>s.code_hash then
    update public.voter_credentials set
      failed_attempts=case when locked_until is not null and locked_until<now() then 1 else least(failed_attempts+1,5) end,
      locked_until=case when failed_attempts+1>=5 and (locked_until is null or locked_until>now())
        then now()+interval '15 minutes'
        when locked_until is not null and locked_until<now() then null else locked_until end
    where staff_id=s.id;
    return jsonb_build_object('ok',false,'error','Name or private code is incorrect.');
  end if;
  update public.voter_credentials set failed_attempts=0,locked_until=null where staff_id=s.id;
  if s.has_voted then return jsonb_build_object('ok',false,'error','Your ballot has already been submitted.'); end if;
  categories:=case when s.department='Projects'
    then array['overall_male','overall_female','projects']
    else array['overall_male','overall_female','technical','nontechnical'] end;
  foreach cat in array categories loop
    select coalesce(jsonb_agg(jsonb_build_object('id',n.id,'name',n.display_name) order by n.display_name),'[]'::jsonb)
    into opts from public.staff n where n.id<>s.id and
      ((cat='overall_male' and n.gender='Male') or
       (cat='overall_female' and n.gender='Female') or
       (cat='technical' and n.department='Technical') or
       (cat='nontechnical' and n.department='Non-Technical') or
       (cat='projects' and n.department='Projects'));
    entries:=entries || jsonb_build_array(jsonb_build_object(
      'key',cat,
      'title',case cat when 'overall_male' then 'Overall Best Male Staff'
                       when 'overall_female' then 'Overall Best Female Staff'
                       when 'technical' then 'Best Technical Staff'
                       when 'nontechnical' then 'Best Non-Technical Staff'
                       else 'Best Projects Staff' end,
      'nominees',opts));
  end loop;
  return jsonb_build_object('ok',true,'name',s.display_name,'department',s.department,'categories',entries);
end $$;

create or replace function public.submit_awards_ballot(p_name text,p_code text,p_votes jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare s record; settings record; allowed text[]; item jsonb; cat text;
        nominee uuid; why text; all_cats text[] := array[]::text[]; expected_count integer;
begin
  select * into settings from public.award_settings where id=true;
  if now()<settings.opens_at or now()>=settings.closes_at then
    return jsonb_build_object('ok',false,'error','Voting is not currently open.');
  end if;
  select st.id,st.department,c.code_hash,c.has_voted,c.locked_until,c.failed_attempts
  into s from public.staff st join public.voter_credentials c on c.staff_id=st.id
  where st.normalized_name=lower(trim(regexp_replace(coalesce(p_name,''),'\s+',' ','g')))
  for update of c;
  if not found then return jsonb_build_object('ok',false,'error','Invalid voter credentials.'); end if;
  if s.locked_until is not null and s.locked_until>now() then
    return jsonb_build_object('ok',false,'error','Too many attempts. Try again later.');
  end if;
  if extensions.crypt(upper(trim(coalesce(p_code,''))),s.code_hash)<>s.code_hash then
    update public.voter_credentials set failed_attempts=least(failed_attempts+1,5),
    locked_until=case when failed_attempts>=4 then now()+interval '15 minutes' else locked_until end where staff_id=s.id;
    return jsonb_build_object('ok',false,'error','Invalid voter credentials.');
  end if;
  if s.has_voted then return jsonb_build_object('ok',false,'error','Your ballot was already submitted.'); end if;
  allowed:=case when s.department='Projects'
     then array['overall_male','overall_female','projects']
     else array['overall_male','overall_female','technical','nontechnical'] end;
  expected_count:=array_length(allowed,1);
  if p_votes is null or jsonb_typeof(p_votes)<>'array' or jsonb_array_length(p_votes)<>expected_count then
    return jsonb_build_object('ok',false,'error','Complete every available award category.');
  end if;
  -- Validate all selections before storing any ballots.
  for item in select value from jsonb_array_elements(p_votes) loop
    cat:=item->>'category';
    if cat is null or not(cat=any(allowed)) or cat=any(all_cats) then
      return jsonb_build_object('ok',false,'error','One or more award categories are invalid or duplicated.');
    end if;
    all_cats:=array_append(all_cats,cat);
    if coalesce(item->>'nominee_id','') !~ '^[0-9a-fA-F-]{36}$' then
      return jsonb_build_object('ok',false,'error','Select a valid nominee in each category.');
    end if;
    nominee:=(item->>'nominee_id')::uuid;
    why:=trim(coalesce(item->>'reason',''));
    if length(why)<20 or length(why)>500 then
      return jsonb_build_object('ok',false,'error','Every reason must contain 20 to 500 characters.');
    end if;
    if not exists(
      select 1 from public.staff n where n.id=nominee and n.id<>s.id and
      ((cat='overall_male' and n.gender='Male') or
       (cat='overall_female' and n.gender='Female') or
       (cat='technical' and n.department='Technical') or
       (cat='nontechnical' and n.department='Non-Technical') or
       (cat='projects' and n.department='Projects'))
    ) then return jsonb_build_object('ok',false,'error','Nominee does not qualify for that award.'); end if;
  end loop;
  -- Row lock on credentials serializes concurrent attempts from the same code.
  foreach cat in array allowed loop
    select value into item from jsonb_array_elements(p_votes) where value->>'category'=cat;
    insert into public.ballots(category,nominee_id,reason)
    values(cat,(item->>'nominee_id')::uuid,trim(item->>'reason'));
  end loop;
  update public.voter_credentials set has_voted=true,failed_attempts=0,locked_until=null where staff_id=s.id;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.admin_results()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare close_time timestamptz;
begin
  if not public.is_awards_admin() then raise exception 'Unauthorized administrator'; end if;
  select closes_at into close_time from public.award_settings where id=true;
  if now()<close_time then raise exception 'Results remain sealed until voting has closed'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'category',r.category,'nominee',r.display_name,'votes',r.votes,'reasons',r.reasons)
      order by r.category,r.votes desc,r.display_name)
    from (
      select b.category,s.display_name,count(*) votes,jsonb_agg(b.reason) reasons
      from public.ballots b join public.staff s on s.id=b.nominee_id
      group by b.category,s.display_name
    ) r
  ),'[]'::jsonb);
end $$;

revoke execute on function public.is_awards_admin() from public,anon;
revoke execute on function public.admin_staff() from public,anon;
revoke execute on function public.admin_overview() from public,anon;
revoke execute on function public.admin_set_window(timestamptz,timestamptz) from public,anon;
revoke execute on function public.admin_generate_codes() from public,anon;
revoke execute on function public.admin_reissue_code(uuid) from public,anon;
revoke execute on function public.admin_results() from public,anon;
revoke execute on function public.check_voter(text,text) from public,authenticated;
revoke execute on function public.submit_awards_ballot(text,text,jsonb) from public,authenticated;
grant execute on function public.is_awards_admin() to authenticated;
grant execute on function public.admin_staff() to authenticated;
grant execute on function public.admin_overview() to authenticated;
grant execute on function public.admin_set_window(timestamptz,timestamptz) to authenticated;
grant execute on function public.admin_generate_codes() to authenticated;
grant execute on function public.admin_reissue_code(uuid) to authenticated;
grant execute on function public.admin_results() to authenticated;
grant execute on function public.check_voter(text,text) to anon;
grant execute on function public.submit_awards_ballot(text,text,jsonb) to anon;