-- Companion records are owned by the LeadFlow D1 Worker.  This table stores only
-- manager decisions for those source records; it does not copy or reinterpret the
-- live-lead bonus ledger.

create table if not exists public.companion_source_bonus_decisions (
  id bigint generated always as identity primary key,
  source_lead_id text not null,
  destination_fub_person_id text,
  decision text not null check (decision in ('approved','retracted','reset')),
  credited_agent_name text,
  reason text not null,
  source_snapshot jsonb not null default '{}'::jsonb,
  decided_by uuid not null references auth.users(id),
  decided_at timestamptz not null default now()
);

create index if not exists companion_source_bonus_latest_idx
on public.companion_source_bonus_decisions (source_lead_id,decided_at desc,id desc);

alter table public.companion_source_bonus_decisions enable row level security;
revoke all on table public.companion_source_bonus_decisions from public,anon,authenticated;

create or replace function public.dashboard_companion_source_decisions(p_source_lead_ids text[])
returns table (
  source_lead_id text,
  destination_fub_person_id text,
  decision text,
  credited_agent_name text,
  reason text,
  decided_at timestamptz,
  decided_by uuid
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform report_api.assert_access();
  if coalesce(cardinality(p_source_lead_ids),0)>500 then
    raise exception 'Companion decision lookups are limited to 500 source leads.' using errcode='22023';
  end if;
  return query
  select distinct on (d.source_lead_id)
    d.source_lead_id,d.destination_fub_person_id,d.decision,d.credited_agent_name,
    d.reason,d.decided_at,d.decided_by
  from public.companion_source_bonus_decisions d
  where d.source_lead_id=any(coalesce(p_source_lead_ids,array[]::text[]))
  order by d.source_lead_id,d.decided_at desc,d.id desc;
end;
$$;

create or replace function public.dashboard_set_companion_source_bonus_decision(
  p_source_lead_id text,
  p_destination_fub_person_id text,
  p_decision text,
  p_agent_name text default null,
  p_reason text default null,
  p_source_snapshot jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_source_id text:=trim(coalesce(p_source_lead_id,''));
  v_decision text:=lower(trim(coalesce(p_decision,'')));
  v_id bigint;
begin
  perform report_api.assert_manager();
  if length(v_source_id)<3 or length(v_source_id)>200 then
    raise exception 'A valid LeadFlow source lead ID is required.' using errcode='22023';
  end if;
  if v_decision not in ('approved','retracted','reset') then
    raise exception 'Decision must be approved, retracted, or reset.' using errcode='22023';
  end if;
  if length(trim(coalesce(p_reason,'')))<3 then
    raise exception 'A short reason is required for the audit history.' using errcode='22023';
  end if;
  if v_decision='approved' and nullif(trim(coalesce(p_agent_name,'')),'') is null then
    raise exception 'Choose the agent who receives the bonus.' using errcode='22023';
  end if;
  if pg_column_size(coalesce(p_source_snapshot,'{}'::jsonb))>16384 then
    raise exception 'The companion source snapshot is too large.' using errcode='22023';
  end if;

  insert into public.companion_source_bonus_decisions (
    source_lead_id,destination_fub_person_id,decision,credited_agent_name,
    reason,source_snapshot,decided_by
  ) values (
    v_source_id,nullif(trim(coalesce(p_destination_fub_person_id,'')),''),v_decision,
    nullif(trim(coalesce(p_agent_name,'')),''),trim(p_reason),
    coalesce(p_source_snapshot,'{}'::jsonb),(select auth.uid())
  ) returning id into v_id;

  return jsonb_build_object('success',true,'decision_id',v_id,'source_lead_id',v_source_id,'decision',v_decision);
end;
$$;

revoke execute on function public.dashboard_companion_source_decisions(text[]) from public,anon;
revoke execute on function public.dashboard_set_companion_source_bonus_decision(text,text,text,text,text,jsonb) from public,anon;
grant execute on function public.dashboard_companion_source_decisions(text[]) to authenticated;
grant execute on function public.dashboard_set_companion_source_bonus_decision(text,text,text,text,text,jsonb) to authenticated;

comment on table public.companion_source_bonus_decisions is
'Append-only manager decisions for authoritative companion records read from the LeadFlow D1 Worker.';
