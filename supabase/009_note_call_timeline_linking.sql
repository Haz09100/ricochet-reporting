begin;

-- Keep explicit playable note/call matches as the first choice. When webhook
-- ordering did not save that relationship, link the closest playable call on
-- the same lead or phone. There is intentionally no time cutoff: one note plus
-- one recording must link, while multiple calls/notes use timestamp proximity.
create or replace function public.dashboard_notes(
  p_from date, p_to date, p_filters jsonb default '{}'::jsonb,
  p_page integer default 1, p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb; v_page integer := greatest(coalesce(p_page,1),1); v_size integer := least(greatest(coalesce(p_page_size,25),10),25); v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from, p_to);
  with selected as materialized (
    select l.id,l.lead_date_eastern,l.created_date_eastern
    from reporting.leads l
    where (not v_has_filters or report_api.lead_matches(l,p_filters))
      and case when coalesce(p_filters->>'date_basis','activity')='created' then l.created_date_eastern else l.lead_date_eastern end between p_from and p_to
      and nullif(trim(coalesce(l.all_notes,l.note,'')),'') is not null
  ), page_ids as (
    select s.id from selected s
    order by (case when coalesce(p_filters->>'date_basis','activity')='created' then s.created_date_eastern else s.lead_date_eastern end) desc nulls last,s.id desc
    limit v_size offset (v_page-1)*v_size
  ), page_rows as (
    select l.id,l.id lead_row_id,l.phone,l.phone_key,
      coalesce(nullif(trim(l.all_notes),''),l.note) note_text,l.note latest_note,
      l.user_name note_user_name,l.user_email note_user_email,
      coalesce(latest_note.note_created_at_utc,latest_note.detected_at_utc) note_created_at,l.lead_date_eastern note_date,
      latest_note.matched_call_event_id,latest_note.match_method,latest_note.match_confidence,
      l.first_name,l.last_name,l.lead_status,report_api.classified_lead_type(l) lead_type,
      coalesce(note_history.items,'[]'::jsonb) note_items,
      coalesce(recordings.items,'[]'::jsonb) recordings
    from page_ids p join reporting.leads l on l.id=p.id
    left join lateral (
      select n.note_created_at_utc,n.detected_at_utc,n.matched_call_event_id,n.match_method,n.match_confidence
      from reporting.note_events n
      where n.lead_row_id=l.id or (n.lead_row_id is null and n.phone_key=l.phone_key)
      order by coalesce(n.note_created_at_utc,n.detected_at_utc) desc nulls last,n.id desc limit 1
    ) latest_note on true
    left join lateral (
      select jsonb_agg(to_jsonb(h) order by h.note_sequence desc nulls last,h.note_time desc nulls last,h.id desc) items
      from (
        select n.id,n.ricochet_note_id,n.note_sequence,n.note_text,n.note_user_name,n.note_user_id,n.note_user_email,
          coalesce(n.note_created_at_utc,n.detected_at_utc) note_time,n.is_new_append,n.match_method,n.match_confidence,
          c.id call_id,c.call_uuid,c.call_datetime_text call_date_time,c.duration_seconds,c.user_name call_user_name,
          case when trim(coalesce(c.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(c.call_direction,''),'Outbound') end direction,
          c.recording_status,
          case when c.id=n.matched_call_event_id then 'exact' when c.id is not null then 'lead_timeline' end link_method
        from reporting.note_events n
        left join lateral (
          select ce.*
          from reporting.call_events ce
          where nullif(trim(coalesce(ce.call_uuid,'')),'') is not null
            and (ce.lead_id=l.id or (l.phone_key is not null and ce.phone_key=l.phone_key))
          order by (ce.id=n.matched_call_event_id) desc,
            case when ce.call_timestamp is null or coalesce(n.note_created_at_utc,n.detected_at_utc) is null then 1 else 0 end,
            abs(extract(epoch from (coalesce(n.note_created_at_utc,n.detected_at_utc)-ce.call_timestamp))) asc nulls last,
            ce.id desc
          limit 1
        ) c on true
        where n.lead_row_id=l.id or (n.lead_row_id is null and n.phone_key=l.phone_key)
        order by n.note_sequence desc nulls last,coalesce(n.note_created_at_utc,n.detected_at_utc) desc nulls last,n.id desc
        limit 50
      ) h
    ) note_history on true
    left join lateral (
      select jsonb_agg(to_jsonb(r) order by r.exact_match desc,r.sort_at desc nulls last,r.id desc) items from (
        select c.id,c.call_uuid,c.call_datetime_text call_date_time,c.call_timestamp sort_at,c.call_date_eastern call_date,
          c.duration_seconds,c.user_name,c.user_id,c.call_status,
          case when trim(coalesce(c.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(c.call_direction,''),'Outbound') end direction,
          c.recording_status,(c.id=latest_note.matched_call_event_id) exact_match,
          c.ai_status,c.ai_analysis_status,c.ai_analysis_model,c.ai_agent_score,c.ai_summary,c.ai_status_matches,c.ai_note_matches
        from reporting.call_events c
        where nullif(trim(coalesce(c.call_uuid,'')),'') is not null
          and (c.lead_id=l.id or (l.phone_key is not null and c.phone_key=l.phone_key))
        order by (c.id=latest_note.matched_call_event_id) desc,c.call_timestamp desc nulls last,c.id desc
        limit 25
      ) r
    ) recordings on true
    order by l.lead_date_eastern desc nulls last,l.id desc
  )
  select jsonb_build_object('total',(select count(*) from selected),'page',v_page,'page_size',v_size,
    'rows',coalesce((select jsonb_agg(to_jsonb(r)) from page_rows r),'[]'::jsonb),'generated_at',now()) into v_result;
  return v_result;
end;
$$;

create or replace function public.dashboard_call_ai_review(p_call_event_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  perform report_api.assert_access();
  if coalesce(p_call_event_id,0) <= 0 then raise exception 'A valid call event ID is required.' using errcode='22023'; end if;

  select jsonb_build_object(
    'call',jsonb_build_object(
      'id',c.id,'call_event_id',c.id,'call_uuid',c.call_uuid,'lead_id',coalesce(l.id,c.lead_id),
      'first_name',coalesce(l.first_name,c.first_name),'last_name',coalesce(l.last_name,c.last_name),
      'phone',coalesce(l.phone,c.phone),'agent_name',c.user_name,'user_name',c.user_name,'user_id',c.user_id,
      'call_date_time',c.call_datetime_text,'call_date',c.call_date_eastern,'duration_seconds',c.duration_seconds,
      'call_status',c.call_status,'direction',case when trim(coalesce(c.call_type_id,'')) in ('7','10') then 'Inbound' else coalesce(nullif(c.call_direction,''),'Outbound') end,
      'lead_status',l.lead_status,'lead_type',case when l.id is not null then report_api.classified_lead_type(l) else coalesce(c.lead_type,'Unknown') end,
      'vendor',l.vendor,'recording_status',c.recording_status
    ),
    'analysis',jsonb_build_object(
      'transcription_status',c.ai_status,'transcription_model',c.ai_model,'detected_language',c.ai_detected_language,
      'original_transcript',c.ai_transcript_original,'transcription_error',c.ai_error,'transcribed_at',c.ai_processed_at,
      'analysis_status',c.ai_analysis_status,'analysis_model',c.ai_analysis_model,'analysis_language',c.ai_language,
      'english_transcript',c.ai_english_transcript,'summary',c.ai_summary,'ai_lead_type',c.ai_lead_type,
      'note_matches',c.ai_note_matches,'note_match_score',c.ai_note_match_score,'note_differences',c.ai_note_differences,
      'corrected_note',c.ai_corrected_note,'current_status',c.ai_current_lead_status,
      'recommended_status',c.ai_recommended_status,'status_matches',c.ai_status_matches,'status_reason',c.ai_status_reason,
      'agent_score',c.ai_agent_score,'missing_questions',c.ai_missing_questions,'coaching',c.ai_coaching,
      'next_action',c.ai_next_action,'analysis_error',c.ai_analysis_error,'reviewed_at',c.ai_analysis_processed_at
    ),
    'note',case when n.id is null then '{}'::jsonb else jsonb_build_object(
      'id',n.id,'ricochet_note_id',n.ricochet_note_id,'text',n.note_text,
      'owner',coalesce(nullif(trim(n.note_user_name),''),nullif(trim(n.note_user_email),''),'Unknown note owner'),
      'owner_id',n.note_user_id,'created_at',coalesce(n.note_created_at_utc,n.detected_at_utc),
      'match_method',case when n.matched_call_event_id=c.id then coalesce(nullif(n.match_method::text,''),'exact') else 'lead_timeline' end,
      'match_confidence',case when n.matched_call_event_id=c.id then n.match_confidence::text else '0.75' end
    ) end
  ) into v_result
  from reporting.call_events c
  left join lateral (
    select x.* from reporting.leads x
    where x.id=c.lead_id or (c.lead_id is null and x.phone_key=c.phone_key)
    order by (x.id=c.lead_id) desc nulls last,x.id desc limit 1
  ) l on true
  left join lateral (
    select x.* from reporting.note_events x
    where x.matched_call_event_id=c.id
      or x.lead_row_id=coalesce(l.id,c.lead_id)
      or (c.phone_key is not null and x.phone_key=c.phone_key)
    order by (x.matched_call_event_id=c.id) desc,
      case when coalesce(x.note_created_at_utc,x.detected_at_utc) is null or c.call_timestamp is null then 1 else 0 end,
      abs(extract(epoch from (coalesce(x.note_created_at_utc,x.detected_at_utc)-c.call_timestamp))) asc nulls last,
      x.id desc limit 1
  ) n on true
  where c.id=p_call_event_id;

  if v_result is null then raise exception 'Call event was not found.' using errcode='P0002'; end if;
  return v_result;
end;
$$;

revoke execute on function public.dashboard_notes(date,date,jsonb,integer,integer) from public,anon;
revoke execute on function public.dashboard_call_ai_review(bigint) from public,anon;
grant execute on function public.dashboard_notes(date,date,jsonb,integer,integer) to authenticated;
grant execute on function public.dashboard_call_ai_review(bigint) to authenticated;

commit;
