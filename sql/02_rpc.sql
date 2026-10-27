-- API Ledger v1.1, sourced from verified deployed Supabase RPCs.
-- Install AFTER 01_schema.sql. No users, URLs, stations, prices, or credentials are prefilled.
-- The first six target-user overloads only accept calls by actual service_role.

CREATE OR REPLACE FUNCTION public.rpc_archive_station(p_station_name text, p_is_archived boolean)
 RETURNS SETOF hsb_stations
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 return query update public.hsb_stations
 set is_archived=p_is_archived,updated_at=now()
 where user_id=auth.uid() and name=p_station_name returning *;
end $function$;

CREATE OR REPLACE FUNCTION public.rpc_archive_station(p_target_user_id uuid, p_station_name text, p_is_archived boolean)
 RETURNS SETOF hsb_stations
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if current_user <> 'service_role' or p_target_user_id is null then
 raise exception 'Service role and target_user_id required' using errcode='42501';end if;
 return query update public.hsb_stations set is_archived=p_is_archived,updated_at=now()
 where user_id=p_target_user_id and name=p_station_name returning *;
end $function$;

CREATE OR REPLACE FUNCTION public.rpc_get_full_summary(p_include_archived boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
 select coalesce(jsonb_agg(s_json order by s_json->>'name'),'[]'::jsonb) from (
  select jsonb_build_object(
    'id',s.id,'name',s.name,'recharge_amount',s.recharge_amount,'received_quota',s.received_quota,
    'current_balance',s.current_balance,'note',s.note,'is_archived',s.is_archived,
    'normal_recharge_amount',s.normal_recharge_amount,'normal_received_quota',s.normal_received_quota,
    'effective_price_per_quota',s.effective_price_per_quota,'total_used_quota',s.total_used_quota,
    'transactions',coalesce((select jsonb_agg(row_to_json(t) order by t.record_date desc,t.created_at desc)
                              from public.hsb_station_transactions t where t.station_id=s.id),'[]'::jsonb),
    'balance_log',coalesce((select jsonb_agg(row_to_json(b) order by b.record_date desc,b.created_at desc)
                            from public.hsb_station_balance_log b where b.station_id=s.id),'[]'::jsonb),
    'models',coalesce((select jsonb_agg(row_to_json(m) order by m.model_name asc)
                       from public.hsb_station_models m where m.station_id=s.id),'[]'::jsonb)
  ) as s_json from public.hsb_stations s
  where s.user_id=auth.uid() and (p_include_archived or not s.is_archived)
 ) sub;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_get_full_summary(p_target_user_id uuid, p_include_archived boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_summary jsonb;
begin
 if current_user <> 'service_role' or p_target_user_id is null then
 raise exception 'Service role and target_user_id required' using errcode='42501';end if;
 select coalesce(jsonb_agg(s_json order by s_json->>'name'),'[]'::jsonb)
 into v_summary from (
 select jsonb_build_object(
 'id',s.id,'name',s.name,'recharge_amount',s.recharge_amount,
 'received_quota',s.received_quota,'current_balance',s.current_balance,
 'note',s.note,'is_archived',s.is_archived,
 'normal_recharge_amount',s.normal_recharge_amount,
 'normal_received_quota',s.normal_received_quota,
 'effective_price_per_quota',s.effective_price_per_quota,
 'total_used_quota',s.total_used_quota,
 'transactions',coalesce((select jsonb_agg(row_to_json(t) order by t.record_date desc,t.created_at desc)
 from public.hsb_station_transactions t where t.station_id=s.id),'[]'::jsonb),
 'balance_log',coalesce((select jsonb_agg(row_to_json(b) order by b.record_date desc,b.created_at desc)
 from public.hsb_station_balance_log b where b.station_id=s.id),'[]'::jsonb),
 'models',coalesce((select jsonb_agg(row_to_json(m) order by m.model_name)
 from public.hsb_station_models m where m.station_id=s.id),'[]'::jsonb)
 ) as s_json from public.hsb_stations s
 where s.user_id=p_target_user_id and (p_include_archived or not s.is_archived)
 ) sub;
 return v_summary;
end $function$;

CREATE OR REPLACE FUNCTION public.rpc_record_balance_growth(p_station_name text, p_quota_amount numeric, p_rmb_amount numeric DEFAULT NULL::numeric, p_record_date date DEFAULT CURRENT_DATE, p_note text DEFAULT NULL::text)
 RETURNS SETOF hsb_station_balance_log
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare sid uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 select id into sid from public.hsb_stations where user_id=auth.uid() and name=p_station_name;
 if sid is null then raise exception 'Station not found';end if;
 update public.hsb_stations set current_balance=current_balance+p_quota_amount,updated_at=now()
 where id=sid and user_id=auth.uid();
 return query insert into public.hsb_station_balance_log(station_id,record_date,quota_amount,rmb_amount,note)
 values(sid,p_record_date,p_quota_amount,p_rmb_amount,p_note) returning *;
end $function$;

CREATE OR REPLACE FUNCTION public.rpc_record_balance_growth(p_target_user_id uuid, p_station_name text, p_quota_amount numeric, p_rmb_amount numeric DEFAULT NULL::numeric, p_record_date date DEFAULT CURRENT_DATE, p_note text DEFAULT NULL::text)
 RETURNS SETOF hsb_station_balance_log
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_station_id uuid;
begin
 if current_user <> 'service_role' or p_target_user_id is null then
 raise exception 'Service role and target_user_id required' using errcode='42501';end if;
 if p_quota_amount is null then raise exception 'Quota amount required';end if;
 select id into v_station_id from public.hsb_stations
 where user_id=p_target_user_id and name=p_station_name for update;
 if v_station_id is null then raise exception 'Station not found';end if;
 update public.hsb_stations set current_balance=current_balance+p_quota_amount,updated_at=now()
 where id=v_station_id and user_id=p_target_user_id;
 return query insert into public.hsb_station_balance_log
 (station_id,record_date,quota_amount,rmb_amount,note)
 values(v_station_id,p_record_date,p_quota_amount,p_rmb_amount,p_note) returning *;
end $function$;

CREATE OR REPLACE FUNCTION public.rpc_record_transaction(p_station_name text, p_consumed_quota numeric, p_record_date date, p_call_count integer DEFAULT NULL::integer, p_model_name text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS SETOF hsb_station_transactions
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare sid uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 select id into sid from public.hsb_stations where user_id=auth.uid() and name=p_station_name;
 if sid is null then raise exception 'Station not found';end if;
 update public.hsb_stations set current_balance=current_balance-p_consumed_quota,updated_at=now()
 where id=sid and user_id=auth.uid();
 return query insert into public.hsb_station_transactions(station_id,record_date,consumed_quota,call_count,model_name,note)
 values(sid,p_record_date,p_consumed_quota,p_call_count,p_model_name,p_note) returning *;
end $function$;

CREATE OR REPLACE FUNCTION public.rpc_record_transaction(p_target_user_id uuid, p_station_name text, p_consumed_quota numeric, p_record_date date, p_call_count integer DEFAULT NULL::integer, p_model_name text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS SETOF hsb_station_transactions
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_station_id uuid;
begin
 if current_user <> 'service_role' or p_target_user_id is null then
 raise exception 'Service role and target_user_id required' using errcode='42501';end if;
 if p_consumed_quota is null then raise exception 'Quota amount required';end if;
 select id into v_station_id from public.hsb_stations
 where user_id=p_target_user_id and name=p_station_name for update;
 if v_station_id is null then raise exception 'Station not found';end if;
 update public.hsb_stations set current_balance=current_balance-p_consumed_quota,updated_at=now()
 where id=v_station_id and user_id=p_target_user_id;
 return query insert into public.hsb_station_transactions
 (station_id,record_date,consumed_quota,call_count,model_name,note)
 values(v_station_id,p_record_date,p_consumed_quota,p_call_count,p_model_name,p_note) returning *;
end $function$;

CREATE OR REPLACE FUNCTION public.rpc_replace_station_model_prices(p_station_name text, p_rows jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_count integer;
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 if not exists(select 1 from public.hsb_price_sources s where s.user_id=auth.uid() and s.station_name=p_station_name and s.enabled)
 then raise exception 'Unconfigured or disabled price source';end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>500
 then raise exception 'Invalid pricing data';end if;
 if jsonb_array_length(p_rows)=0 then raise exception 'Empty pricing data cannot replace existing prices';end if;
 if exists(select 1 from jsonb_to_recordset(p_rows) as r(family text,billing_type text,model_name text,source_url text)
 where r.family is null or r.model_name is null or r.model_name='' or r.source_url!~'^https?://'
 or r.billing_type not in ('per_call','per_token','dynamic')
 or not exists(select 1 from public.hsb_price_model_families f where f.user_id=auth.uid() and f.enabled and f.family_key=r.family)
 ) then raise exception 'Invalid or unconfigured model price row';end if;
 delete from public.hsb_model_price_catalog where user_id=auth.uid() and station_name=p_station_name;
 insert into public.hsb_model_price_catalog
 (user_id,station_name,source_url,family,model_name,channel_name,group_name,billing_type,price_per_call,
 price_input,price_output,price_cache_read,price_cache_write,unit,currency,collected_at)
 select auth.uid(),p_station_name,r.source_url,r.family,r.model_name,coalesce(r.channel_name,''),
 coalesce(r.group_name,''),r.billing_type,r.price_per_call,r.price_input,r.price_output,
 r.price_cache_read,r.price_cache_write,r.unit,'CNY',now()
 from jsonb_to_recordset(p_rows) as r(source_url text,family text,model_name text,
 channel_name text,group_name text,billing_type text,price_per_call numeric,
 price_input numeric,price_output numeric,price_cache_read numeric,
 price_cache_write numeric,unit text);
 get diagnostics v_count=row_count;return v_count;
end;$function$;

CREATE OR REPLACE FUNCTION public.rpc_upsert_model_pricing(p_station_name text, p_model_name text, p_pricing_type text, p_input_price numeric DEFAULT NULL::numeric, p_output_price numeric DEFAULT NULL::numeric, p_per_call_price numeric DEFAULT NULL::numeric)
 RETURNS SETOF hsb_station_models
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare sid uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 select id into sid from public.hsb_stations where user_id=auth.uid() and name=p_station_name;
 if sid is null then raise exception 'Station not found';end if;
 return query insert into public.hsb_station_models(station_id,model_name,pricing_type,input_price,output_price,per_call_price)
 values(sid,p_model_name,p_pricing_type,p_input_price,p_output_price,p_per_call_price)
 on conflict(station_id,model_name) do update set pricing_type=excluded.pricing_type,input_price=excluded.input_price,
 output_price=excluded.output_price,per_call_price=excluded.per_call_price,updated_at=now() returning *;
end $function$;

CREATE OR REPLACE FUNCTION public.rpc_upsert_model_pricing(p_target_user_id uuid, p_station_name text, p_model_name text, p_pricing_type text, p_input_price numeric DEFAULT NULL::numeric, p_output_price numeric DEFAULT NULL::numeric, p_per_call_price numeric DEFAULT NULL::numeric)
 RETURNS SETOF hsb_station_models
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_station_id uuid;
begin
 if current_user <> 'service_role' or p_target_user_id is null then
 raise exception 'Service role and target_user_id required' using errcode='42501';end if;
 select id into v_station_id from public.hsb_stations
 where user_id=p_target_user_id and name=p_station_name;
 if v_station_id is null then raise exception 'Station not found';end if;
 return query insert into public.hsb_station_models
 (station_id,model_name,pricing_type,input_price,output_price,per_call_price)
 values(v_station_id,p_model_name,p_pricing_type,p_input_price,p_output_price,p_per_call_price)
 on conflict(station_id,model_name) do update set
 pricing_type=excluded.pricing_type,
 input_price=excluded.input_price,
 output_price=excluded.output_price,
 per_call_price=excluded.per_call_price,
 updated_at=now() returning *;
end $function$;

CREATE OR REPLACE FUNCTION public.rpc_upsert_station(p_name text, p_recharge_amount numeric DEFAULT NULL::numeric, p_received_quota numeric DEFAULT NULL::numeric, p_current_balance numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text, p_is_archived boolean DEFAULT NULL::boolean, p_normal_recharge_amount numeric DEFAULT NULL::numeric, p_normal_received_quota numeric DEFAULT NULL::numeric, p_total_used_quota numeric DEFAULT NULL::numeric)
 RETURNS SETOF hsb_stations
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null then raise exception 'Authentication required';end if;
 return query
 insert into public.hsb_stations(user_id,name,recharge_amount,received_quota,current_balance,note,is_archived,
 normal_recharge_amount,normal_received_quota,total_used_quota)
 values(auth.uid(),p_name,p_recharge_amount,p_received_quota,coalesce(p_current_balance,0),p_note,
 coalesce(p_is_archived,false),p_normal_recharge_amount,p_normal_received_quota,p_total_used_quota)
 on conflict(user_id,name) do update set
 recharge_amount=coalesce(excluded.recharge_amount,hsb_stations.recharge_amount),
 received_quota=coalesce(excluded.received_quota,hsb_stations.received_quota),
 current_balance=coalesce(p_current_balance,hsb_stations.current_balance),
 note=coalesce(p_note,hsb_stations.note),is_archived=coalesce(p_is_archived,hsb_stations.is_archived),
 normal_recharge_amount=coalesce(excluded.normal_recharge_amount,hsb_stations.normal_recharge_amount),
 normal_received_quota=coalesce(excluded.normal_received_quota,hsb_stations.normal_received_quota),
 total_used_quota=coalesce(excluded.total_used_quota,hsb_stations.total_used_quota),updated_at=now()
 returning *;
end $function$;

CREATE OR REPLACE FUNCTION public.rpc_upsert_station(p_target_user_id uuid, p_name text, p_recharge_amount numeric DEFAULT NULL::numeric, p_received_quota numeric DEFAULT NULL::numeric, p_current_balance numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text, p_is_archived boolean DEFAULT NULL::boolean, p_normal_recharge_amount numeric DEFAULT NULL::numeric, p_normal_received_quota numeric DEFAULT NULL::numeric, p_total_used_quota numeric DEFAULT NULL::numeric)
 RETURNS SETOF hsb_stations
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if current_user <> 'service_role' or p_target_user_id is null then
 raise exception 'Service role and target_user_id required' using errcode='42501';end if;
 if p_name is null or btrim(p_name)='' then raise exception 'Station name required';end if;
 return query insert into public.hsb_stations
 (user_id,name,recharge_amount,received_quota,current_balance,note,is_archived,
 normal_recharge_amount,normal_received_quota,total_used_quota)
 values(p_target_user_id,p_name,p_recharge_amount,p_received_quota,
 coalesce(p_current_balance,0),p_note,coalesce(p_is_archived,false),
 p_normal_recharge_amount,p_normal_received_quota,p_total_used_quota)
 on conflict(user_id,name) do update set
 recharge_amount=coalesce(excluded.recharge_amount,hsb_stations.recharge_amount),
 received_quota=coalesce(excluded.received_quota,hsb_stations.received_quota),
 current_balance=coalesce(p_current_balance,hsb_stations.current_balance),
 note=coalesce(p_note,hsb_stations.note),
 is_archived=coalesce(p_is_archived,hsb_stations.is_archived),
 normal_recharge_amount=coalesce(excluded.normal_recharge_amount,hsb_stations.normal_recharge_amount),
 normal_received_quota=coalesce(excluded.normal_received_quota,hsb_stations.normal_received_quota),
 total_used_quota=coalesce(excluded.total_used_quota,hsb_stations.total_used_quota),
 updated_at=now()
 returning *;
end $function$;

-- Explicit permissions: regular browser RPCs vs backend-only target_user_id overloads.
REVOKE ALL ON FUNCTION public.rpc_archive_station(text,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_archive_station(text,boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_archive_station(uuid,text,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_archive_station(uuid,text,boolean) TO service_role;
REVOKE ALL ON FUNCTION public.rpc_get_full_summary(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_full_summary(boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_get_full_summary(uuid,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_full_summary(uuid,boolean) TO service_role;
REVOKE ALL ON FUNCTION public.rpc_record_balance_growth(text,numeric,numeric,date,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_record_balance_growth(text,numeric,numeric,date,text) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_record_balance_growth(uuid,text,numeric,numeric,date,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_record_balance_growth(uuid,text,numeric,numeric,date,text) TO service_role;
REVOKE ALL ON FUNCTION public.rpc_record_transaction(text,numeric,date,integer,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_record_transaction(text,numeric,date,integer,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_record_transaction(uuid,text,numeric,date,integer,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_record_transaction(uuid,text,numeric,date,integer,text,text) TO service_role;
REVOKE ALL ON FUNCTION public.rpc_replace_station_model_prices(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_replace_station_model_prices(text,jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_upsert_model_pricing(text,text,text,numeric,numeric,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_upsert_model_pricing(text,text,text,numeric,numeric,numeric) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_upsert_model_pricing(uuid,text,text,text,numeric,numeric,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_upsert_model_pricing(uuid,text,text,text,numeric,numeric,numeric) TO service_role;
REVOKE ALL ON FUNCTION public.rpc_upsert_station(text,numeric,numeric,numeric,text,boolean,numeric,numeric,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_upsert_station(text,numeric,numeric,numeric,text,boolean,numeric,numeric,numeric) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_upsert_station(uuid,text,numeric,numeric,numeric,text,boolean,numeric,numeric,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_upsert_station(uuid,text,numeric,numeric,numeric,text,boolean,numeric,numeric,numeric) TO service_role;
