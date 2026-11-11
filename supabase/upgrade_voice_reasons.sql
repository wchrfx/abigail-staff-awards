-- Apply ONCE to the EXISTING awards Supabase project before deploying voice-note frontend.
-- Audio is stored in a restricted database bytea column, NOT in public Storage.
-- The administrator can retrieve it only after the voting deadline.
-- A voice recording can reveal the speaker's identity; do not promise anonymity.

alter table public.ballots alter column reason drop not null;
alter table public.ballots add column if not exists audio_data bytea;
alter table public.ballots add column if not exists audio_mime text;
alter table public.ballots drop constraint if exists ballots_reason_check;
alter table public.ballots add constraint ballots_reason_or_audio check (
  (reason is not null and length(trim(reason)) between 20 and 500 and audio_data is null and audio_mime is null)
  or (reason is null and audio_data is not null and octet_length(audio_data) between 64 and 2097152
      and audio_mime in ('audio/webm','audio/mp4','audio/ogg'))
);

create or replace function public.submit_awards_ballot(p_name text,p_code text,p_votes jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare s record; settings record; allowed text[]; item jsonb; cat text;
        nominee uuid; why text; audio_text text; audio_bytes bytea; audio_mime text; all_cats text[] := array[]::text[]; expected_count integer;
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
    audio_text:=item->>'audio_base64';
    audio_mime:=item->>'audio_mime';
    if audio_text is not null then
      if length(audio_text)>2800000 or length(audio_text)<100 or audio_text !~ '^[A-Za-z0-9+/]+={0,2}
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
    audio_text:=item->>'audio_base64';
    insert into public.ballots(category,nominee_id,reason,audio_data,audio_mime)
    values(cat,(item->>'nominee_id')::uuid,
      case when audio_text is not null then null else trim(item->>'reason') end,
      case when audio_text is not null then decode(audio_text,'base64') else null end,
      case when audio_text is not null then item->>'audio_mime' else null end);
  end loop;
  update public.voter_credentials set has_voted=true,failed_attempts=0,locked_until=null where staff_id=s.id;
  return jsonb_build_object('ok',true);
end $$;


         or audio_mime not in ('audio/webm','audio/mp4','audio/ogg') then
        return jsonb_build_object('ok',false,'error','Invalid or oversized voice note (maximum 2 MB).');
      end if;
      audio_bytes:=decode(audio_text,'base64');
      if octet_length(audio_bytes)>2097152 or octet_length(audio_bytes)<64 then
        return jsonb_build_object('ok',false,'error','Voice note must be under 2 MB.');
      end if;
      if (audio_mime='audio/webm' and substring(audio_bytes from 1 for 4)<>decode('1a45dfa3','hex'))
        or (audio_mime='audio/ogg' and substring(audio_bytes from 1 for 4)<>decode('4f676753','hex'))
        or (audio_mime='audio/mp4' and substring(audio_bytes from 5 for 4)<>decode('66747970','hex')) then
        return jsonb_build_object('ok',false,'error','Unsupported voice-note file format.');
      end if;
      if why<>'' then return jsonb_build_object('ok',false,'error','Choose either a typed reason or a voice note.'); end if;
    elsif length(why)<20 or length(why)>500 then
      return jsonb_build_object('ok',false,'error','Every typed reason must contain 20 to 500 characters.');
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


-- Replace results with audio identifiers rather than including large recordings in results payload.
create or replace function public.admin_results()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare close_time timestamptz;
begin
  if not public.is_awards_admin() then raise exception 'Unauthorized administrator'; end if;
  select closes_at into close_time from public.award_settings where id=true;
  if now()<close_time then raise exception 'Results remain sealed until voting has closed'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('category',r.category,'nominee',r.display_name,
      'votes',r.votes,'reasons',r.reasons) order by r.category,r.votes desc,r.display_name)
    from (
      select b.category,s.display_name,count(*) votes,
        jsonb_agg(jsonb_build_object('id',b.id,'text',b.reason,'is_audio',b.audio_data is not null)) reasons
      from public.ballots b join public.staff s on s.id=b.nominee_id
      group by b.category,s.display_name
    ) r
  ),'[]'::jsonb);
end $$;

create or replace function public.admin_get_voice_reason(p_ballot_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare close_time timestamptz; recording record;
begin
  if not public.is_awards_admin() then raise exception 'Unauthorized administrator'; end if;
  select closes_at into close_time from public.award_settings where id=true;
  if now()<close_time then raise exception 'Voice notes remain sealed until voting has closed'; end if;
  select audio_data,audio_mime into recording from public.ballots where id=p_ballot_id and audio_data is not null;
  if not found then raise exception 'Voice note not found'; end if;
  return jsonb_build_object('mime',recording.audio_mime,'base64',encode(recording.audio_data,'base64'));
end $$;

revoke execute on function public.admin_get_voice_reason(uuid) from public,anon;
grant execute on function public.admin_get_voice_reason(uuid) to authenticated;
