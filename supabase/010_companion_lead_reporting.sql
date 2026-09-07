-- Buyer/Seller intent and companion-lead reporting.
-- Run after 009_note_call_timeline_linking.sql.

begin;

create table if not exists public.companion_bonus_decisions (
  id bigint generated always as identity primary key,
  lead_id bigint not null,
  decision text not null check (decision in ('approved','retracted','reset')),
  credited_agent_name text,
  reason text not null check (length(trim(reason)) >= 3),
  decided_by uuid not null references auth.users(id),
  decided_at timestamptz not null default now()
);

create index if not exists companion_bonus_decisions_lead_latest_idx
  on public.companion_bonus_decisions (lead_id,decided_at desc,id desc);

alter table public.companion_bonus_decisions enable row level security;
revoke all on table public.companion_bonus_decisions from public,anon,authenticated;

-- Mirror the source worker's intent rule: an explicit structured form heading
-- decides the primary side. Secondary intent inside that form does not turn the
-- same row into "Buyer and Seller" because the worker creates a companion row.
create or replace function report_api.classified_lead_type(p_lead reporting.leads)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_text text := lower(concat_ws(E'\n',nullif(trim(p_lead.note),''),nullif(trim(p_lead.all_notes),'')));
  v_flat text;
  v_stored text := lower(trim(coalesce(p_lead.lead_type,'')));
  v_seller_heading boolean;
  v_buyer_heading boolean;
  v_positive_both boolean;
  v_buyer_hits integer := 0;
  v_seller_hits integer := 0;
  v_marker text;
begin
  v_flat := trim(regexp_replace(v_text,'[^a-z0-9]+',' ','g'));
  v_seller_heading := v_text ~ '(^|[\r\n])[[:space:]]*seller([[:space:]]+(and[[:space:]]+)?buyer)?[[:space:]]+form([[:space:]:]|$)';
  v_buyer_heading := v_text ~ '(^|[\r\n])[[:space:]]*buyer([[:space:]]+(and[[:space:]]+)?seller)?[[:space:]]+form([[:space:]:]|$)';

  if v_seller_heading and not v_buyer_heading then return 'Seller'; end if;
  if v_buyer_heading and not v_seller_heading then return 'Buyer'; end if;

  select exists (
    select 1
    from regexp_split_to_table(v_text,E'[\r\n]+') raw(line)
    cross join lateral (
      select upper(trim(regexp_replace(raw.line,'[^a-zA-Z0-9]+',' ','g'))) comparable
    ) normalized
    where normalized.comparable ~ '(^| )(SELLER( AND)? BUYER|BUYER( AND)? SELLER)( |$)'
      and normalized.comparable !~ '(NOT CONFIRMED|UNCONFIRMED|DECLINED|DENIED)'
  ) into v_positive_both;

  foreach v_marker in array array[
    'buyer form','qit checklist','price and financing','max purchase price','budget ceiling',
    'max monthly payment','pre approved','funds accessible','home to sell first','target areas',
    'reason drawn to that area','flexible on location','motivation and timeline',
    'reason for buying now','target move in date','must have criteria',
    'currently working with an agent','looking at homes in person'
  ] loop
    if position(v_marker in v_flat) > 0 then v_buyer_hits := v_buyer_hits + 1; end if;
  end loop;

  foreach v_marker in array array[
    'seller form','property address','property details','interior condition','seller motivation',
    'price estimate','why selling now','mortgage on property','timeline to close',
    'next move after sale','other offers received','sole owner on the deed',
    'signed with a listing agent','cash offer appointment','current living status',
    'on leased land','year built','foundation type','unpermitted work'
  ] loop
    if position(v_marker in v_flat) > 0 then v_seller_hits := v_seller_hits + 1; end if;
  end loop;

  if v_positive_both then return 'Buyer and Seller'; end if;
  if v_buyer_hits > v_seller_hits then return 'Buyer'; end if;
  if v_seller_hits > v_buyer_hits then return 'Seller'; end if;
  if v_buyer_hits > 0 and v_seller_hits > 0 then return 'Buyer and Seller'; end if;
  if v_stored in ('buyer and seller','seller and buyer','both') then return 'Buyer and Seller'; end if;
  if v_stored='buyer' then return 'Buyer'; end if;
  if v_stored='seller' then return 'Seller'; end if;
  return 'Unknown';
end;
$$;

