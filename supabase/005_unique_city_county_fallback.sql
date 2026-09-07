-- Conservative city/state fallback for ZIPs absent from the Zillow lookup.
-- Run after every browser-safe 004 ZIP geography part has completed.

begin;

create table if not exists public.city_geo_fallback (
  state text not null check (state ~ '^[A-Z]{2}$'),
  city_key text not null,
  city text not null,
  county text not null,
  metro text,
  source_zip_count integer not null check (source_zip_count > 0),
  updated_at timestamptz not null default now(),
  primary key (state, city_key)
);

alter table public.city_geo_fallback enable row level security;
revoke all on table public.city_geo_fallback from public, anon, authenticated;

create or replace function report_api.normalize_city(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(lower(trim(regexp_replace(coalesce(p_value,''), '[[:space:]]+', ' ', 'g'))),'')
$$;

-- This table is derived only from cities that resolve to exactly one county
-- inside a state. Ambiguous city names are deliberately excluded.
delete from public.city_geo_fallback;

insert into public.city_geo_fallback (state,city_key,city,county,metro,source_zip_count,updated_at)
select
  g.state,
  report_api.normalize_city(g.city) city_key,
  min(g.city) city,
  min(g.county) county,
  case
    when count(distinct nullif(trim(g.metro),'')) = 1 then min(nullif(trim(g.metro),''))
    else null
  end metro,
  count(*)::integer source_zip_count,
  now()
from public.zip_geo_lookup g
where report_api.normalize_city(g.city) is not null
group by g.state,report_api.normalize_city(g.city)
having count(distinct g.county) = 1;

create or replace function report_api.resolve_geo(p_zip text, p_state text, p_city text)
returns table(geo_state text, county text, metro text, match_method text)
language sql
stable
set search_path = ''
as $$
  with exact_match as (
    select g.state geo_state,g.county,g.metro,'zip'::text match_method
    from public.zip_geo_lookup g
    where g.zip_code=report_api.normalize_zip(p_zip)
  ), city_match as (
    select c.state geo_state,c.county,c.metro,'city_state_unique_county'::text match_method
    from public.city_geo_fallback c
    where c.state=upper(trim(coalesce(p_state,'')))
      and c.city_key=report_api.normalize_city(p_city)
  )
  select e.geo_state,e.county,e.metro,e.match_method from exact_match e
  union all
  select c.geo_state,c.county,c.metro,c.match_method from city_match c
  where not exists (select 1 from exact_match)
  limit 1
$$;

create or replace function report_api.lead_matches(p_lead reporting.leads, p_filters jsonb)
returns boolean
language sql
stable
set search_path = ''
as $$
  select
    (nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'status'),'')),'') is null
      or (p_lead).lead_status = jsonb_extract_path_text(p_filters,'status'))
    and (nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'agent'),'')),'') is null
      or lower(trim(coalesce((p_lead).user_id,''))) = lower(trim(jsonb_extract_path_text(p_filters,'agent')))
      or lower(trim(coalesce((p_lead).user_name,''))) = lower(trim(jsonb_extract_path_text(p_filters,'agent'))))
    and (nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'vendor'),'')),'') is null
      or lower(trim(coalesce((p_lead).vendor,''))) = lower(trim(jsonb_extract_path_text(p_filters,'vendor'))))
    and (nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'lead_type'),'')),'') is null
      or report_api.classified_lead_type(p_lead) = jsonb_extract_path_text(p_filters,'lead_type'))
    and (nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'state'),'')),'') is null
      or upper(trim(coalesce(nullif(trim((p_lead).property_state),''),(
        select r.geo_state from report_api.resolve_geo((p_lead).property_zip,(p_lead).property_state,(p_lead).city) r
      ),''))) = upper(trim(jsonb_extract_path_text(p_filters,'state'))))
    and (nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'city'),'')),'') is null
      or lower(trim(coalesce((p_lead).city,''))) = lower(trim(jsonb_extract_path_text(p_filters,'city'))))
    and (
      not (coalesce(p_filters,'{}'::jsonb) ? 'counties')
      or exists (
        select 1
        from report_api.resolve_geo((p_lead).property_zip,(p_lead).property_state,(p_lead).city) r
        where lower(trim(r.county)) in (
          select lower(trim(value))
          from jsonb_array_elements_text(
            case when jsonb_typeof(p_filters->'counties')='array' then p_filters->'counties' else '[]'::jsonb end
          ) selected_counties(value)
        )
      )
    )
    and (
      not (coalesce(p_filters,'{}'::jsonb) ? 'metros')
      or exists (
        select 1
        from report_api.resolve_geo((p_lead).property_zip,(p_lead).property_state,(p_lead).city) r
        where lower(trim(coalesce(r.metro,''))) in (
          select lower(trim(value))
          from jsonb_array_elements_text(
            case when jsonb_typeof(p_filters->'metros')='array' then p_filters->'metros' else '[]'::jsonb end
          ) selected_metros(value)
        )
      )
    )
    and (nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'appointment_type'),'')),'') is null
      or report_api.appointment_type(p_lead) = jsonb_extract_path_text(p_filters,'appointment_type'))
    and (nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'source_description'),'')),'') is null
      or lower(trim(coalesce((p_lead).source_lead_description,''))) = lower(trim(jsonb_extract_path_text(p_filters,'source_description'))))
    and (coalesce(jsonb_extract_path_text(p_filters,'email_status'),'') <> 'sent' or (p_lead).live_email_sent is true)
    and (coalesce(jsonb_extract_path_text(p_filters,'email_status'),'') <> 'not_sent' or coalesce((p_lead).live_email_sent,false) is false)
    and (
      nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'address_quality'),'')),'') is null
      or (jsonb_extract_path_text(p_filters,'address_quality')='missing_city_or_zip'
        and (nullif(trim(coalesce((p_lead).city,'')), '') is null or report_api.normalize_zip((p_lead).property_zip) is null))
      or (jsonb_extract_path_text(p_filters,'address_quality')='missing_city'
        and nullif(trim(coalesce((p_lead).city,'')), '') is null)
      or (jsonb_extract_path_text(p_filters,'address_quality')='missing_zip'
        and report_api.normalize_zip((p_lead).property_zip) is null)
      or (jsonb_extract_path_text(p_filters,'address_quality')='complete'
        and nullif(trim(coalesce((p_lead).city,'')), '') is not null
        and report_api.normalize_zip((p_lead).property_zip) is not null)
    )
    and (
      nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'search'),'')),'') is null
      or lower(concat_ws(' ',(p_lead).first_name,(p_lead).last_name)) like '%' || lower(trim(jsonb_extract_path_text(p_filters,'search'))) || '%'
      or lower(coalesce((p_lead).email,'')) like '%' || lower(trim(jsonb_extract_path_text(p_filters,'search'))) || '%'
      or (report_api.normalize_phone(jsonb_extract_path_text(p_filters,'search')) <> ''
        and report_api.normalize_phone((p_lead).phone) like '%' || report_api.normalize_phone(jsonb_extract_path_text(p_filters,'search')) || '%')
      or (p_lead).id::text = trim(jsonb_extract_path_text(p_filters,'search'))
      or lower(coalesce((p_lead).fub_id::text,'')) = lower(trim(jsonb_extract_path_text(p_filters,'search')))
    )
