// Only canonical public YouTube video IDs leave the relay. Never fetch arbitrary source URLs.
import {boundedJSON, ServiceError} from './errors.mjs';
export function youtubeURL(value) {
  if (typeof value !== 'string') return null;
  let url; try {url = new URL(value);} catch {return null;}
  if (!['https:','http:'].includes(url.protocol) || url.username || url.password || url.port) return null;
  let id;
  if (url.hostname === 'youtu.be') id = url.pathname.slice(1);
  else if (['youtube.com','www.youtube.com','m.youtube.com'].includes(url.hostname)) {
    if (url.pathname === '/watch') id = url.searchParams.get('v');
    else id = /^\/(?:shorts|live|embed)\/([\w-]{11})\/?$/.exec(url.pathname)?.[1];
  }
  return /^[\w-]{11}$/.test(id ?? '') ? `https://www.youtube.com/watch?v=${id}` : null;
}
export function boundedTranscript(text, limit=26000) {
  const encoder=new TextEncoder();
  if(encoder.encode(text).length<=limit)return {text,truncated:false};
  // Sample the entire video in order, keeping the opening and conclusion.
  const chunks=Array.from(text), count=24, per=Math.floor((limit-1500)/count);
  const pieces=[];
  for(let i=0;i<count;i++){
    const offset=Math.floor(i*(chunks.length-per)/(count-1));
    let piece='',bytes=0;
    for(let j=Math.max(0,offset);j<chunks.length;j++){
      const n=encoder.encode(chunks[j]).length;if(bytes+n>per)break;piece+=chunks[j];bytes+=n;
    }
    if(i===count-1){
      piece='';bytes=0;
      for(let j=chunks.length-1;j>=0;j--){
        const n=encoder.encode(chunks[j]).length;if(bytes+n>per)break;piece=chunks[j]+piece;bytes+=n;
      }
    }
    pieces.push(piece);
  }
  return {text:pieces.join('\n[... excerpt gap ...]\n'),truncated:true};
}
export async function youtubeTranscript(url,env,signal,upstream=fetch){
  if(!env.SUPADATA_API_KEY)throw new ServiceError('transcript_unavailable',424);
  const timeout=AbortSignal.any([signal,AbortSignal.timeout(12000)]);
  const endpoint=new URL('https://api.supadata.ai/v1/transcript');
  endpoint.search=new URLSearchParams({url,text:'true',mode:'native',lang:'en'}).toString();
  async function get(endpoint){
    let response;
    try {response=await upstream(endpoint.toString(),{headers:{'x-api-key':env.SUPADATA_API_KEY},redirect:'manual',signal:timeout});}
    catch {throw new ServiceError('transcript_unavailable',424);}
    if(!response.ok){await response.body?.cancel();throw new ServiceError('transcript_unavailable',424);}
    return boundedJSON(response,4_000_000);
  }
  let result=await get(endpoint);
  if(result.jobId && /^[\w-]{1,100}$/.test(result.jobId)){
    const job=result.jobId;
    for(let i=0;i<10;i++){
      await new Promise(resolve=>setTimeout(resolve,1000));
      if(timeout.aborted)throw new ServiceError('transcript_unavailable',424);
      result=await get(`https://api.supadata.ai/v1/transcript/${job}`);
      if(result.status==='failed')throw new ServiceError('transcript_unavailable',424);
      if(result.status==='completed')break;
    }
  }
  if(typeof result.content!=='string'||!result.content.trim())throw new ServiceError('transcript_unavailable',424);
  return {...boundedTranscript(result.content),language:typeof result.lang==='string'?result.lang.slice(0,20):''};
}
