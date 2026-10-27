-- Sugar Ledger clean installation. Run ONCE in a BRAND NEW, EMPTY Supabase project.
-- Deliberately no INSERT statements: no personal accounts, stations, URLs or prices.
create extension if not exists pgcrypto;
create table public.hsb_stations(
 id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 name text not null,recharge_amount numeric,received_quota numeric,current_balance numeric not null default 0,note text,
 is_archived boolean not null default false,normal_recharge_amount numeric,normal_received_quota numeric,
 effective_price_per_quota numeric generated always as (
 case when normal_recharge_amount is not null and normal_received_quota is not null and normal_received_quota<>0 and
 recharge_amount is not null and received_quota is not null and received_quota<>0
 then ((normal_recharge_amount/normal_received_quota)+(recharge_amount/received_quota))/2
 when normal_recharge_amount is not null and normal_received_quota is not null and normal_received_quota<>0
 then normal_recharge_amount/normal_received_quota
 when recharge_amount is not null and received_quota is not null and received_quota<>0
 then recharge_amount/received_quota else null end) stored,
 total_used_quota numeric,price_base_url text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(user_id,name));
create table public.hsb_station_models(
 id uuid primary key default gen_random_uuid(),station_id uuid not null references public.hsb_stations(id) on delete cascade,
 model_name text not null,pricing_type text not null check(pricing_type in('token','per_call')),
 input_price numeric,output_price numeric,per_call_price numeric,updated_at timestamptz not null default now(),
 unique(station_id,model_name));
create table public.hsb_station_transactions(
 id uuid primary key default gen_random_uuid(),station_id uuid not null references public.hsb_stations(id) on delete cascade,
 record_date date not null,consumed_quota numeric not null,call_count integer,model_name text,note text,created_at timestamptz not null default now());
create table public.hsb_station_balance_log(
 id uuid primary key default gen_random_uuid(),station_id uuid not null references public.hsb_stations(id) on delete cascade,
 record_date date not null,quota_amount numeric not null,rmb_amount numeric,note text,created_at timestamptz not null default now());
create table public.hsb_model_price_catalog(
 id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 station_name text not null,source_url text not null,family text not null,model_name text not null,channel_name text not null default '',
 group_name text not null default '',billing_type text not null check(billing_type in('per_call','per_token','dynamic')),
 price_per_call numeric,price_input numeric,price_output numeric,price_cache_read numeric,price_cache_write numeric,
 unit text not null check(unit in('CNY/call','CNY/1M_tokens')),currency text not null default 'CNY' check(currency='CNY'),
 collected_at timestamptz not null default now(),unique(user_id,station_name,model_name,group_name,billing_type),
 check(price_per_call is null or price_per_call>=0),check(price_input is null or price_input>=0),
 check(price_output is null or price_output>=0),check(price_cache_read is null or price_cache_read>=0),
 check(price_cache_write is null or price_cache_write>=0));
create table public.hsb_price_channels(
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 channel_key text not null,display_name text not null,aliases text[] not null default '{}',
 priority_tier smallint not null default 0,sort_order smallint not null default 100,enabled boolean not null default true,
 primary key(user_id,channel_key));
create table public.hsb_price_model_families(
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 family_key text not null,display_name text not null,match_pattern text not null,
 sort_order smallint not null default 100,enabled boolean not null default true,primary key(user_id,family_key));
create table public.hsb_price_sources(
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 site_key text not null,station_name text not null,display_name text not null,base_url text,
 collection_mode text not null check(collection_mode in('newapi','hark','manual')),
 auto_sync boolean not null default false,enabled boolean not null default true,sort_order smallint not null default 100,
 primary key(user_id,site_key),unique(user_id,station_name));
create table public.hsb_price_sort_options(
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 sort_key text not null,display_name text not null,sort_kind text not null check(sort_kind in('numeric','text','group','aggregate')),
 sort_field text not null,group_field text,aggregate_function text,ascending boolean not null default true,
 sort_order smallint not null default 100,enabled boolean not null default true,primary key(user_id,sort_key));
