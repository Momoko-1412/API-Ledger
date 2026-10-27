import {extractPrices} from './normalize.mjs';
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Cache-Control':'no-store'};
const reply=(status:number,obj:unknown)=>new Response(JSON.stringify(obj),{status,headers:{'Content-Type':'application/json; charset=utf-8',...cors}});
function safeOrigin(raw:unknown){
 if(typeof raw!=='string'||raw.length>220)return null;
 try { const u=new URL(raw); const h=u.hostname.toLowerCase();
  if(!['https:','http:'].includes(u.protocol)||u.username||u.password||u.port||u.search||u.hash||u.pathname!=='/'||!h.includes('.')||h==='localhost'||h.endsWith('.local')||h.endsWith('.internal')||h.endsWith('.localhost')||h.endsWith('.test')||h.endsWith('.invalid')||/^[0-9.:[\]]+$/.test(h)||h.includes('..'))return null;
  return u.origin;
 }catch(_){return null;}
}
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
 if(req.method!=='POST')return reply(405,{error:'POST required'});
 const jwt=req.headers.get('authorization')||'';
 if(!/^Bearer \S+$/.test(jwt))return reply(401,{error:'Login required'});
 const base=Deno.env.get('SUPABASE_URL'),anon=Deno.env.get('SUPABASE_ANON_KEY');
 if(!base||!anon)return reply(503,{error:'Supabase environment unavailable'});
 const headers={apikey:anon,authorization:jwt};
 try{const r=await fetch(base+'/auth/v1/user',{headers,signal:AbortSignal.timeout(5000)});if(!r.ok)return reply(401,{error:'Invalid login'});}catch(_){return reply(503,{error:'Auth unavailable'});}
 let payload:unknown;try{payload=await req.json();}catch(_){return reply(400,{error:'Invalid JSON'});}
 const key=(payload as Record<string,unknown>)?.site;
 if(typeof key!=='string'||!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(key))return reply(400,{error:'Invalid station key'});
 try{
  const [stationResponse,familyResponse]=await Promise.all([
   fetch(base+'/rest/v1/hsb_price_sources?select=station_name,base_url,collection_mode,auto_sync,enabled&site_key=eq.'+encodeURIComponent(key)+'&limit=1',{headers,signal:AbortSignal.timeout(5000)}),
   fetch(base+'/rest/v1/hsb_price_model_families?select=family_key,match_pattern&enabled=eq.true&order=sort_order.asc',{headers,signal:AbortSignal.timeout(5000)})
  ]);
  if(!stationResponse.ok||!familyResponse.ok)return reply(502,{error:'Failed to read pricing configuration'});
  const stations=await stationResponse.json(),families=await familyResponse.json();
  if(!Array.isArray(stations)||stations.length!==1||!Array.isArray(families)||!families.length)return reply(400,{error:'No configured station or models'});
  const station=stations[0];
  if(!station.enabled||!station.auto_sync||station.collection_mode!=='newapi')return reply(403,{error:'Station not eligible for public sync'});
  const origin=safeOrigin(station.base_url);if(!origin)return reply(400,{error:'Invalid HTTP(S) source origin'});
  const response=await fetch(origin+'/api/pricing',{method:'GET',redirect:'manual',headers:{Accept:'application/json'},signal:AbortSignal.timeout(12000)});
  if(!response.ok)return reply(502,{error:'Source HTTP '+response.status});
  const raw=await response.text();if(raw.length>3000000)return reply(502,{error:'Response too large'});
  let parsed:unknown;try{parsed=JSON.parse(raw);}catch(_){return reply(502,{error:'Not JSON'});}
  const result=extractPrices(parsed,{origin},families);
  if(result.rows.length===0)return reply(422,{error:'No matching models; existing prices preserved'});
  const ledgerRes=await fetch(base+'/rest/v1/hsb_stations?select=normal_recharge_amount,normal_received_quota&name=eq.'+encodeURIComponent(station.station_name)+'&limit=2',{headers,signal:AbortSignal.timeout(5000)});
  if(!ledgerRes.ok)return reply(502,{error:'Station exchange ratio unavailable'});
  const ledgerRows=await ledgerRes.json();
  if(!Array.isArray(ledgerRows)||ledgerRows.length!==1)return reply(422,{error:'Station exchange ratio missing or ambiguous'});
  const numerator=Number(ledgerRows[0].normal_recharge_amount);
  const denominator=Number(ledgerRows[0].normal_received_quota);
  if(!Number.isFinite(numerator)||!Number.isFinite(denominator)||numerator<=0||denominator<=0)
    return reply(422,{error:'Invalid station exchange ratio'});
  const cnyPerQuota=numerator/denominator;
  // Convert only fresh raw API quotes. Previously saved CNY catalog prices are never converted twice.
  const converted=result.rows.map(row=>({...row,
    price_per_call:row.price_per_call===null?null:Number((row.price_per_call*cnyPerQuota).toPrecision(14)),
    price_input:row.price_input===null?null:Number((row.price_input*cnyPerQuota).toPrecision(14)),
    price_output:row.price_output===null?null:Number((row.price_output*cnyPerQuota).toPrecision(14)),
    price_cache_read:row.price_cache_read===null?null:Number((row.price_cache_read*cnyPerQuota).toPrecision(14)),
    price_cache_write:row.price_cache_write===null?null:Number((row.price_cache_write*cnyPerQuota).toPrecision(14))
  }));
  return reply(200,{site:station.station_name,siteKey:key,...result,rows:converted,cnyPerQuota});
 }catch(e){return reply(502,{error:e instanceof Error?e.message:'Sync failed'});}
});
