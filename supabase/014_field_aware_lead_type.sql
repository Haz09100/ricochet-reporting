-- Field-aware Buyer / Seller / Buyer and Seller classification.
-- Run after 013_authoritative_companion_decisions.sql.

begin;

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
  v_companion boolean;
  v_home_to_sell text;
  v_next_move text;
  v_open_buy_side text;
  v_buy_appointment text;
  v_next_home_city text;
  v_next_home_state text;
  v_next_home_zip text;
  v_next_home_budget text;
  v_next_home_timeline text;
  v_buyer_intent boolean := false;
  v_seller_intent boolean := false;
begin
  v_flat := trim(regexp_replace(v_text,'[^a-z0-9]+',' ','g'));
  v_seller_heading := v_text ~ '(^|[\r\n])[[:space:]]*seller([[:space:]]+(and[[:space:]]+)?buyer)?[[:space:]]+form([[:space:]:]|$)';
  v_buyer_heading := v_text ~ '(^|[\r\n])[[:space:]]*buyer([[:space:]]+(and[[:space:]]+)?seller)?[[:space:]]+form([[:space:]:]|$)';
  v_companion := v_text ~ 'disposition[[:space:]]*:[[:space:]]*companion[[:space:]]+opportunity'
    or v_text like '%leadflow_split_side%';

  -- Generated companion records stay on the side created by LeadFlow. Their
  -- template may repeat facts about the originating side, which must not turn
  -- one generated record into a second "Both" bonus.
  if v_companion and v_buyer_heading and not v_seller_heading then return 'Buyer'; end if;
  if v_companion and v_seller_heading and not v_buyer_heading then return 'Seller'; end if;
  if v_buyer_heading and v_seller_heading then return 'Buyer and Seller'; end if;

  -- Buyer Form: only the actual HOME TO SELL FIRST answer creates seller intent.
  -- Merely containing the template label "BUYER AND SELLER" is not evidence.
  v_home_to_sell := substring(v_text from 'home[[:space:]]+to[[:space:]]+sell[[:space:]]+first[[:space:]]*[?]?[[:space:]]*:[[:space:]]*([^\r\n]{0,160})');
  if v_buyer_heading then
    v_seller_intent := coalesce(v_home_to_sell ~ '^[[:space:]]*(yes|true|confirmed)([^a-z]|$)',false);
    if v_seller_intent then return 'Buyer and Seller'; end if;
    return 'Buyer';
  end if;

  -- Seller Form: classify as Both only when completed buy-side answers show
  -- real intent. Empty labels, placeholders, and negative answers do not count.
  v_next_move := substring(v_text from 'next[[:space:]]+move[[:space:]]+after[[:space:]]+sale[[:space:]]*[?]?[[:space:]]*:[[:space:]]*([^\r\n]{0,160})');
  v_open_buy_side := substring(v_text from 'open[[:space:]]+to[[:space:]]+speaking[[:space:]]+with[[:space:]]+a[[:space:]]+licensed[[:space:]]+agent[[:space:]]+for[[:space:]]+the[[:space:]]+buy[[:space:]]+side[[:space:]]*:[[:space:]]*([^\r\n]{0,160})');
  v_buy_appointment := substring(v_text from 'set[[:space:]]+appointment[[:space:]]+date[[:space:]]+and[[:space:]]+time[[:space:]]+for[[:space:]]+the[[:space:]]+buy[[:space:]]+side[[:space:]]*:[[:space:]]*([^\r\n]{0,180})');
  v_next_home_city := substring(v_text from 'next[[:space:]]+home[^\r\n:]{0,12}city[[:space:]]*:[[:space:]]*([^\r\n]{0,100})');
  v_next_home_state := substring(v_text from 'next[[:space:]]+home[^\r\n:]{0,12}state[[:space:]]*:[[:space:]]*([^\r\n]{0,80})');
  v_next_home_zip := substring(v_text from 'next[[:space:]]+home[^\r\n:]{0,20}zip[[:space:]]+code[[:space:]]*:[[:space:]]*([^\r\n]{0,80})');
  v_next_home_budget := substring(v_text from 'next[[:space:]]+home[^\r\n:]{0,20}price[[:space:]]+range[^\r\n:]{0,12}budget[[:space:]]*:[[:space:]]*([^\r\n]{0,120})');
  v_next_home_timeline := substring(v_text from 'next[[:space:]]+home[^\r\n:]{0,20}timeline[[:space:]]+to[[:space:]]+buy[[:space:]]*:[[:space:]]*([^\r\n]{0,120})');

  if v_seller_heading then
    v_buyer_intent :=
      coalesce(v_next_move ~ '^[[:space:]]*(buy|purchase)([^a-z]|$)',false)
      or coalesce(v_open_buy_side ~ '^[[:space:]]*(yes|true|confirmed)([^a-z]|$)',false)
      or coalesce(v_buy_appointment !~ '^[[:space:]]*(|\[|no([^a-z]|$)|none([^a-z]|$)|n/?a([^a-z]|$)|not[[:space:]]+(set|scheduled|yet|provided)|unknown)',false)
      or coalesce(v_next_home_city !~ '^[[:space:]]*(|\[|none([^a-z]|$)|n/?a([^a-z]|$)|not[[:space:]]+(set|known|provided)|unknown)',false)
      or coalesce(v_next_home_state !~ '^[[:space:]]*(|\[|none([^a-z]|$)|n/?a([^a-z]|$)|not[[:space:]]+(set|known|provided)|unknown)',false)
      or coalesce(v_next_home_zip !~ '^[[:space:]]*(|\[|none([^a-z]|$)|n/?a([^a-z]|$)|not[[:space:]]+(set|known|provided)|unknown)',false)
      or coalesce(v_next_home_budget !~ '^[[:space:]]*(|\[|none([^a-z]|$)|n/?a([^a-z]|$)|not[[:space:]]+(set|known|provided)|unknown)',false)
      or coalesce(v_next_home_timeline !~ '^[[:space:]]*(|\[|none([^a-z]|$)|n/?a([^a-z]|$)|not[[:space:]]+(set|known|provided)|unknown)',false);
    if v_buyer_intent then return 'Buyer and Seller'; end if;
    return 'Seller';
  end if;

  -- Older unstructured notes retain conservative phrase-based inference.
  v_buyer_intent :=
    v_text ~ '(want|wants|wanted|need|needs|plan|plans|planning|looking|ready|hoping)[[:space:]]+to[[:space:]]+(buy|purchase)'
    or v_text ~ '(buying|purchasing)[[:space:]]+(another|a|their|his|her)[[:space:]]+(home|house|property)';
  v_seller_intent :=
    v_text ~ '(want|wants|wanted|need|needs|plan|plans|planning|looking|ready|consider|considering)[[:space:]]+to[[:space:]]+sell'
    or v_flat like '% seller motivation and financials %'
    or v_text like '%why selling now:%';

  if v_buyer_intent and v_seller_intent then return 'Buyer and Seller'; end if;
  if v_buyer_intent then return 'Buyer'; end if;
  if v_seller_intent then return 'Seller'; end if;
  if v_stored in ('buyer and seller','seller and buyer','both') then return 'Buyer and Seller'; end if;
  if v_stored='buyer' then return 'Buyer'; end if;
  if v_stored='seller' then return 'Seller'; end if;
  return 'Unknown';
end;
$$;

commit;