-- The source worker gives generated companion notes a companion disposition.
-- Combining that marker with the form heading identifies the split direction
-- without guessing from ordinary buyer/seller language.
create or replace function report_api.lead_creation_origin(p_lead reporting.leads)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_text text := lower(concat_ws(E'\n',nullif(trim(p_lead.note),''),nullif(trim(p_lead.all_notes),'')));
  v_type text := report_api.classified_lead_type(p_lead);
  v_companion boolean;
begin
  v_companion := v_text ~ 'disposition[[:space:]]*:[[:space:]]*companion[[:space:]]+opportunity'
    or v_text like '%leadflow_split_side%';
  if not v_companion then return 'original'; end if;
  if v_type='Buyer' then return 'seller_to_buyer'; end if;
  if v_type='Seller' then return 'buyer_to_seller'; end if;
  return 'original';
end;
$$;

create or replace function report_api.companion_originating_agent(p_lead reporting.leads)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    nullif(trim(report_api.form_isa(coalesce(p_lead.note,''))),''),
    nullif(trim(report_api.form_isa(coalesce(p_lead.all_notes,''))),''),
    nullif(trim(p_lead.user_name),''),'Unknown'
  )
$$;

create or replace function report_api.lead_matches(p_lead reporting.leads,p_filters jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select
    (nullif(trim(coalesce(p_filters->>'status','')),'') is null or (p_lead).lead_status=p_filters->>'status')
    and (nullif(trim(coalesce(p_filters->>'agent','')),'') is null
      or lower(trim(coalesce((p_lead).user_id,'')))=lower(trim(p_filters->>'agent'))
      or lower(trim(coalesce((p_lead).user_name,'')))=lower(trim(p_filters->>'agent')))
    and (nullif(trim(coalesce(p_filters->>'vendor','')),'') is null
      or lower(trim(coalesce((p_lead).vendor,'')))=lower(trim(p_filters->>'vendor')))
    and (nullif(trim(coalesce(p_filters->>'lead_type','')),'') is null
      or report_api.classified_lead_type(p_lead)=p_filters->>'lead_type')
    and (nullif(trim(coalesce(p_filters->>'creation_origin','')),'') is null
      or report_api.lead_creation_origin(p_lead)=p_filters->>'creation_origin')
    and (nullif(trim(coalesce(p_filters->>'state','')),'') is null
      or upper(trim(coalesce(nullif(trim((p_lead).property_state),''),(
        select r.geo_state from report_api.resolve_geo((p_lead).property_zip,(p_lead).property_state,(p_lead).city) r
      ),'')))=upper(trim(p_filters->>'state')))
    and (nullif(trim(coalesce(p_filters->>'city','')),'') is null
      or lower(trim(coalesce((p_lead).city,'')))=lower(trim(p_filters->>'city')))
    and (not (coalesce(p_filters,'{}'::jsonb) ? 'counties') or exists (
      select 1 from report_api.resolve_geo((p_lead).property_zip,(p_lead).property_state,(p_lead).city) r
      where lower(trim(r.county)) in (select lower(trim(value)) from jsonb_array_elements_text(
        case when jsonb_typeof(p_filters->'counties')='array' then p_filters->'counties' else '[]'::jsonb end
      ) selected_counties(value))
    ))
    and (not (coalesce(p_filters,'{}'::jsonb) ? 'metros') or exists (
      select 1 from report_api.resolve_geo((p_lead).property_zip,(p_lead).property_state,(p_lead).city) r
      where lower(trim(coalesce(r.metro,''))) in (select lower(trim(value)) from jsonb_array_elements_text(
        case when jsonb_typeof(p_filters->'metros')='array' then p_filters->'metros' else '[]'::jsonb end
      ) selected_metros(value))
    ))
    and (nullif(trim(coalesce(p_filters->>'appointment_type','')),'') is null
      or report_api.appointment_type(p_lead)=p_filters->>'appointment_type')
    and (nullif(trim(coalesce(p_filters->>'source_description','')),'') is null
      or lower(trim(coalesce((p_lead).source_lead_description,'')))=lower(trim(p_filters->>'source_description')))
    and (coalesce(p_filters->>'email_status','')<>'sent' or (p_lead).live_email_sent is true)
    and (coalesce(p_filters->>'email_status','')<>'not_sent' or coalesce((p_lead).live_email_sent,false) is false)
    and (
      nullif(trim(coalesce(p_filters->>'address_quality','')),'') is null
      or (p_filters->>'address_quality'='missing_city_or_zip' and (nullif(trim(coalesce((p_lead).city,'')),'') is null or report_api.normalize_zip((p_lead).property_zip) is null))
      or (p_filters->>'address_quality'='missing_city' and nullif(trim(coalesce((p_lead).city,'')),'') is null)
      or (p_filters->>'address_quality'='missing_zip' and report_api.normalize_zip((p_lead).property_zip) is null)
      or (p_filters->>'address_quality'='complete' and nullif(trim(coalesce((p_lead).city,'')),'') is not null and report_api.normalize_zip((p_lead).property_zip) is not null)
    )
    and (
      nullif(trim(coalesce(p_filters->>'search','')),'') is null
      or lower(concat_ws(' ',(p_lead).first_name,(p_lead).last_name)) like '%'||lower(trim(p_filters->>'search'))||'%'
      or lower(coalesce((p_lead).email,'')) like '%'||lower(trim(p_filters->>'search'))||'%'
      or (report_api.normalize_phone(p_filters->>'search')<>'' and report_api.normalize_phone((p_lead).phone) like '%'||report_api.normalize_phone(p_filters->>'search')||'%')
      or (p_lead).id::text=trim(p_filters->>'search')
      or lower(coalesce((p_lead).fub_id::text,''))=lower(trim(p_filters->>'search'))
    )
$$;

create or replace function report_api.has_lead_filters(p_filters jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select exists (
    select 1 from jsonb_each_text(coalesce(p_filters,'{}'::jsonb)) f
    where f.key in ('status','agent','vendor','lead_type','creation_origin','state','city','appointment_type',
      'source_description','address_quality','email_status','search')
      and nullif(trim(coalesce(f.value,'')),'') is not null
  ) or coalesce(p_filters,'{}'::jsonb) ? 'counties'
    or coalesce(p_filters,'{}'::jsonb) ? 'metros'
$$;

create or replace function public.dashboard_set_companion_bonus_decision(
  p_lead_id bigint,p_decision text,p_agent_name text default null,p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare v_decision text := lower(trim(coalesce(p_decision,''))); v_id bigint;
begin
  perform report_api.assert_manager();
  if p_lead_id is null or not exists (
    select 1 from reporting.leads l where l.id=p_lead_id and report_api.lead_creation_origin(l)<>'original'
  ) then raise exception 'A valid companion lead ID is required.' using errcode='22023'; end if;
  if v_decision not in ('approved','retracted','reset') then
    raise exception 'Decision must be approved, retracted, or reset.' using errcode='22023';
  end if;
  if length(trim(coalesce(p_reason,'')))<3 then
    raise exception 'A short reason is required for the audit history.' using errcode='22023';
  end if;
  if v_decision='approved' and nullif(trim(coalesce(p_agent_name,'')),'') is null then
    raise exception 'Choose the agent who receives the bonus.' using errcode='22023';
  end if;
  insert into public.companion_bonus_decisions(lead_id,decision,credited_agent_name,reason,decided_by)
  values(p_lead_id,v_decision,nullif(trim(p_agent_name),''),trim(p_reason),(select auth.uid()))
  returning id into v_id;
  return jsonb_build_object('success',true,'decision_id',v_id,'lead_id',p_lead_id,'decision',v_decision);
end;
$$;

create or replace function public.dashboard_companion_bonus(p_from date,p_to date,p_filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from,p_to);
  with agent_filter as materialized (
    select nullif(trim(coalesce(p_filters->>'agent','')),'') requested,
      (select max(nullif(trim(l.user_name),'')) from reporting.leads l
        where lower(trim(coalesce(l.user_id,'')))=lower(trim(coalesce(p_filters->>'agent','')))) requested_name
  ), candidates as materialized (
    select l.*,report_api.classified_lead_type(l) classified_type,
      report_api.lead_creation_origin(l) creation_origin,
      report_api.companion_originating_agent(l) originating_agent
    from reporting.leads l
    where l.created_date_eastern between p_from and p_to
      and report_api.lead_creation_origin(l)<>'original'
      and report_api.lead_matches(l,p_filters-'agent')
      and (
        (select requested from agent_filter) is null
        or report_api.normalize_agent(report_api.companion_originating_agent(l))=report_api.normalize_agent((select requested from agent_filter))
        or report_api.normalize_agent(report_api.companion_originating_agent(l))=report_api.normalize_agent((select requested_name from agent_filter))
      )
  ), ledger_base as materialized (
    select c.id,concat_ws(' ',nullif(trim(c.first_name),''),nullif(trim(c.last_name),'')) lead_name,
      c.classified_type lead_type,c.creation_origin,c.originating_agent,c.created_date_eastern,
      c.lead_status,c.vendor,c.user_name assigned_agent,
      d.decision manual_decision,d.credited_agent_name manual_agent_name,
      d.reason decision_reason,d.decided_at,d.decided_by
    from candidates c
    left join lateral (
      select x.decision,x.credited_agent_name,x.reason,x.decided_at,x.decided_by
      from public.companion_bonus_decisions x where x.lead_id=c.id
      order by x.decided_at desc,x.id desc limit 1
    ) d on true
  ), ledger as materialized (
    select b.*,
      case when b.manual_decision='approved' then coalesce(nullif(b.manual_agent_name,''),b.originating_agent)
        else b.originating_agent end credited_agent_name,
      case when b.manual_decision='retracted' then 'retracted'
        when b.manual_decision='approved' then 'payable'
        when nullif(trim(b.originating_agent),'') is not null and b.originating_agent<>'Unknown' then 'payable'
        else 'needs_review' end bonus_state,
      case when b.creation_origin='seller_to_buyer' then 'Buyer created from Seller Form'
        when b.creation_origin='buyer_to_seller' then 'Seller created from Buyer Form' end creation_label
    from ledger_base b
  ), agent_stats as (
    select 'name:'||report_api.normalize_agent(credited_agent_name) owner_key,
      max(credited_agent_name) agent,count(*)::bigint payable_companion_leads,
      count(*) filter(where creation_origin='seller_to_buyer')::bigint buyers_from_seller,
      count(*) filter(where creation_origin='buyer_to_seller')::bigint sellers_from_buyer,
      count(*) filter(where manual_decision='approved')::bigint manager_approved
    from ledger where bonus_state='payable' group by 1
  )
  select jsonb_build_object(
    'can_manage_bonus',exists(select 1 from public.report_users u where u.user_id=(select auth.uid()) and u.active is true and u.role in ('manager','admin')),
    'totals',jsonb_build_object(
      'created',coalesce((select count(*) from ledger),0),
      'buyers_from_seller',coalesce((select count(*) from ledger where creation_origin='seller_to_buyer'),0),
      'sellers_from_buyer',coalesce((select count(*) from ledger where creation_origin='buyer_to_seller'),0),
      'payable',coalesce((select count(*) from ledger where bonus_state='payable'),0),
      'needs_review',coalesce((select count(*) from ledger where bonus_state='needs_review'),0),
      'retracted',coalesce((select count(*) from ledger where bonus_state='retracted'),0)
    ),
    'agents',coalesce((select jsonb_agg(to_jsonb(a) order by a.payable_companion_leads desc,a.agent) from agent_stats a),'[]'::jsonb),
    'ledger',coalesce((select jsonb_agg(to_jsonb(l) order by l.created_date_eastern desc,l.lead_name,l.id) from ledger l),'[]'::jsonb),
    'generated_at',now()
  ) into v_result;
  return v_result;
end;
$$;

-- Small lookup used to decorate Leads, CSV results, and exports without making
-- the main paginated report functions heavier.
create or replace function public.dashboard_companion_origins(p_lead_ids bigint[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  perform report_api.assert_access();
  if coalesce(cardinality(p_lead_ids),0)>500 then
    raise exception 'Companion lookups are limited to 500 leads.' using errcode='22023';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',l.id,
    'lead_type',report_api.classified_lead_type(l),
    'creation_origin',report_api.lead_creation_origin(l),
    'creation_label',case report_api.lead_creation_origin(l)
      when 'seller_to_buyer' then 'Buyer created from Seller Form'
      when 'buyer_to_seller' then 'Seller created from Buyer Form'
      else 'Original / not companion' end,
    'originating_agent',report_api.companion_originating_agent(l)
  ) order by l.id),'[]'::jsonb) into v_result
  from reporting.leads l where l.id=any(coalesce(p_lead_ids,array[]::bigint[]));
  return v_result;
end;
$$;

revoke execute on function public.dashboard_set_companion_bonus_decision(bigint,text,text,text) from public,anon;
grant execute on function public.dashboard_set_companion_bonus_decision(bigint,text,text,text) to authenticated;
revoke execute on function public.dashboard_companion_bonus(date,date,jsonb) from public,anon;
grant execute on function public.dashboard_companion_bonus(date,date,jsonb) to authenticated;
revoke execute on function public.dashboard_companion_origins(bigint[]) from public,anon;
grant execute on function public.dashboard_companion_origins(bigint[]) to authenticated;

commit;
