import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const source = await readFile(new URL('../dist/language.js', import.meta.url), 'utf8');

function visit({lang='zh-CN', languages=['en-US'], saved=null, denied=false, hash='', search=''}={}) {
  const data=new Map(saved ? [['phonebridge.language',saved]] : []);
  const listeners={};
  const location={href:`https://example.com/phonebridge/${lang==='en'?'en/':''}${search}${hash}`,hash,search,replace(value){this.redirect=value;}};
  const links=['zh','en'].map(language=>({dataset:{language},href:`https://example.com/phonebridge/${language==='en'?'en/':''}`,addEventListener(event,handler){this.click=handler;}}));
  const context={URL,location,navigator:{languages,language:languages[0]},localStorage:{getItem(key){if(denied) throw Error('denied');return data.get(key);},setItem(key,value){if(denied) throw Error('denied');data.set(key,value);}},document:{documentElement:{lang},addEventListener(event,handler){listeners[event]=handler;},querySelectorAll(){return links;}}};
  vm.runInNewContext(source,context);
  listeners.DOMContentLoaded();
  return {location,data,links};
}

test('fresh English preference selects the English page before rendering and retains URL context',()=>{
  const {location}=visit({hash:'#how',search:'?ref=share'});
  assert.equal(location.redirect,'https://example.com/phonebridge/en/?ref=share#how');
});
test('Chinese system variants keep the Chinese page',()=>{
  for(const language of ['zh','zh-CN','zh-TW','zh-HK']) assert.equal(visit({languages:[language]}).location.redirect,undefined);
});
test('first preferred language wins; unsupported languages use English',()=>{
  assert.equal(visit({languages:['fr-FR','zh-CN']}).location.redirect,'https://example.com/phonebridge/en/');
});
test('saved manual Chinese choice wins over browser English',()=>{
  assert.equal(visit({saved:'zh'}).location.redirect,undefined);
});
test('saved manual English choice wins over browser Chinese',()=>{
  assert.equal(visit({saved:'en',languages:['zh-CN']}).location.redirect,'https://example.com/phonebridge/en/');
});
test('direct English entry never auto redirects, even for a saved Chinese choice',()=>{
  assert.equal(visit({lang:'en',saved:'zh',languages:['zh-CN']}).location.redirect,undefined);
});
test('manual selection persists and retains the current section after anchor navigation',()=>{
  const {links,data,location}=visit({lang:'en'});
  location.hash='#how';
  links[0].click();
  assert.equal(data.get('phonebridge.language'),'zh');
  assert.equal(links[0].href,'https://example.com/phonebridge/?lang=zh#how');
});
test('blocked storage does not prevent language selection or native links',()=>{
  const {links,location}=visit({denied:true});
  assert.equal(location.redirect,'https://example.com/phonebridge/en/');
  assert.doesNotThrow(()=>links[0].click());
  assert.equal(links[0].href,'https://example.com/phonebridge/?lang=zh');
  // Follow the actual destination under the same blocked storage and English browser.
  assert.equal(visit({denied:true,search:new URL(links[0].href).search}).location.redirect,undefined);
});
test('invalid saved preferences fall back to browser language',()=>{
  assert.equal(visit({saved:'garbage',languages:['zh-CN']}).location.redirect,undefined);
});
