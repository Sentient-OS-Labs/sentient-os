// Remove only records owned by one marked, local acceptance database after an interrupted run.
// No production DB connection, account discovery, provider grant revocation or content reads.
import {PGlite} from '@electric-sql/pglite';
import {readFile,realpath} from 'node:fs/promises';
import path from 'node:path';
import {composioClient} from '../../src/connectors/composio.mjs';
const [rootArgument,keyFile]=process.argv.slice(2);
const root=await realpath(rootArgument);
if(!path.basename(root).startsWith('sentient-connectors-live-')||await readFile(root+'/.fixture','utf8')!=='1\n')throw new Error('Marked acceptance database required');
const provider=composioClient({apiKey:(await readFile(keyFile,'utf8')).trim()});
const db=new PGlite(root+'/database');
try {
  const rows=(await db.query(`select distinct attempt.upstream_id,attempt.auth_config,account.service,owner.composio_user
    from public.hosted_connector_attempts attempt join public.hosted_connector_accounts account on account.id=attempt.connection_id
    join public.hosted_connector_users owner on owner.principal_id=account.principal_id where attempt.upstream_id is not null
    union select account.upstream_id,account.auth_config,account.service,owner.composio_user
    from public.hosted_connector_accounts account join public.hosted_connector_users owner on owner.principal_id=account.principal_id
    where account.upstream_id is not null`)).rows;
  if(rows.length>60)throw new Error('Unexpected acceptance database size');
  for(const row of rows){
    try{await provider.account(row);}catch(error){if(!['connection_required','connector_upstream_not_found'].includes(error.code))throw error;}
    await provider.remove('connection',row.upstream_id,row.auth_config);
    await db.query(`update public.hosted_connector_attempts set upstream_id=null,status='cancelled' where upstream_id=$1`,[row.upstream_id]);
    await db.query(`update public.hosted_connector_accounts set upstream_id=null,status='disconnected',generation=generation+1 where upstream_id=$1`,[row.upstream_id]);
    await db.query(`delete from public.hosted_connector_cleanup where upstream_id=$1 and kind in ('account','connection')`,[row.upstream_id]);
  }
  console.log(JSON.stringify({removed_test_connections:rows.length,provider_grants_revoked:false}));
}finally{await db.close();}
