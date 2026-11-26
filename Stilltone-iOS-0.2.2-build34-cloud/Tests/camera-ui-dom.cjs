// Offline host for the packaged page. Only DOM operations used by the camera UI are
// modeled. No capture/format/Live policy lives here; all handlers run from the HTML.
const vm = require('node:vm');
const assert = require('node:assert/strict');
const voidTags = new Set(['meta','input','img','br','hr','link']);
const dataKey = name => name.slice(5).replace(/-([a-z])/g, (_,c)=>c.toUpperCase());

class Element {
    constructor(tag) {
        this.tag=tag; this.childNodes=[]; this.parentNode=null; this.attributes={}; this.dataset={};
        this.className=''; this._value=''; this.disabled=false; this.hidden=false; this.listeners=[];
        this.style={setProperty(k,v){this[k]=String(v)}};
        this.classList={contains:s=>this.className.split(/\s+/).includes(s),
            toggle:(s,on)=>{const set=new Set(this.className.split(/\s+/).filter(Boolean)); on??=!set.has(s); if(on)set.add(s);else set.delete(s);this.className=[...set].join(' ');return on},
            add:(...ss)=>ss.forEach(s=>this.classList.toggle(s,true)), remove:(...ss)=>ss.forEach(s=>this.classList.toggle(s,false))};
    }
    get children(){return this.childNodes.filter(n=>n.tag!=='#text')}
    get firstChild(){return this.childNodes[0]} get lastChild(){return this.childNodes.at(-1)}
    get firstElementChild(){return this.children[0]} get parentElement(){return this.parentNode}
    get options(){return this.tag==='select'?this.children:undefined}
    get selectedIndex(){return this.options.findIndex(o=>o.value===this.value)}
    get text(){return this.textContent}
    get value(){if(this.tag==='select')return this._value||this.options[0]?.value||''; if(this.tag==='option')return this._value||this.text;return this._value}
    set value(v){this._value=String(v)}
    set textContent(s){this.replaceChildren(String(s))}
    get textContent(){return this.tag==='#text'?this.data:this.childNodes.map(n=>n.textContent).join('')}
    set innerHTML(html){this.replaceChildren();parse(html,this);this._html=html}
    get innerHTML(){return this._html??this.textContent}
    setAttribute(k,v){v=String(v);this.attributes[k]=v;if(k==='class')this.className=v;else if(k.startsWith('data-'))this.dataset[dataKey(k)]=v;else if(k==='hidden'||k==='disabled')this[k]=true;else if(['id','title','value','min','max','type'].includes(k))this[k]=v}
    getAttribute(k){if(k.startsWith('data-'))return this.dataset[dataKey(k)]??null;if(['id','class','title','type'].includes(k))return this[k==='class'?'className':k]??null;return this.attributes[k]??null}
    hasAttribute(k){return this.getAttribute(k)!==null}
    removeAttribute(k){delete this.attributes[k];if(k==='id')delete this.id}
    remove(){if(this.parentNode){const a=this.parentNode.childNodes;a.splice(a.indexOf(this),1);this.parentNode=null}}
    insertBefore(node,ref){if(typeof node!=='object'){const t=new Element('#text');t.data=String(node);node=t} node.remove();node.parentNode=this;const i=ref?this.childNodes.indexOf(ref):-1;this.childNodes.splice(i<0?this.childNodes.length:i,0,node);return node}
    append(...nodes){for(const n of nodes)this.insertBefore(n,null)}
    prepend(...nodes){const ref=this.firstChild;for(const n of nodes)this.insertBefore(n,ref)}
    before(n){this.parentNode.insertBefore(n,this)} after(n){const p=this.parentNode;p.insertBefore(n,p.childNodes[p.childNodes.indexOf(this)+1])}
    replaceChildren(...nodes){for(const n of this.childNodes)n.parentNode=null;this.childNodes=[];this.append(...nodes)}
    contains(node){for(let n=node;n;n=n.parentNode)if(n===this)return true;return false}
    matches(s){const m=/^([\w-]+)?(?:#([\w-]+))?(?:\.([\w-]+))?(?:\[([\w-]+)(?:="?([^"\]]+)"?)?\])?$/.exec(s);if(!m)throw Error('Unsupported test selector: '+s);
        return (!m[1]||this.tag===m[1])&&(!m[2]||this.id===m[2])&&(!m[3]||this.classList.contains(m[3]))&&(!m[4]||(m[5]===undefined?this.hasAttribute(m[4]):this.getAttribute(m[4])===m[5]))}
    closest(s){for(let n=this;n;n=n.parentNode)if(s.split(',').some(part=>n.matches(part.trim())))return n;return null}
    querySelectorAll(s){const terms=s.match(/(?:\[[^\]]*\]|[^\s])+/g);const matches=n=>{let i=terms.length-1;if(!n.matches(terms[i]))return false;while(i>0){--i;do{n=n.parentNode}while(n&&n!==this&&!n.matches(terms[i]));if(!n||n===this)return false}return true};
        const out=[];function visit(n){for(const child of n.children){if(matches(child))out.push(child);visit(child)}}visit(this);return out}
    querySelector(s){return this.querySelectorAll(s)[0]??null}
    cloneNode(){const n=new Element(this.tag);for(const [k,v] of Object.entries(this.attributes))n.setAttribute(k,v);n.value=this.value;return n}
    get clientWidth(){return this.classList.contains('rail-window')||this.classList.contains('rail-track')?320:100}
    get offsetHeight(){return 100}
    getBoundingClientRect(){return {x:0,y:0,left:0,top:0,width:this.clientWidth,height:100}}
    getAnimations(){return []} setPointerCapture(id){this.captured=id}
    addEventListener(name,fn,opts){this.listeners.push({name,fn,capture:opts===true||opts?.capture===true})}
    dispatch(name,props={}){const path=[];for(let n=this;n;n=n.parentNode)path.push(n);
        const e={type:name,target:this,button:0,clientX:30,clientY:30,isPrimary:true,pointerId:1,pointerType:'touch',
            preventDefault(){this.defaultPrevented=true},stopImmediatePropagation(){this.stopped=true},...props};
        const fire=(n,capture)=>{e.currentTarget=n;for(const l of n.listeners){if(e.stopped)break;if(l.name===name&&l.capture===capture)l.fn(e)}};
        for(const n of [...path].reverse()){fire(n,true);if(e.stopped)return e}
        for(const n of path){if(n['on'+name])n['on'+name](e);if(e.stopped)break;fire(n,false);if(e.stopped)break}return e}
    click(){if(!this.disabled)this.dispatch('click')}
    getContext(){return this.context??={fillRect(){},drawImage(){},createLinearGradient:()=>({addColorStop(){}}),getImageData:()=>({data:new Uint8ClampedArray(4)}),putImageData(){}}}
    captureStream(){return {}} showModal(){this.open=true} close(){this.open=false}
}
function parse(html,root){const stack=[root];for(const [token] of html.matchAll(/<[^>]+>|[^<]+/g)){
    if(token.startsWith('</')){stack.pop();continue}if(!token.startsWith('<')){stack.at(-1).append(token);continue}
    const [,tag,attrs]=/^<([\w-]+)([\s\S]*?)\/?>$/.exec(token);const n=new Element(tag);stack.at(-1).append(n);
    for(const [,key,value] of attrs.matchAll(/([^\s=]+)(?:="([^"]*)")?/g))n.setAttribute(key,value??'');
    if(!voidTags.has(tag)&&!token.endsWith('/>'))stack.push(n)
}}
function boot(html,{native=true,landscape=false,touch=true}={}){
    const doc=new Element('document');doc.body=new Element('body');doc.head=new Element('head');doc.append(doc.head,doc.body);
    doc.createElement=tag=>new Element(tag);doc.getElementById=id=>doc.querySelector('#'+id);
    const markup=html.slice(html.indexOf('<main'),html.indexOf('<script id="assets"'));assert.ok(markup.startsWith('<main'),'camera markup missing');parse(markup,doc.body);
    const start=html.indexOf('</script><script>'),end=html.lastIndexOf('</script>');assert.ok(start>=0&&end>start,'inline camera script missing');const source=html.slice(start+'</script><script>'.length,end);
    const assets=doc.createElement('script');assets.id='assets';assets.textContent=html.slice(html.indexOf('>',html.indexOf('<script id="assets"'))+1,start);doc.body.append(assets);
    const messages=[],intervals=new Map(),timeouts=new Map();let id=0,clock=1000;
    const host={document:doc,atob:s=>Buffer.from(s,'base64').toString('latin1'),navigator:{userAgent:touch?'iPhone':'Desktop',maxTouchPoints:touch?1:0},
        screen:{orientation:{type:landscape?'landscape-primary':'portrait-primary',addEventListener(){}}},innerWidth:landscape?800:390,innerHeight:landscape?390:800,
        addEventListener(){},performance:{now:()=>clock},matchMedia:q=>({matches:q.includes('prefers-reduced-motion')}),
        getComputedStyle:e=>e.style,DOMMatrixReadOnly:class{constructor(transform){this.m41=Number(/translate(?:3d|X)\(([-\d.]+)px/.exec(transform)?.[1]??0)}},
        requestAnimationFrame:()=>++id,cancelAnimationFrame(){},ResizeObserver:class{observe(){}},MutationObserver:class{observe(){}},MediaRecorder:class{},
        setInterval:(cb,ms)=>(intervals.set(++id,{cb,ms}),id),clearInterval:i=>intervals.delete(i),setTimeout:(cb,ms)=>(timeouts.set(++id,{cb,ms}),id),clearTimeout:i=>timeouts.delete(i)};
    if(native)host.webkit={messageHandlers:{camera:{postMessage:m=>messages.push(JSON.parse(JSON.stringify(m)))}}};
    host.window=host;const context=vm.createContext(host);
    vm.runInContext(source,context,{filename:'FL-Camera-Review.html.inline.js'});
    const run=code=>vm.runInContext(code,context);
    return {doc,host,messages,run,report:s=>host.receiveCamera(s),tick(ms,n=1){while(n--){clock+=ms;for(const task of [...intervals.values()])if(task.ms===ms)task.cb()}},advance:ms=>{clock+=ms},
        fireTimeout(ms){for(const [id,task] of [...timeouts])if(task.ms===ms){timeouts.delete(id);task.cb()}},
        capture(){const before=messages.length;run('takeShot()');return messages.slice(before).find(m=>m.type==='capture')},
        button(name){return run(name)},open(kind){run('chooseBottom('+JSON.stringify(kind)+',true)')},close(){run('leavePicker()')},
        row(label){return run('selector').querySelector('[aria-label="'+label+'"]')?.querySelectorAll('button')??[]},
        shutter(){doc.getElementById('shutter').click()}
    }
}
module.exports={boot};
