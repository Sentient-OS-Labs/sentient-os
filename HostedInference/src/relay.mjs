// Compose hosted routes with the existing Double Tap handler. Root routes and Durable Object
// exports retain their original implementation. Activation is an explicit operator setting.
import {proofread} from './proofread.mjs';
import {summarize} from './summarize.mjs';

export function composeRelay(legacy, hosted) {
  return {
    async fetch(request,env,context) {
      const url=new URL(request.url);
      if (url.pathname === '/v1/proofread') return proofread(request, env);
      if(url.pathname==='/v1/summarize') return summarize(request,env);
      if(url.pathname==='/hosted' || url.pathname.startsWith('/hosted/')) {
        if(env.SENTIENT_HOSTED_ROUTES_ENABLED!=='true') return Response.json({error:{code:'service_disabled'}},{status:503,headers:{'cache-control':'no-store'}});
        url.pathname=url.pathname.slice('/hosted'.length)||'/';
        return hosted.fetch(new Request(url,request),env,context);
      }
      return legacy.fetch(request,env,context);
    },
    async scheduled(event,env,context) {
      if(legacy.scheduled) await legacy.scheduled(event,env,context);
      // Revocation and session cleanup continue through an admission kill switch.
      if(env.COMPOSIO_API_KEY && env.SUPABASE_SERVICE_ROLE_KEY) {
        try {await hosted.scheduled(event,env,context);}catch{/* Retry on the next scheduled sweep; never log payloads. */}
      }
    },
  };
}
