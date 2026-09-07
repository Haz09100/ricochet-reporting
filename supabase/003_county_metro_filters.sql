-- County and metro filtering for the GitHub dashboard.
-- Run this after 001_github_dashboard_api.sql, then run 004_zip_geo_lookup_data.sql.

begin;

create table if not exists public.zip_geo_lookup (
  zip_code text primary key check (zip_code ~ '^[0-9]{5}$'),
  state text not null check (state ~ '^[A-Z]{2}$'),
  county text not null,
  metro text,
  city text,
  source text not null default 'Zillow ZHVI ZIP geography',
  updated_at timestamptz not null default now()
);

create index if not exists zip_geo_lookup_state_county_idx
  on public.zip_geo_lookup (state, county);
create index if not exists zip_geo_lookup_state_metro_idx
  on public.zip_geo_lookup (state, metro);

alter table public.zip_geo_lookup enable row level security;
revoke all on table public.zip_geo_lookup from public, anon, authenticated;

create or replace function report_api.normalize_zip(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  with cleaned as (
    select regexp_replace(coalesce(p_value,''), '[^0-9]', '', 'g') digits
  )
  select case
    when length(digits) >= 5 then left(digits,5)
    when length(digits) = 4 then lpad(digits,5,'0')
    else null
  end
  from cleaned
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
      or upper(trim(coalesce(nullif((p_lead).property_state,''),(
        select g.state from public.zip_geo_lookup g where g.zip_code=report_api.normalize_zip((p_lead).property_zip)
      ),''))) = upper(trim(jsonb_extract_path_text(p_filters,'state'))))
    and (nullif(trim(coalesce(jsonb_extract_path_text(p_filters,'city'),'')),'') is null
      or lower(trim(coalesce((p_lead).city,''))) = lower(trim(jsonb_extract_path_text(p_filters,'city'))))
    and (
      not (coalesce(p_filters,'{}'::jsonb) ? 'counties')
      or exists (
        select 1
        from public.zip_geo_lookup g
        where g.zip_code=report_api.normalize_zip((p_lead).property_zip)
          and lower(trim(g.county)) in (
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
        from public.zip_geo_lookup g
        where g.zip_code=report_api.normalize_zip((p_lead).property_zip)
          and lower(trim(coalesce(g.metro,''))) in (
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

create or replace function report_api.has_lead_filters(p_filters jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select
    exists (
      select 1 from jsonb_each_text(coalesce(p_filters, '{}'::jsonb)) f
      where f.key in ('status','agent','vendor','lead_type','state','city','appointment_type',
        'source_description','address_quality','email_status','search')
        and nullif(trim(coalesce(f.value, '')), '') is not null
    )
    or coalesce(p_filters,'{}'::jsonb) ? 'counties'
    or coalesce(p_filters,'{}'::jsonb) ? 'metros'
$$;

create or replace function public.dashboard_geo_options(p_state text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_state text := upper(trim(coalesce(p_state,''))); v_result jsonb;
begin
  perform report_api.assert_access();
  if v_state !~ '^[A-Z]{2}$' then
    return jsonb_build_object('state',v_state,'counties','[]'::jsonb,'metros','[]'::jsonb,'mapped_zip_codes',0);
  end if;
  select jsonb_build_object(
    'state',v_state,
    'counties',coalesce((select jsonb_agg(county order by county) from (select distinct county from public.zip_geo_lookup where state=v_state) c),'[]'::jsonb),
    'metros',coalesce((select jsonb_agg(metro order by metro) from (select distinct metro from public.zip_geo_lookup where state=v_state and nullif(trim(metro),'') is not null) m),'[]'::jsonb),
    'mapped_zip_codes',(select count(*) from public.zip_geo_lookup where state=v_state)
  ) into v_result;
  return v_result;
end;
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
      l.address,l.address_2,l.city,coalesce(nullif(l.property_state,''),g.state) property_state,l.property_zip,
      g.county,g.metro,l.lead_date_eastern lead_date,l.created_date_eastern created_date,
      l.first_live_date_eastern first_live_date,l.live_email_sent,l.fub_id
    from selected l
    left join public.zip_geo_lookup g on g.zip_code=report_api.normalize_zip(l.property_zip)
    order by l.lead_date_eastern desc nulls last,l.id desc
    limit v_size offset (v_page-1)*v_size
  )
  select jsonb_build_object('total',(select count(*) from selected),'page',v_page,'page_size',v_size,
    'rows',coalesce((select jsonb_agg(to_jsonb(r)) from page_rows r),'[]'::jsonb),'generated_at',now()) into v_result;
  return v_result;
end;
$$;

revoke execute on function public.dashboard_geo_options(text) from public, anon;
grant execute on function public.dashboard_geo_options(text) to authenticated;

commit;
