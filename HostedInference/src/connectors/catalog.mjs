// Sentient's reviewed connector surface. Provider schemas never grant additional authority.
// Each operation builds its upstream arguments; unknown fields and arbitrary account/URL inputs fail closed.
import { ServiceError } from '../errors.mjs';

const string = (maxLength = 2048, extra = {}) => ({ type: 'string', minLength: 1, maxLength, ...extra });
const driveID = string(200, { pattern: '^[A-Za-z0-9_-]+$' });
const gmailID = string(32, { pattern: '^[A-Fa-f0-9]{10,32}$' });
const outlookID = string(1024, { pattern: '^[A-Za-z0-9_+/=-]{8,1024}$' });
const date = string(40, { pattern: '^\\d{4}-\\d{2}-\\d{2}T.*(?:Z|[+-]\\d{2}:\\d{2})$' });
const email = string(254, { pattern: '^[^\\s<>@,;]+@[^\\s<>@,;]+\\.[^\\s<>@,;]+$' });
const text = string(32_000);
const emails = { type: 'array', items: email, maxItems: 20 };
const page = { cursor: string(36, { pattern: '^[0-9a-f-]{36}$' }) };
const object = (properties, required = Object.keys(properties)) => ({ type: 'object', properties, required, additionalProperties: false });
const definitions = {};
function add(service, name, upstream, description, properties, required, build, options = {}) {
  definitions[name] = { service, name, upstream, description, inputSchema: object(properties, required), build, write: false, ...options };
}
const windowFields = { start: date, end: date, query: string(1024), ...page };
function phrase(value) {
  if(/["\\(){}\x00-\x1f]/.test(value))throw new ServiceError('invalid_arguments');
  return `"${value}"`;
}
function window(a, days = 31) {
  for(const value of [a.start,a.end]) {
    const match=value.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$/);
    if(!match || +match[2]<1 || +match[2]>12 || +match[3]<1 || +match[3]>new Date(Date.UTC(+match[1],+match[2],0)).getUTCDate()
      || +match[4]>23 || +match[5]>59 || +match[6]>59)throw new ServiceError('invalid_window');
  }
  const lower = Date.parse(a.start), upper = Date.parse(a.end);
  if (!Number.isFinite(lower) || !Number.isFinite(upper) || upper <= lower || upper - lower > days * 86_400_000) {
    throw new ServiceError('invalid_window');
  }
  return { lower: new Date(lower).toISOString(), upper: new Date(upper).toISOString() };
}
add('gmail', 'gmail_search', 'GMAIL_FETCH_EMAILS',
  'Read a bounded Gmail window. query is literal text, not search operators; use sender, recipient and subject for those filters. Returns up to 50 messages per page. Continue with the returned cursor and identical filters.',
  {...windowFields,sender:email,recipient:email,subject:string(500)}, ['start', 'end'], a => {
    window(a);
    return { user_id: 'me', query: `after:${Math.floor(Date.parse(a.start)/1000)-1} before:${Math.ceil(Date.parse(a.end)/1000)}`
      +(a.query?` ${phrase(a.query)}`:'')+(a.sender?` from:${phrase(a.sender)}`:'')+(a.recipient?` to:${phrase(a.recipient)}`:'')+(a.subject?` subject:${phrase(a.subject)}`:''),
      max_results: 50, verbose: true, include_payload: false, include_spam_trash: false };
  }, { cursorField: 'page_token', collection: 'messages' });
add('gmail', 'gmail_read', 'GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID', 'Read up to 32,000 characters from one message in this Gmail account. Reports truncation. Attachments are unavailable.',
  { message_id: gmailID }, ['message_id'], a => ({ user_id: 'me', message_id: a.message_id, format: 'full' }));
add('gmail', 'gmail_send', 'GMAIL_SEND_EMAIL', 'Send a new plain-text email requested by the user. Never repeat an uncertain send.',
  { to: email, subject: string(998), body: text, cc: emails, bcc: emails }, ['to', 'subject', 'body'], a => ({
    user_id: 'me', recipient_email: a.to, subject: a.subject, body: a.body, is_html: false, include_signature: false,
    ...(a.cc ? { cc: a.cc } : {}), ...(a.bcc ? { bcc: a.bcc } : {}) }), { write: true, receipt: 'mail' });
add('gmail', 'gmail_reply', 'GMAIL_REPLY_TO_THREAD', 'Reply to a verified Gmail thread and explicit recipient. Never repeat an uncertain reply.',
  { thread_id: gmailID, to: email, body: text }, ['thread_id', 'to', 'body'], a => ({ user_id: 'me',
    thread_id: a.thread_id, recipient_email: a.to, message_body: a.body, is_html: false, include_signature: false }), { write: true, receipt: 'mail' });

add('google-calendar', 'google_calendar_list', 'GOOGLECALENDAR_EVENTS_LIST',
  'Read the connected account’s primary calendar, including expanded recurring events, in a bounded window.',
  windowFields, ['start', 'end'], a => { const w = window(a); return { calendarId: 'primary', timeMin: w.lower,
    timeMax: w.upper, maxResults: 50, singleEvents: true, showDeleted: false, orderBy: 'startTime', ...(a.query ? { query: a.query } : {}) };
  }, { cursorField: 'pageToken', collection: 'items' });
add('google-calendar', 'google_calendar_create', 'GOOGLECALENDAR_CREATE_EVENT',
  'Create one timed event in the primary calendar. Explicit attendees receive invitations; no recurring events or existing-event edits.',
  { title: string(500), start: date, end: date, description: text, location: string(500), attendees: emails },
  ['title', 'start', 'end'], a => { const w=window(a, 366); return { calendar_id: 'primary', summary: a.title,
    start_datetime: w.lower.replace('Z',''), end_datetime: w.upper.replace('Z',''), timezone: 'UTC', description: a.description ?? '', location: a.location ?? '',
    attendees: a.attendees ?? [], send_updates: a.attendees?.length ? 'all' : 'none', create_meeting_room: false,
    exclude_organizer: true, guestsCanModify: false, guestsCanInviteOthers: false }; }, { write: true, receipt: 'event' });

add('google-drive', 'drive_search', 'GOOGLEDRIVE_FIND_FILE',
  'List recently modified accessible Drive files. Returns metadata and descriptions; continue every page before calling a window complete.',
  windowFields, ['start', 'end'], a => { const w = window(a); const query = a.query?.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    return { q: `trashed = false and modifiedTime >= '${w.lower}' and modifiedTime < '${w.upper}'${query ? ` and fullText contains '${query}'` : ''}`,
      fields: 'kind,nextPageToken,incompleteSearch,files(id,name,mimeType,size,description,modifiedTime,webViewLink)',
      pageSize: 50, corpora: 'user', ...(query ? {} : { orderBy: 'modifiedTime desc' }) }; },
  { cursorField: 'pageToken', collection: 'files' });
add('google-drive', 'drive_metadata', 'GOOGLEDRIVE_GET_FILE_METADATA', 'Read metadata for an exact accessible Drive file.',
  { file_id: driveID }, ['file_id'], a => ({ fileId: a.file_id, fields: 'id,name,mimeType,size,description,modifiedTime,webViewLink' }));
add('google-drive', 'drive_read_text', 'GOOGLEDRIVE_DOWNLOAD_FILE',
  'Read up to 256 KB of UTF-8 Google Doc or text content through temporary Composio file staging. Binary files are unsupported; a rejected read is not an empty document.',
  { file_id: driveID }, ['file_id'], a => ({ fileId: a.file_id, mime_type: 'text/plain' }),
  { textDownload: true });
add('google-drive', 'drive_create_text', 'GOOGLEDRIVE_CREATE_FILE_FROM_TEXT',
  'Create a new plain-text file in My Drive. Does not edit existing files or share access.',
  { name: string(200,{pattern:'^[^/\\\\\\x00-\\x1f]+$'}), text }, ['name', 'text'], a => {
    if(['.','..'].includes(a.name))throw new ServiceError('invalid_arguments');
    return { file_name: a.name, text_content: a.text, mime_type: 'text/plain' };
  },
  { write: true, receipt: 'file' });

add('slack', 'slack_search', 'SLACK_SEARCH_MESSAGES', 'Search messages visible to the connected Slack user in a bounded window. query is literal text; channel and sender are optional exact filters.',
  {...windowFields,channel:string(100,{pattern:'^[CDG][A-Z0-9]+$'}),sender:string(100,{pattern:'^(?:me|[UW][A-Z0-9]+)$'})}, ['start', 'end'], a => { const w = window(a); return { query: `after:${new Date(Date.parse(w.lower)-86_400_000).toISOString().slice(0,10)} before:${new Date(Date.parse(w.upper)+86_400_000).toISOString().slice(0,10)}`
      +(a.query?` ${phrase(a.query)}`:'')+(a.channel?` in:${a.channel}`:'')+(a.sender?` from:${a.sender}`:''),
    count: 50, sort: 'timestamp', sort_dir: 'asc', highlight: false, auto_paginate: false }; },
  { cursorField: 'page', collection: 'matches' });
add('slack', 'slack_thread', 'SLACK_FETCH_MESSAGE_THREAD_FROM_A_CONVERSATION', 'Read a Slack thread by exact channel and parent timestamp.',
  { channel: string(100, { pattern: '^[CDG][A-Z0-9]+$' }), timestamp: string(40, { pattern: '^\\d+\\.\\d+$' }), ...page },
  ['channel', 'timestamp'], a => ({ channel: a.channel, ts: a.timestamp, limit: 50, include_all_metadata: false }),
  { cursorField: 'cursor', collection: 'messages' });
add('slack', 'slack_users', 'SLACK_LIST_ALL_USERS', 'Find workspace users by name, one bounded directory page at a time. Continue cursors even if a filtered page has no matches. Do not guess an ambiguous recipient.',
  { query: string(120), ...page }, ['query'], () => ({ limit: 50, include_locale: false }),
  { cursorField: 'cursor', collection: 'members', filterUsers: true });
add('slack', 'slack_conversations', 'SLACK_LIST_CONVERSATIONS', 'List the connected user’s accessible conversations to resolve an exact channel or existing direct-message destination.',
  page, [], () => ({ limit: 50, types: 'public_channel,private_channel,im,mpim', exclude_archived: true }),
  { cursorField: 'cursor', collection: 'channels' });
add('slack', 'slack_send', 'SLACK_CHAT_POST_MESSAGE', 'Send a message to an exact Slack channel or conversation, optionally as a thread reply. No broadcasts, link unfurling or edits.',
  { channel: string(100, { pattern: '^[CDG][A-Z0-9]+$' }), text, thread_ts: string(40, { pattern: '^\\d+\\.\\d+$' }) },
  ['channel', 'text'], a => {
    if(/<!(?:channel|here|everyone)(?:\|[^>]*)?>/i.test(a.text))throw new ServiceError('invalid_arguments');
    return { channel: a.channel, text: a.text, mrkdwn: false, parse: 'none', link_names: false,
      unfurl_links: false, unfurl_media: false, reply_broadcast: false, ...(a.thread_ts ? { thread_ts: a.thread_ts } : {}) };
  }, { write: true, receipt: 'slack' });

add('outlook-mail', 'outlook_mail_list', 'OUTLOOK_LIST_MESSAGES', 'Read a bounded window from the connected primary Outlook mailbox. Shared/delegated mailboxes are excluded.',
  { start: date, end: date, ...page }, ['start', 'end'], a => { const w = window(a); return { user_id: 'me', folder: 'allfolders',
    received_date_time_ge: w.lower, received_date_time_lt: w.upper, top: 50, orderby: ['receivedDateTime asc'],
    response_detail: 'minimal', include_sensitivity_label: true }; }, { cursorField: 'page_token', collection: 'value' });
add('outlook-mail', 'outlook_mail_read', 'OUTLOOK_GET_MESSAGE', 'Read one exact message in the connected primary Outlook mailbox.',
  { message_id: outlookID }, ['message_id'], a => ({ user_id: 'me', message_id: a.message_id, include_sensitivity_label: true }));
add('outlook-mail', 'outlook_mail_send', 'OUTLOOK_SEND_EMAIL', 'Send one plain-text email from the connected primary Outlook mailbox. Successful provider acceptance does not prove delivery.',
  { to: email, subject: string(998), body: text, cc: emails, bcc: emails }, ['to', 'subject', 'body'], a => ({
    user_id: 'me', to: a.to, subject: a.subject, body: a.body, is_html: false, save_to_sent_items: true,
    ...(a.cc ? { cc_emails: a.cc } : {}), ...(a.bcc ? { bcc_emails: a.bcc } : {}) }), { write: true, receipt: 'accepted' });
add('outlook-mail', 'outlook_mail_reply', 'OUTLOOK_REPLY_EMAIL', 'Reply to one verified message in the connected primary Outlook mailbox. Read the message and verify its sender before replying; no attachments or extra recipients.',
  { message_id: outlookID, body: text }, ['message_id','body'], a => ({ user_id: 'me', message_id: a.message_id, comment: a.body, is_html: false }),
  { write: true, receipt: 'accepted' });
add('outlook-calendar', 'outlook_calendar_list', 'OUTLOOK_GET_CALENDAR_VIEW', 'Read expanded events in the connected primary Outlook calendar for a bounded window.',
  { start: date, end: date, ...page }, ['start', 'end'], a => { const w = window(a); return { user_id: 'me',
    start_datetime: w.lower, end_datetime: w.upper, top: 50, timezone: 'UTC', include_sensitivity_label: true }; },
  { cursorField: 'page_token', collection: 'value' });
add('outlook-calendar', 'outlook_calendar_create', 'OUTLOOK_CALENDAR_CREATE_EVENT',
  'Create a timed event in the connected primary Outlook calendar. Explicit attendees receive invitations. No recurring events or existing-event edits.',
  { title: string(500), start: date, end: date, description: text, location: string(500), attendees: emails },
  ['title', 'start', 'end'], a => { const w=window(a, 366); return { user_id: 'me', subject: a.title, start_datetime: w.lower.replace('Z',''),
    end_datetime: w.upper.replace('Z',''), time_zone: 'UTC', body: a.description ?? '', is_html: false, location: a.location ?? '',
    is_online_meeting: false, attendees_info: (a.attendees ?? []).map(address => ({ email: address, type: 'required' })) }; },
  { write: true, receipt: 'event' });

export const catalog = Object.freeze(definitions);
export const services = Object.freeze({ gmail: 'gmail', 'google-calendar': 'googlecalendar', 'google-drive': 'googledrive',
  slack: 'slack', 'outlook-mail': 'outlook', 'outlook-calendar': 'outlook' });
export function toolsFor(service, mode = 'read') {
  return Object.values(catalog).filter(t => t.service === service && (mode === 'action' || !t.write));
}
export function validate(schema, value) {
  if (schema.type === 'object') {
    if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(k => !Object.hasOwn(schema.properties, k))
      || schema.required.some(k => !Object.hasOwn(value, k))) throw new ServiceError('invalid_arguments');
    for (const [key, child] of Object.entries(value)) validate(schema.properties[key], child);
  } else if (schema.type === 'string') {
    if (typeof value !== 'string' || value.length < schema.minLength || value.length > schema.maxLength || /\x00/.test(value)
      || schema.pattern && !new RegExp(schema.pattern).test(value)) throw new ServiceError('invalid_arguments');
  } else if (schema.type === 'array') {
    if (!Array.isArray(value) || value.length > schema.maxItems) throw new ServiceError('invalid_arguments');
    for (const item of value) validate(schema.items, item);
  } else throw new ServiceError('invalid_arguments');
}
export function prepareTool(service, mode, name, args) {
  const tool = catalog[name];
  if (!tool || tool.service !== service || tool.write && mode !== 'action') throw new ServiceError('tool_not_allowed', 403);
  validate(tool.inputSchema, args);
  return { tool, arguments: tool.build(args) };
}
