// Exercise the actual inline Web atlas receiver, without a browser, camera or packages.
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, '..', 'FL-Camera-Review.html'), 'utf8');
const start = html.indexOf('window.receiveThumbs=async('), end = html.indexOf('\nsync();send(', start);
assert.ok(start >= 0 && end > start, 'find the packaged receiver');
const paintStart=html.indexOf('let cachedRailAtlas=null;'), paintEnd=html.indexOf('function filterRail(',paintStart);
assert.ok(paintStart>=0&&paintEnd>paintStart,'find the packaged atlas painter');
const names = ['original', 'FL2', 'FL3', 'GR-Positive', 'Classic-Negative', 'Nostalgic-Negative', 'Classic-Chrome'];
const edge = 307, calls = [], timers = new Map();
let decode, timerID = 0;
const canvases = names.map((look) => ({ dataset:{ look }, width:96, height:96,
  getContext: () => ({ drawImage: (_image, ...args) => calls.push([look, ...args]) }) }));
const track={querySelectorAll:()=>canvases,setAttribute:()=>{}};
const env = vm.createContext({ window:{}, railVersion:1, lastRail:true, selector:{querySelector:()=>track},performance,
  Image:class { naturalHeight=edge; naturalWidth=edge*names.length; decode() { return decode(); } },
  setTimeout:(fn, ms) => { assert.equal(ms, 600); timers.set(++timerID, fn); return timerID; },
  clearTimeout:(id) => timers.delete(id) });
vm.runInContext(html.slice(paintStart,paintEnd)+html.slice(start,end),env);
const send = (looks=names) => env.window.receiveThumbs('test-atlas',looks);
(async () => {
  decode = () => Promise.resolve(); await send();
  assert.deepEqual(calls.splice(0), names.map((look, i) => [look, i*edge, 0, edge, edge, 0, 0, edge, edge]));
  assert.ok(canvases.every(c => c.width === edge && c.height === edge));
  console.log('PASS: all seven tiles use the right column and retain the requested backing-pixel detail');
  await send(names.slice(1));await send(names.map((name,index)=>index===0?names[1]:name));
  assert.equal(calls.length,0,'partial/malformed atlas must not overwrite a subset of the previous frame');
  env.lastRail = false; decode = () => { throw new Error('must not decode closed rail'); }; await send();
  env.lastRail = true; let release; decode = () => new Promise(ok => { release = ok; });
  const pending = send(); env.lastRail = false; env.railVersion++; env.lastRail = true; env.railVersion++; release(); await pending;
  assert.equal(calls.length, 0); console.log('PASS: closing and reopening the rail prevents stale draws');
  env.lastRail = true; decode = () => new Promise(() => {}); const stalled = send();
  assert.equal(timers.size, 1); [...timers.values()][0](); await stalled;
  assert.equal(timers.size, 0); assert.equal(calls.length, 0);
  decode = () => Promise.reject(new Error('decode failure')); await send(); assert.equal(calls.length, 0);
  decode = () => Promise.resolve(); await send(); assert.equal(calls.length, names.length);
  console.log('PASS: a hung or failed decode does not prevent the next atlas from being drawn');
})().catch(e => { console.error(e); process.exitCode = 1; });
