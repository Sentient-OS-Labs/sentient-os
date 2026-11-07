import test from 'node:test';
import assert from 'node:assert/strict';
import {youtubeURL,boundedTranscript} from '../src/youtube-transcript.mjs';
test('video lookup accepts known formats, never arbitrary hosts, credentials or IDs',()=>{
  const expected='https://www.youtube.com/watch?v=jNQXAC9IVRw';
  for(const value of [expected,'http://m.youtube.com/watch?v=jNQXAC9IVRw&list=abc','https://youtu.be/jNQXAC9IVRw',
    'https://www.youtube.com/shorts/jNQXAC9IVRw','https://youtube.com/live/jNQXAC9IVRw'])assert.equal(youtubeURL(value),expected);
  for(const value of ['https://youtube.com.evil.com/watch?v=jNQXAC9IVRw','https://localhost/watch?v=jNQXAC9IVRw',
    'https://a:b@youtube.com/watch?v=jNQXAC9IVRw','https://youtube.com:444/watch?v=jNQXAC9IVRw','file:///etc/passwd',
    'https://youtube.com/watch?v=../secret','https://youtube.com/playlist?list=abc',null])assert.equal(youtubeURL(value),null);
});
test('large Unicode transcripts remain bounded and retain ending material',()=>{
  const source='start '+('あ😀 c '.repeat(30000))+' end';
  const result=boundedTranscript(source);assert.equal(result.truncated,true);
  assert.ok(new TextEncoder().encode(result.text).length<=26000);
  assert.ok(!result.text.includes('\uFFFD'));assert.ok(result.text.startsWith('start'));assert.ok(result.text.endsWith('end'));
});