$$;

create or replace function public.dashboard_leads(
  p_from date, p_to date, p_filters jsonb default '{}'::jsonb,
  p_page integer default 1, p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb; v_page integer := greatest(coalesce(p_page,1),1); v_size integer := least(greatest(coalesce(p_page_size,50),10),1000); v_has_filters boolean := report_api.has_lead_filters(p_filters);
begin
  perform report_api.assert_access();
  perform report_api.validate_range(p_from, p_to);
  with selected as materialized (
    select l.* from reporting.leads l
    where (not v_has_filters or report_api.lead_matches(l,p_filters))
      and case when coalesce(p_filters->>'date_basis','activity')='created' then l.created_date_eastern else l.lead_date_eastern end between p_from and p_to
  ), page_rows as (
    select l.id,l.first_name,l.last_name,l.phone,l.email,l.lead_status,report_api.classified_lead_type(l) lead_type,l.vendor,l.user_name,l.user_id,
      l.address,l.address_2,l.city,coalesce(nullif(trim(l.property_state),''),g.geo_state) property_state,l.property_zip,
      g.county,g.metro,g.match_method geo_match_method,l.lead_date_eastern lead_date,l.created_date_eastern created_date,
      l.first_live_date_eastern first_live_date,l.live_email_sent,l.fub_id,
      l.source_lead_description,report_api.appointment_type(l) appointment_type
    from selected l
    left join lateral report_api.resolve_geo(l.property_zip,l.property_state,l.city) g on true
    order by l.lead_date_eastern desc nulls last,l.id desc
    limit v_size offset (v_page-1)*v_size
  )
  select jsonb_build_object('total',(select count(*) from selected),'page',v_page,'page_size',v_size,
    'rows',coalesce((select jsonb_agg(to_jsonb(r)) from page_rows r),'[]'::jsonb),'generated_at',now()) into v_result;
  return v_result;
end;
$$;

commit;
