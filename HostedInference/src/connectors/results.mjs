// Normalize bounded result envelopes and provider continuation tokens. Source content remains
// untrusted data. We never fetch an upstream URL returned in a payload or supplied by a client.
import { ServiceError } from '../errors.mjs';

export function normalizeResult(tool, data, args = {}) {
  // Some toolkit versions wrap the provider value in a data member.
  let payload = data;
  if (typeof payload.data === 'string') {
    try { payload = JSON.parse(payload.data); } catch { /* A real text document may be a string. */ }
  } else if (payload.data && typeof payload.data === 'object' && !Array.isArray(payload.data)) payload = payload.data;
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new ServiceError('connector_invalid_response', 502);
  if (payload.error || payload.ok === false || payload.successful === false || payload.incompleteSearch === true) throw new ServiceError('connector_execution_failed', 502);
  const permittedOutlook = item => item?.sensitivity_label?.status === 'not_present'
    && (!Object.hasOwn(item,'sensitivity') || item.sensitivity === 'normal');
  if(tool.name==='outlook_mail_read' && !permittedOutlook(payload)) return {data:{excluded:true},next:null};
  if(tool.name==='gmail_read') {
    const text=payload.messageText ?? (typeof payload.preview==='string'?payload.preview:'');
    if(typeof text!=='string' || typeof payload.messageId!=='string' || args.message_id && payload.messageId!==args.message_id)
      throw new ServiceError('connector_invalid_response',502);
    return {data:{id:payload.messageId,thread_id:payload.threadId,subject:payload.subject,from:payload.sender,to:payload.to,
      date:payload.messageTimestamp,text:text.slice(0,32000),truncated:text.length>32000},next:null};
  }
  if (tool.textDownload) {
    const content = payload.downloaded_file_content;
    // The server adapter has already downloaded and bounded this text. A document may
    // legitimately start with a URL; it is content, never a second download instruction.
    if (typeof content !== 'string' || content.length > 256_000) throw new ServiceError('connector_file_unavailable', 422);
    return { data: { text: content }, next: null };
  }
  if (!tool.collection) return { data: payload, next: null };
  let container = payload;
  if (tool.name === 'slack_search') container = payload.messages;
  if (!container || typeof container !== 'object') throw new ServiceError('connector_invalid_response', 502);
  let items = container[tool.collection];
  // Gmail expressly permits absent messages for an empty successful listing.
  if (items === undefined && tool.name === 'gmail_search' && container.resultSizeEstimate === 0) items = [];
  if(items===undefined && (tool.name==='google_calendar_list'&&payload.kind==='calendar#events'
    ||tool.name==='drive_search'&&payload.kind==='drive#fileList'))items=[];
  if (!Array.isArray(items) || items.length > 100) throw new ServiceError('connector_invalid_response', 502);
  if(tool.name==='slack_search' && args.start && args.end) {
    if(items.some(item=>!/^\d+\.\d+$/.test(item.ts??'')))throw new ServiceError('connector_invalid_response',502);
    items=items.filter(item=>Number(item.ts)*1000>=Date.parse(args.start)&&Number(item.ts)*1000<Date.parse(args.end));
  }
  if(tool.name==='gmail_search') items=items.map(item=>({id:item.messageId??item.id,thread_id:item.threadId,
    subject:item.subject,from:item.sender,to:item.to,date:item.messageTimestamp,
    preview:(typeof item.messageText==='string'?item.messageText:typeof item.preview==='string'?item.preview:'').slice(0,2048)}));
  if(['outlook_mail_list','outlook_calendar_list'].includes(tool.name)) items=items.filter(permittedOutlook);
  if(tool.filterUsers) {
    const query=(args.query??'').toLowerCase();
    items=items.filter(item=>!item.deleted&&!item.is_bot&&!item.is_app_user &&
      [item.name,item.real_name,item.profile?.display_name].some(s=>typeof s==='string'&&s.toLowerCase().includes(query)))
      .map(item=>({id:item.id,name:item.name,real_name:item.real_name,display_name:item.profile?.display_name}));
  }
  let next = container.next_page_token ?? container.nextPageToken ?? container.response_metadata?.next_cursor ?? payload.next_page_token ?? null;
  if (tool.name === 'slack_search') {
    const paging = container.paging ?? container.pagination;
    if (!paging || !Number.isInteger(paging.page) || !Number.isInteger(paging.pages) || paging.page < 1 || paging.pages < 0) throw new ServiceError('connector_invalid_response', 502);
    next = paging.page < paging.pages ? paging.page + 1 : null;
  }
  if (container.has_more === true && !next) throw new ServiceError('connector_invalid_response', 502);
  // Outlook's current tools expose an opaque next_page_token. Do not turn @odata.nextLink
  // into a caller-controlled URL or silently mark an unfinished legacy result complete.
  if ((container['@odata.nextLink'] || payload['@odata.nextLink']) && !next) throw new ServiceError('connector_pagination_unsupported', 502);
  if (next !== null && next !== '' && !(typeof next === 'string' && next.length <= 12000 || Number.isInteger(next) && next > 0)) throw new ServiceError('connector_invalid_response', 502);
  return { data: { items }, next: next || null };
}
export function mutationReceipt(tool, data, args = {}) {
  const result = normalizeResult(tool, data).data;
  if (tool.receipt === 'accepted') {
    if (result.status_code !== 202) throw new ServiceError('write_outcome_unknown',409);
    return { outcome: 'accepted' };
  }
  const id = result.id ?? result.messageId ?? result.message?.id ?? result.file?.id ?? result.response_data?.id ?? result.ts;
  if (typeof id !== 'string' || id.length < 1 || id.length > 512) throw new ServiceError('write_outcome_unknown', 409);
  if(tool.receipt==='event' && args.start) {
    const event=result.response_data??result;
    const instant=value=>{
      if(typeof value?.dateTime!=='string')return NaN;
      const explicit=/(?:Z|[+-]\d{2}:\d{2})$/.test(value.dateTime);
      if(!explicit&&!['UTC','GMT','ETC/UTC'].includes((value.timeZone??'').toUpperCase()))return NaN;
      return Date.parse(value.dateTime+(explicit?'':'Z'));
    };
    if(instant(event.start)!==Date.parse(args.start)||instant(event.end)!==Date.parse(args.end)
      ||(event.summary??event.subject)!==args.title)throw new ServiceError('write_outcome_unknown',409);
  }
  if (tool.receipt === 'slack' && typeof result.channel !== 'string') throw new ServiceError('write_outcome_unknown', 409);
  return { outcome: 'confirmed', id, ...(tool.receipt === 'slack' ? { channel: result.channel } : {}) };
}