create table public.hsb_price_ui_config(
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 config_key text not null,config_value jsonb not null default '{}'::jsonb,sort_order smallint not null default 100,primary key(user_id,config_key));
create table public.hsb_price_user_preferences(
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 pref_key text not null,pref_value jsonb not null default 'null'::jsonb,sort_order smallint not null default 100,primary key(user_id,pref_key));
create index hsb_catalog_user_family_idx on public.hsb_model_price_catalog(user_id,family);
do $$
declare tab text;
begin
 foreach tab in array array['hsb_stations','hsb_model_price_catalog','hsb_price_channels',
 'hsb_price_model_families','hsb_price_sources','hsb_price_sort_options',
 'hsb_price_ui_config','hsb_price_user_preferences']
 loop
 execute format('alter table public.%I enable row level security',tab);
 execute format('revoke all on public.%I from public,anon,authenticated',tab);
 execute format('grant select,insert,update,delete on public.%I to authenticated',tab);
 execute format('create policy owner_only on public.%I for all to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()))',tab);
 end loop;
 foreach tab in array array['hsb_station_models','hsb_station_transactions','hsb_station_balance_log']
 loop
 execute format('alter table public.%I enable row level security',tab);
 execute format('revoke all on public.%I from public,anon,authenticated',tab);
 execute format('grant select,insert,update,delete on public.%I to authenticated',tab);
 execute format('create policy owner_only on public.%I for all to authenticated using(exists(select 1 from public.hsb_stations s where s.id=station_id and s.user_id=(select auth.uid()))) with check(exists(select 1 from public.hsb_stations s where s.id=station_id and s.user_id=(select auth.uid())))',tab);
 end loop;
end $$;

-- Register ledger stations in the price source list automatically.
-- A missing price_base_url produces a visible manual source, not a fabricated URL.
-- A later UPDATE of price_base_url switches a generated source to NewAPI syncing.
-- Existing manually curated/Hark sources are not overwritten.
CREATE OR REPLACE FUNCTION public.hsb_auto_register_price_source()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=''
AS $f$
DECLARE
 generated_key text := 'station-' || replace(NEW.id::text,'-','');
 source_url text := nullif(btrim(NEW.price_base_url),'');
BEGIN
 IF source_url IS NOT NULL AND source_url !~* '^https?://[a-z0-9][a-z0-9.-]*\.[a-z]{2,}(:[0-9]{1,5})?/?$'
 THEN RAISE EXCEPTION 'Pricing URL must be a public HTTP(S) base origin'; END IF;
 IF EXISTS (
 SELECT 1 FROM public.hsb_price_sources
 WHERE user_id=NEW.user_id AND station_name=NEW.name AND site_key <> generated_key
 ) THEN RETURN NEW; END IF;
 INSERT INTO public.hsb_price_sources
 (user_id,site_key,station_name,display_name,base_url,collection_mode,auto_sync,enabled,sort_order)
 VALUES
 (NEW.user_id,generated_key,NEW.name,NEW.name,source_url,
 CASE WHEN source_url IS NULL THEN 'manual' ELSE 'newapi' END,
 source_url IS NOT NULL,true,100)
 ON CONFLICT (user_id,site_key) DO UPDATE
 SET station_name=EXCLUDED.station_name,display_name=EXCLUDED.display_name,
 base_url=EXCLUDED.base_url,collection_mode=EXCLUDED.collection_mode,
 auto_sync=EXCLUDED.auto_sync;
 RETURN NEW;
END $f$;
REVOKE ALL ON FUNCTION public.hsb_auto_register_price_source() FROM PUBLIC, anon;
CREATE TRIGGER hsb_auto_register_price_source_trigger
AFTER INSERT OR UPDATE OF name,price_base_url ON public.hsb_stations
FOR EACH ROW EXECUTE FUNCTION public.hsb_auto_register_price_source();
