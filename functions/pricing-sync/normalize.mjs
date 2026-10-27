// Shared pure parser for the public NewAPI /api/pricing response.
// No currencies are converted: these stations treat both $ and ¥ nominal values as RMB.
export const FAMILIES = Object.freeze([
  'gemini-3.7-flash','gemini-3.8-flash','gemini-4-Argon',
  'claude-opus-5.5','claude-opus-5',
  'claude-sonnet-5.5','claude-sonnet-5',
  'deepseek-v4.1-flash','deepseek-v4-pro'
]);

// Match only the complete requested model name, optionally with -high/-xhigh/-max.
// Channel prefixes such as "[vertex]" or "AU【xxx】" are retained, not treated
// as model suffixes. Alias "5-5" is the dotted version "5.5", NOT "-5".
export function identifyFamily(name,configuredFamilies) {
  if(Array.isArray(configuredFamilies)){
    const text=String(name||'').normalize('NFKC').trim().toLowerCase().replace(/[_\s/]+/g,'-');
    for(const f of configuredFamilies){try{const m=new RegExp(f.match_pattern,'i').exec(text);if(m&&(m.index===0||/[^a-z0-9]/.test(text[m.index-1])))return f.family_key;}catch(_){}}
    return null;
  }
  const text = String(name || '').normalize('NFKC').trim().toLowerCase()
    .replace(/[_\s/]+/g,'-');
  const patterns = [
    [/gemini-3[.-]7-flash(?:-(?:high|xhigh|max))?$/,'gemini-3.7-flash'],
    [/gemini-3[.-]8-flash(?:-(?:high|xhigh|max))?$/,'gemini-3.8-flash'],
    [/gemini-4-argon(?:-(?:high|xhigh|max))?$/,'gemini-4-Argon'],
    [/claude-opus-5[.-]5(?:-(?:high|xhigh|max))?$/,'claude-opus-5.5'],
    [/claude-opus-5(?:-(?:high|xhigh|max))?$/,'claude-opus-5'],
    [/claude-sonnet-5[.-]5(?:-(?:high|xhigh|max))?$/,'claude-sonnet-5.5'],
    [/claude-sonnet-5(?:-(?:high|xhigh|max))?$/,'claude-sonnet-5'],
    [/deepseek-v4[.-]1-flash(?:-(?:0731|0813|0910|1017))?$/,'deepseek-v4.1-flash'],
    [/deepseek-v4-pro(?:-(?:0731|0813|0910|1017))?$/,'deepseek-v4-pro']
  ];
  for(const [rx,family] of patterns) {
    const match = rx.exec(text);
    if(match && (match.index === 0 || /[^a-z0-9]/.test(text[match.index-1])))
      return family;
  }
  return null;
}
function samePriceKey(row) {
  // Normalize harmless floating-point artifacts (8.999999999999801 ~ 9).
  const amount = v => v == null ? '' : Number(Number(v).toPrecision(12)).toString();
  return [
    row.model_name.normalize('NFKC').trim().toLowerCase(),
    row.billing_type, row.unit,
    amount(row.price_per_call),amount(row.price_input),amount(row.price_output),
    amount(row.price_cache_read),amount(row.price_cache_write)
  ].join('\u001f');
}

const nonNegative=(v)=>{
  if(v===null||v===undefined||v==='')return null;
  const n=Number(v);
  return Number.isFinite(n)&&n>=0?n:null;
};
function prefixOf(name){
  return [...String(name).matchAll(/[\[【]([^\]】]{1,40})[\]】]/g)].map(x=>x[1]).join(' / ');
}

export function extractPrices(payload,site,configuredFamilies) {
  // Invalid/unrecognized payloads must NEVER be interpreted as an empty price
  // list, since an empty result intentionally removes stale records for a site.
  if(payload?.success===false)throw new Error('价格接口返回失败状态');
  const models=Array.isArray(payload?.data) ? payload.data
    : (Array.isArray(payload?.data?.data) ? payload.data.data : null);
  if(!models)throw new Error('价格接口未返回可识别的模型数组');
  const groupRatios=(payload?.group_ratio && typeof payload.group_ratio==='object')
    ? payload.group_ratio:{};
  const rows=[];
  const seen=new Set();
  let unsupported=0;
  for(const m of models) {
    if(!m||typeof m.model_name!=='string')continue;
    const family=identifyFamily(m.model_name,configuredFamilies);
    if(!family)continue;
    const billing=Number(m.quota_type);
    // Treat as dynamic only when the source explicitly marks it as such.
    const explicitDynamic=m.billing_type==='dynamic'||m.pricing_type==='dynamic'||
      m.is_dynamic===true||m.dynamic_pricing===true;
    if(billing!==0&&billing!==1){unsupported++;continue;}
    // NewAPI documents "enable_group" (singular); some forks use "enable_groups".
    const stated=Array.isArray(m.enable_group)?m.enable_group:
      Array.isArray(m.enable_groups)?m.enable_groups:null;
    const groups=stated===null?['default']:stated.filter(x=>typeof x==='string');
    if(groups.length===0){unsupported++;continue;}
    for(const group of [...new Set(groups)].slice(0,20)){
      const mult=nonNegative(groupRatios[group]);
      // Never assume an unknown VIP/group discount is 1.0 and misstate its price.
      if(mult===null&&group!=='default'){unsupported++;continue;}
      const gr=mult===null?1:mult;
      const row={
        source_url:site.origin+'/api/pricing',family,
        model_name:m.model_name,channel_name:prefixOf(m.model_name),
        group_name:group==='default'?'':group,
        billing_type:billing===1?'per_call':explicitDynamic?'dynamic':'per_token',
        price_per_call:null,price_input:null,price_output:null,
        price_cache_read:null,price_cache_write:null,
        unit:billing===1?'CNY/call':'CNY/1M_tokens'
      };
      if(billing===1) {
        const price=nonNegative(m.model_price);
        if(price===null)continue;
        row.price_per_call=price*gr;
      }else{
        const ratio=nonNegative(m.model_ratio);
        const completion=nonNegative(m.completion_ratio);
        if(ratio===null||completion===null)continue;
        // NewAPI/OneAPI standard 2 currency units per 1M input tokens at ratio 1.
        const price=ratio*2*gr;
        row.price_input=price;
        row.price_output=price*completion;
        const cache=nonNegative(m.cache_ratio),write=nonNegative(m.create_cache_ratio);
        if(cache!==null)row.price_cache_read=price*cache;
        if(write!==null)row.price_cache_write=price*write;
      }
      // Same model, billing type and effective price in several NewAPI groups
      // is ONE offer. Keep distinct groups only when their effective price differs.
      const identity=samePriceKey(row);
      if(seen.has(identity))continue;
      seen.add(identity);
      rows.push(row);
      if(rows.length>=500)break;
    }
    if(rows.length>=500)break;
  }
  return {rows,modelCount:models.length,unsupported,currency:'CNY',pricingMethod:'NewAPI /api/pricing'};
}
