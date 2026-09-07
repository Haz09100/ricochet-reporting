-- Separate the Team activity and live-bonus workloads, and explain incomplete
-- formal-note evidence instead of calling every incomplete record "missing".
-- Run after 011_large_range_performance.sql.

create or replace function public.dashboard_team_activity(p_from date,p_to date,p_filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set statement_timeout = '50s'
as $$
declare v_result jsonb; v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from,p_to);
  with filtered_leads as materialized (
    select l.id,l.phone_key from reporting.leads l where v_has_filters and report_api.lead_matches(l,p_filters)
  ), base as materialized (
    select c.lead_id,c.phone_key,c.user_id,c.user_name,c.duration_seconds,c.call_datetime_text,
      coalesce(nullif(trim(c.user_id),''),'name:'||lower(nullif(trim(c.user_name),'')),'unknown') caller_key
    from reporting.call_events c
    where c.call_date_eastern between p_from and p_to
      and (coalesce(nullif(trim(c.call_type_id),''),'0') not in ('7','10')
        or lower(trim(coalesce(c.recording_status,''))) in ('available','stored','completed')
        or nullif(trim(coalesce(c.recording_storage_key,'')),'') is not null
        or nullif(trim(coalesce(c.recording_url,'')),'') is not null
        or nullif(trim(coalesce(c.ai_transcript_original,'')),'') is not null)
      and (not v_has_filters
        or (c.lead_id is not null and c.lead_id in (select l.id from filtered_leads l))
        or (c.lead_id is null and c.phone_key in (select l.phone_key from filtered_leads l where l.phone_key is not null)))
  ), agent_stats as (
    select caller_key,coalesce(max(nullif(trim(user_name),'')),'Unknown') user_name,
      coalesce(max(nullif(trim(user_id),'')),'') user_id,count(*)::bigint calls,
      count(distinct coalesce(lead_id::text,'phone:'||phone_key))::bigint unique_leads,
      count(*) filter(where coalesce(duration_seconds,0)>=6)::bigint handled_calls,
      coalesce(sum(duration_seconds),0)::bigint duration_seconds,
      round(avg(nullif(duration_seconds,0))::numeric,1) average_duration_seconds,
      min(call_datetime_text) first_call,max(call_datetime_text) last_call
    from base group by caller_key
  ), maximums as (
    select greatest(coalesce(max(calls),0),1) max_calls,greatest(coalesce(max(unique_leads),0),1) max_leads from agent_stats
  ), scored as (
    select a.*,round(least(100,
      30*a.calls::numeric/m.max_calls+20*a.unique_leads::numeric/m.max_leads+
      20*a.handled_calls::numeric/greatest(a.calls,1)+15*least(coalesce(a.average_duration_seconds,0),300)/300+
      15*least(a.unique_leads::numeric/greatest(a.calls,1),1)))::integer score
    from agent_stats a cross join maximums m
  ), note_authors as (
    select coalesce(nullif(trim(n.note_user_name),''),nullif(trim(n.note_user_email),''),'Unknown') author,
      count(*)::bigint notes,count(distinct coalesce(n.lead_row_id::text,'phone:'||n.phone_key))::bigint unique_leads,
      min(coalesce(n.note_created_at_utc,n.detected_at_utc)) first_note,
      max(coalesce(n.note_created_at_utc,n.detected_at_utc)) last_note
    from reporting.note_events n
    where n.note_date_eastern between p_from and p_to and n.is_new_append is true
      and (not v_has_filters
        or (n.lead_row_id is not null and n.lead_row_id in (select l.id from filtered_leads l))
        or (n.lead_row_id is null and n.phone_key in (select l.phone_key from filtered_leads l where l.phone_key is not null)))
    group by 1
  )
  select jsonb_build_object(
    'totals',jsonb_build_object('calls',coalesce((select count(*) from base),0),'agents',coalesce((select count(*) from agent_stats),0),
      'unique_leads',coalesce((select count(distinct coalesce(lead_id::text,'phone:'||phone_key)) from base),0),
      'duration_seconds',coalesce((select sum(duration_seconds) from base),0)),
    'agents',coalesce((select jsonb_agg(to_jsonb(s) order by s.score desc,s.calls desc,s.user_name) from scored s),'[]'::jsonb),
    'note_authors',coalesce((select jsonb_agg(to_jsonb(n) order by n.notes desc,n.author) from note_authors n),'[]'::jsonb),
    'generated_at',now()
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.dashboard_live_bonus(p_from date,p_to date,p_filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set statement_timeout = '50s'
as $$
declare v_result jsonb; v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from,p_to);
  with first_live_candidates as materialized (
    select l.* from reporting.leads l
    where l.first_live_date_eastern between p_from and p_to
      and (not v_has_filters or report_api.lead_matches(l,p_filters-'agent'-'status'))
  ), live_candidates as materialized (
    select l.* from first_live_candidates l where l.live_email_sent is true
  ), evidence as materialized (
    select l.id,l.phone_key,l.first_live_date_eastern,l.lead_status current_lead_status,
      concat_ws(' ',nullif(trim(l.first_name),''),nullif(trim(l.last_name),'')) lead_name,
      n.note_found,n.note_text,n.gate_note_at,n.gate_note_date,n.form_note_date,n.original_live_status,
      report_api.form_isa(coalesce(n.note_text,'')) form_isa,
      coalesce(nullif(trim(n.note_user_name),''),nullif(trim(split_part(n.note_user_email,'@',1)),''),'Unknown') note_owner,
      coalesce(nullif(trim(n.note_user_id),''),'') note_owner_id,
      coalesce(nullif(trim(n.note_user_email),''),'') note_owner_email,
      n.matched_call_event_id
    from live_candidates l
    left join lateral (
      select true note_found,n.note_text,n.note_user_name,n.note_user_id,n.note_user_email,n.matched_call_event_id,
        coalesce(n.note_created_at_utc,n.detected_at_utc) gate_note_at,n.note_date_eastern gate_note_date,
        report_api.form_date(n.note_text) form_note_date,
        case
          when n.note_text ~* 'DISPOSITION[[:space:]]*:[[:space:]]*(2[.]3[[:space:]-]*)?LIVE[[:space:]]+(LEAD[[:space:]]+)?TRANSFER' then '2.3 Live Transfer'
          when n.note_text ~* 'DISPOSITION[[:space:]]*:[[:space:]]*(2[.]4[[:space:]-]*)?LIVE[[:space:]]+CALL[[:space:]-]*BACK' then '2.4 Live Call Back'
          when n.note_text ~* 'DISPOSITION[[:space:]]*:[[:space:]]*(2[.]5[[:space:]-]*)?LIVE[[:space:]]+(GROUP[[:space:]]+)?TEXT' then '2.5 Live Group Text'
        end original_live_status
      from reporting.note_events n
      where (n.lead_row_id=l.id or (n.lead_row_id is null and n.phone_key=l.phone_key))
        and (n.note_date_eastern between l.first_live_date_eastern-1 and l.first_live_date_eastern+1
          or report_api.form_date(n.note_text) between l.first_live_date_eastern-1 and l.first_live_date_eastern+1)
        and (n.note_text ~* '(BUYER|SELLER|UYER|ELLER)([[:space:]]+(AND[[:space:]]+)?(BUYER|SELLER))?[[:space:]]+FORM'
          or (n.note_text ~* 'LEAD[[:space:]]*:' and n.note_text ~* 'DATE[[:space:]]*:'
            and (n.note_text ~* 'ISA[[:space:]]*:' or n.note_text ~* 'DISPOSITION[[:space:]]*:')))
      order by
        (case when n.note_text ~* 'DISPOSITION[[:space:]]*:[[:space:]]*(2[.][345][[:space:]-]*)?LIVE' then 0 else 1 end),
        (case when n.note_text ~* 'ISA[[:space:]]*:' then 0 else 1 end),
        abs(n.note_date_eastern-l.first_live_date_eastern),
        coalesce(n.note_created_at_utc,n.detected_at_utc) asc nulls last,n.note_sequence asc nulls last,n.id asc
      limit 1
    ) n on true
  ), with_decision as materialized (
    select e.*,
      (report_api.agent_names_match(e.form_isa,e.note_owner)
        or report_api.agent_names_match(e.form_isa,split_part(e.note_owner_email,'@',1))) isa_owner_match,
      d.decision manual_decision,d.credited_agent_id manual_agent_id,d.credited_agent_name manual_agent_name,
      d.credited_agent_email manual_agent_email,d.reason decision_reason,d.decided_at,d.decided_by
    from evidence e
    left join lateral (
      select x.decision,x.credited_agent_id,x.credited_agent_name,x.credited_agent_email,x.reason,x.decided_at,x.decided_by
      from public.live_bonus_decisions x where x.lead_id=e.id order by x.decided_at desc,x.id desc limit 1
    ) d on true
  ), ledger as materialized (
    select d.*,
      case when d.manual_decision='approved' then coalesce(nullif(d.manual_agent_id,''),nullif(d.note_owner_id,''),'')
        else coalesce(nullif(d.note_owner_id,''),'') end credited_agent_id,
      case when d.manual_decision='approved' then coalesce(nullif(d.manual_agent_name,''),nullif(d.form_isa,''),nullif(d.note_owner,''),'Unknown')
        else coalesce(nullif(d.note_owner,''),nullif(d.form_isa,''),'Unknown') end credited_agent_name,
      case when d.manual_decision='approved' then coalesce(nullif(d.manual_agent_email,''),nullif(d.note_owner_email,''),'')
        else coalesce(nullif(d.note_owner_email,''),'') end credited_agent_email,
      case
        when d.manual_decision='retracted' then 'retracted'
        when d.manual_decision='approved' then 'payable'
        when not coalesce(d.note_found,false) and d.first_live_date_eastern>=((now() at time zone 'America/New_York')::date-1) then 'waiting_for_note'
        when not coalesce(d.note_found,false) then 'missing_formal_note'
        when nullif(trim(coalesce(d.form_isa,'')),'') is null then 'missing_isa'
        when d.original_live_status is null then 'missing_live_disposition'
        when coalesce(d.isa_owner_match,false) then 'payable'
        else 'needs_review' end bonus_state,
      case
        when not coalesce(d.note_found,false) then 'No structured Buyer/Seller form was synchronized near the first-live date.'
        when nullif(trim(coalesce(d.form_isa,'')),'') is null then 'A structured form exists, but its ISA field is missing.'
        when d.original_live_status is null then 'A structured form exists, but it does not contain a qualifying 2.3, 2.4, or 2.5 disposition.'
        when not coalesce(d.isa_owner_match,false) then 'The form ISA and formal-note owner do not match.'
        else 'Formal note, ISA, and live disposition matched.' end gate_reason,
      case when d.manual_decision='approved' then 'manager_approved' when d.manual_decision='retracted' then 'manager_retracted'
        when d.original_live_status is not null and nullif(trim(coalesce(d.form_isa,'')),'') is not null and coalesce(d.isa_owner_match,false) then 'automatic'
        else 'not_approved' end approval_source
    from with_decision d
  ), selected as materialized (
    select b.* from ledger b
    where (nullif(trim(coalesce(p_filters->>'status','')),'') is null or b.original_live_status=p_filters->>'status')
      and (nullif(trim(coalesce(p_filters->>'agent','')),'') is null
        or lower(trim(coalesce(b.credited_agent_id,'')))=lower(trim(p_filters->>'agent'))
        or report_api.normalize_agent(b.credited_agent_name)=report_api.normalize_agent(p_filters->>'agent')
        or report_api.normalize_agent(split_part(b.credited_agent_email,'@',1))=report_api.normalize_agent(p_filters->>'agent'))
  ), agent_stats as (
    select coalesce(nullif(credited_agent_id,''),'email:'||lower(nullif(credited_agent_email,'')),
        'name:'||report_api.normalize_agent(credited_agent_name),'unknown') owner_key,
      max(credited_agent_name) agent,max(credited_agent_id) agent_id,max(credited_agent_email) agent_email,
      count(*)::bigint payable_live_leads,
      count(*) filter(where original_live_status='2.3 Live Transfer')::bigint live_transfers,
      count(*) filter(where original_live_status='2.4 Live Call Back')::bigint live_call_backs,
      count(*) filter(where original_live_status='2.5 Live Group Text')::bigint live_texts,
      count(*) filter(where approval_source='automatic')::bigint auto_approved,
      count(*) filter(where approval_source='manager_approved')::bigint manager_approved
    from selected where bonus_state='payable' group by 1
  )
  select jsonb_build_object(
    'can_manage_bonus',exists(select 1 from public.report_users u where u.user_id=(select auth.uid()) and u.active is true and u.role in ('manager','admin')),
    'live_bonus_agents',coalesce((select jsonb_agg(to_jsonb(a) order by a.payable_live_leads desc,a.agent) from agent_stats a),'[]'::jsonb),
    'live_bonus_ledger',coalesce((select jsonb_agg(to_jsonb(b) order by b.first_live_date_eastern desc,b.lead_name,b.id) from selected b),'[]'::jsonb),
    'live_bonus_totals',jsonb_build_object(
      'sent_live_leads',coalesce((select count(*) from selected),0),
      'formal_note_gate_passed',coalesce((select count(*) from selected where original_live_status is not null and nullif(trim(coalesce(form_isa,'')),'') is not null),0),
      'payable',coalesce((select count(*) from selected where bonus_state='payable'),0),
      'needs_review',coalesce((select count(*) from selected where bonus_state='needs_review'),0),
      'waiting_for_note',coalesce((select count(*) from selected where bonus_state='waiting_for_note'),0),
      'missing_formal_note',coalesce((select count(*) from selected where bonus_state='missing_formal_note'),0),
      'missing_isa',coalesce((select count(*) from selected where bonus_state='missing_isa'),0),
      'missing_live_disposition',coalesce((select count(*) from selected where bonus_state='missing_live_disposition'),0),
      'retracted',coalesce((select count(*) from selected where bonus_state='retracted'),0),
      'live_transfers_payable',coalesce((select count(*) from selected where bonus_state='payable' and original_live_status='2.3 Live Transfer'),0),
      'live_call_backs_payable',coalesce((select count(*) from selected where bonus_state='payable' and original_live_status='2.4 Live Call Back'),0),
      'live_texts_payable',coalesce((select count(*) from selected where bonus_state='payable' and original_live_status='2.5 Live Group Text'),0)
    ),
    'generated_at',now()
  ) into v_result;
  return v_result;
end;
$$;

revoke execute on function public.dashboard_team_activity(date,date,jsonb) from public,anon;
grant execute on function public.dashboard_team_activity(date,date,jsonb) to authenticated;
revoke execute on function public.dashboard_live_bonus(date,date,jsonb) from public,anon;
grant execute on function public.dashboard_live_bonus(date,date,jsonb) to authenticated;
