"""Loopback-only agent API. The existing workbench remains the sole scheduler."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import math
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
from urllib.parse import parse_qs, urlsplit
import uuid

from PIL import Image, UnidentifiedImageError

VERSION = '1.0'
ID = re.compile(r'^(?:job|img)_[0-9a-f]{32}$')
TERMINAL = {'done', 'error', 'cancelled'}
MAX_BODY = 32 * 1024 * 1024


class ApiError(Exception):
    def __init__(self, status, code, message, field=None, retryable=False):
        super().__init__(message)
        self.status, self.code, self.field, self.retryable = status, code, field, retryable


def atomic_json(path, data):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        temporary.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False), encoding='utf-8')
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path, default=None):
    try: return json.loads(Path(path).read_text(encoding='utf-8-sig'))
    except (OSError, ValueError): return default


def integer(value, field, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ApiError(400, 'invalid_parameter', f'{field} must be an integer in [{minimum}, {maximum}]', field)
    return value


def string(value, field, maximum=100000, empty=True):
    if not isinstance(value, str) or len(value) > maximum or (not empty and not value.strip()):
        raise ApiError(400, 'invalid_parameter', f'Invalid {field}', field)
    return value.strip()


class Core:
    def __init__(self, app):
        self.app = Path(app).resolve(); self.root = self.app / 'agent_api'
        for directory in ('jobs', 'inbox', 'uploads'): (self.root / directory).mkdir(parents=True, exist_ok=True)
        token_file = self.root / 'token.txt'
        try:
            with token_file.open('x', encoding='ascii') as stream: stream.write(secrets.token_urlsafe(32))
        except FileExistsError: pass
        self.token = token_file.read_text(encoding='ascii').strip()
        self.lock = threading.RLock()
        self.db = sqlite3.connect(self.root / 'registry.sqlite3', check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, request_id TEXT UNIQUE NOT NULL,
                fingerprint TEXT NOT NULL, payload TEXT NOT NULL, config TEXT NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY, path TEXT NOT NULL, metadata TEXT NOT NULL, job_id TEXT);
        ''')
        self.db.commit()
        # Recover requests committed just before the service lost its inbox write.
        for row in self.db.execute('SELECT id, config, payload, created FROM jobs').fetchall():
            jid=row['id']
            if not (self.root/'jobs'/jid/'bridge.json').exists() and not (self.app/'jobs'/jid/'request.json').exists():
                atomic_json(self.root/'inbox'/(jid+'.json'), dict(job_id=jid, config=json.loads(row['config']),source=json.loads(row['payload']).get('source','agent'),created=row['created']))

    def close(self):
        with self.lock: self.db.close()

    def health(self):
        heartbeat = read_json(self.root / 'heartbeat.json', {})
        online = bool(heartbeat.get('online') and time.time()-heartbeat.get('time', 0) < 6)
        return dict(version=VERSION, workbench_online=online, queue_paused=bool(heartbeat.get('paused')), session=heartbeat.get('session'))

    def models(self):
        profiles = read_json(self.app / 'models.json', [])
        return [dict(id=p['id'], name=p['name'], modes=['text','edit'] if p['id'] in ('qwen21','qwen21_turbo') else ['text'],
                     defaults=dict(width=1024,height=1024,steps=p.get('text_steps',25),edit_steps=p.get('edit_steps',40),cfg=p.get('text_cfg',1),seed=-1),
                     constraints=dict(size_min=256,size_max=2048,size_multiple=32,steps_fixed=8 if p.get('fixed_sigmas') else None)) for p in profiles]

    def catalog(self, kind, query=''):
        data = read_json(self.root / 'catalog.json', {})
        rows=data.get(kind, [])
        query=query.casefold()
        return [row for row in rows if not query or query in ' '.join(str(v) for v in row.values()).casefold()]

    def normalize(self, payload):
        allowed={'request_id','source','model','mode','prompt','prompts','negative_prompt','preset_ids','character_ids',
                 'random_categories','image_ids','count','width','height','steps','seed','cfg','resolution','ref_mode','ref_preset','ref_element','output'}
        unknown=set(payload)-allowed
        if unknown: raise ApiError(400,'unknown_parameter','Unknown parameter: '+sorted(unknown)[0],sorted(unknown)[0])
        profiles=read_json(self.app/'models.json',[])
        model=next((p for p in profiles if p['id']==payload.get('model')),None)
        if model is None: raise ApiError(400,'invalid_model','Choose a model ID from /v1/models','model')
        mode=payload.get('mode','text')
        if mode not in ('text','edit'): raise ApiError(400,'invalid_mode','mode must be text or edit','mode')
        if mode=='edit' and model['id'] not in ('qwen21','qwen21_turbo'):
            raise ApiError(400,'unsupported_mode','This model does not support image input','mode')
        catalog=read_json(self.root/'catalog.json',{})
        fragments=[]
        output_characters=[]
        for key,kind in [('preset_ids','presets'),('character_ids','characters')]:
            ids=payload.get(key,[])
            if not isinstance(ids,list) or len(ids)>256 or any(not isinstance(v,str) for v in ids):
                raise ApiError(400,'invalid_parameter',key+' must be an array of IDs',key)
            lookup={p['id']:p for p in catalog.get(kind,[]) if not p.get('random')}
            for value in dict.fromkeys(ids):
                if value not in lookup: raise ApiError(400,'unknown_id','Unknown '+key+': '+value,key)
                item=lookup[value]
                fragments.append(item['text'])
                if kind=='characters' or item.get('category')=='character':
                    output_characters.append(dict(name=item['name'].split(' · ',1)[-1],text=item['text']))
        random_categories=payload.get('random_categories',[])
        if not isinstance(random_categories,list) or len(random_categories)>32 or any(not isinstance(v,str) for v in random_categories):
            raise ApiError(400,'invalid_parameter','random_categories must be an array','random_categories')
        groups=[]
        for category in dict.fromkeys(random_categories):
            choices=list(dict.fromkeys(p['text'] for p in catalog.get('presets',[]) if p.get('category')==category and not p.get('random')))
            if not choices: raise ApiError(400,'unknown_category','Unknown random category','random_categories')
            groups.append(dict(key=category,choices=choices))
            if category=='character':
                output_characters.extend(dict(name=p['name'].split(' · ',1)[-1],text=p['text']) for p in catalog.get('presets',[]) if p.get('category')==category and not p.get('random'))
        prompts=payload.get('prompts',[payload.get('prompt','')])
        if not isinstance(prompts,list) or not 1<=len(prompts)<=10000: raise ApiError(400,'invalid_parameter','prompts must be a nonempty array','prompts')
        prompts=[', '.join(v for v in [string(text,'prompt'),*fragments] if v) for text in prompts]
        if any(not p for p in prompts) and not groups: raise ApiError(400,'empty_prompt','A prompt or selected preset is required','prompt')
        if mode=='edit' and len(prompts)!=1: raise ApiError(400,'invalid_parameter','Image editing accepts one instruction for all images','prompts')
        width=integer(payload.get('width',1024),'width',256,2048);height=integer(payload.get('height',1024),'height',256,2048)
        if width%32 or height%32: raise ApiError(400,'invalid_parameter','Width and height must be multiples of 32','width')
        steps=integer(payload.get('steps',model.get('edit_steps',40) if mode=='edit' else model.get('text_steps',25)),'steps',1,100)
        if model.get('fixed_sigmas') and steps!=8: raise ApiError(400,'invalid_parameter','Turbo uses exactly 8 steps','steps')
        cfg=payload.get('cfg',5 if mode=='edit' else model.get('text_cfg',1))
        if type(cfg) not in (int,float) or not math.isfinite(cfg) or not 1<=cfg<=10: raise ApiError(400,'invalid_parameter','cfg must be between 1 and 10','cfg')
        seed=integer(payload.get('seed',-1),'seed',-1,2**63-1);count=integer(payload.get('count',1),'count',1,2147483647)
        resolution=integer(payload.get('resolution',1024),'resolution',512,1536)
        if resolution not in (512,1024,1536): raise ApiError(400,'invalid_parameter','resolution must be 512, 1024 or 1536','resolution')
        image_ids=payload.get('image_ids',[])
        if not isinstance(image_ids,list) or len(image_ids)>256: raise ApiError(400,'invalid_parameter','image_ids must be an array','image_ids')
        images=[str(self.asset(aid)[0]) for aid in image_ids]
        if mode=='edit' and not images: raise ApiError(400,'missing_image','Upload or reference an image_id','image_ids')
        if mode=='text' and images: raise ApiError(400,'invalid_parameter','Image input requires mode=edit','image_ids')
        ref_mode=payload.get('ref_mode','structure')
        ref_preset=payload.get('ref_preset','normal' if ref_mode=='structure' else 'balanced')
        if ref_mode not in ('structure','feature') or ref_preset not in ({'structure':['subtle','normal','redraw'],'feature':['free','balanced','close']}[ref_mode]):
            raise ApiError(400,'invalid_parameter','Invalid reference mode or preset','ref_preset')
        element=payload.get('ref_element','character')
        if element not in ('character','pose','style','all'): raise ApiError(400,'invalid_parameter','Invalid reference element','ref_element')
        output=string(payload.get('output',catalog.get('output','')),'output',32768,False)
        if not Path(output).is_absolute(): raise ApiError(400,'invalid_parameter','Output must be an absolute folder path','output')
        return dict(model=model['id'],mode=mode,prompt=prompts[0],prompts=prompts,negative_prompt=string(payload.get('negative_prompt',''),'negative_prompt'),
                    images=images,image=images[0] if images else '',count=count,reference_count=count,width=width,height=height,resolution=resolution,
                    steps=steps,seed=seed,cfg=float(cfg),ref_mode=ref_mode,ref_preset=ref_preset,ref_element=element,random_presets=groups,output_characters=output_characters,output=output)

    def record(self, jid):
        if not isinstance(jid,str) or not ID.fullmatch(jid) or not jid.startswith('job_'): raise ApiError(404,'job_not_found','Unknown job ID')
        with self.lock: row=self.db.execute('SELECT * FROM jobs WHERE id=?',(jid,)).fetchone()
        if row is None: raise ApiError(404,'job_not_found','Unknown job ID')
        result=dict(row)
        result['payload']=json.loads(result['payload']);result['config']=json.loads(result['config'])
        return result

    def submit(self, payload):
        if not isinstance(payload,dict): raise ApiError(400,'invalid_json','Expected a JSON object')
        rid=string(payload.get('request_id'),'request_id',128,False)
        string(payload.get('source','agent'),'source',64,False)
        try: fingerprint=hashlib.sha256(json.dumps(payload,sort_keys=True,allow_nan=False).encode()).hexdigest()
        except (ValueError,TypeError): raise ApiError(400,'invalid_json','JSON must contain finite values')
        with self.lock:
            old=self.db.execute('SELECT id,fingerprint FROM jobs WHERE request_id=?',(rid,)).fetchone()
            if old:
                if old['fingerprint']!=fingerprint: raise ApiError(409,'request_id_conflict','request_id was used with different content','request_id')
                return self.job(old['id'])
            if not self.health()['workbench_online']: raise ApiError(503,'workbench_offline','Start the workbench first',retryable=True)
            config=self.normalize(payload)
            jid='job_'+uuid.uuid4().hex
            self.db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?)',(jid,rid,fingerprint,json.dumps(payload,ensure_ascii=False),json.dumps(config,ensure_ascii=False),time.time()))
            self.db.commit()
            atomic_json(self.root/'inbox'/(jid+'.json'),dict(job_id=jid,source=payload.get('source','agent'),config=config))
        return self.job(jid)

    def job(self, jid):
        row=self.record(jid); bridge=read_json(self.root/'jobs'/jid/'bridge.json',{})
        status=read_json(self.app/'jobs'/jid/'status.json',{})
        state=status.get('state',bridge.get('state','queued'))
        if state=='waiting': state='queued'
        if state=='stopping': state='running'
        health=self.health(); blocked=None
        if state not in TERMINAL:
            if not health['workbench_online']: blocked='workbench_offline'
            elif bridge.get('session') and bridge['session']!=health['session']: blocked='workbench_restarted'
            elif state=='queued' and health['queue_paused']: blocked='queue_paused'
        results=read_json(self.app/'jobs'/jid/'results.json',status.get('outputs',[]))
        if not isinstance(results,list): results=[]
        assets=[]
        for item in results:
            if not isinstance(item,dict) or not item.get('output'): continue
            path=Path(item['output'])
            if not path.is_file(): continue
            metadata={k:v for k,v in item.items() if k!='output'}
            metadata.setdefault('model',row['config']['model'])
            try: assets.append(self.register_asset(path,metadata,jid))
            except (OSError,ValueError,UnidentifiedImageError): continue
        # Previously registered partial results remain available even if a later progress record omits them.
        with self.lock: saved=self.db.execute('SELECT id,metadata FROM assets WHERE job_id=? ORDER BY rowid',(jid,)).fetchall()
        known={a['image_id'] for a in assets}
        for asset in saved:
            if asset['id'] not in known: assets.append(dict({k:v for k,v in json.loads(asset['metadata']).items() if not k.startswith('_')},image_id=asset['id'],url='/v1/images/'+asset['id']))
        error=None
        if state=='error': error=dict(code=bridge.get('code','generation_failed'),message=status.get('message',bridge.get('message','Task failed')),retryable=True)
        return dict(job_id=jid,request_id=row['request_id'],source=row['payload'].get('source','agent'),state=state,
                    blocked_reason=blocked,progress=status.get('progress',0),completed=max(status.get('completed',0),len(assets)),
                    total=row['config']['count']*(len(row['config']['images']) if row['config']['mode']=='edit' else len(row['config']['prompts'])),
                    queue_position=bridge.get('queue_position'),message=status.get('message',bridge.get('message','Waiting for workbench queue')),
                    results=assets,error=error,created=row['created'])

    def cancel(self, jid):
        job=self.job(jid)
        if job['state'] not in TERMINAL:
            path=self.root/'jobs'/jid/'cancel';path.parent.mkdir(parents=True,exist_ok=True);path.touch()
        return self.job(jid)

    def register_asset(self,path,metadata=None,jid=None):
        path=Path(path).resolve()
        stat=path.stat();signature=f'{stat.st_mtime_ns}:{stat.st_size}'
        with self.lock:
            old=self.db.execute('SELECT id,metadata FROM assets WHERE path=? AND job_id IS ? ORDER BY rowid DESC LIMIT 1',(str(path),jid)).fetchone()
            if old:
                previous=json.loads(old['metadata'])
                if previous.get('_signature')==signature:
                    return dict({k:v for k,v in previous.items() if not k.startswith('_')},image_id=old['id'],url='/v1/images/'+old['id'])
            with Image.open(path) as image: width,height=image.size;fmt=image.format
            digest=hashlib.sha256(path.read_bytes()).hexdigest()
            if metadata and metadata.get('sha256') and metadata['sha256']!=digest: raise ValueError('Result image was replaced')
            metadata=dict(metadata or {},width=width,height=height,mime_type=Image.MIME.get(fmt,'application/octet-stream'),sha256=digest,_signature=signature)
            aid='img_'+uuid.uuid4().hex
            self.db.execute('INSERT INTO assets VALUES(?,?,?,?)',(aid,str(path),json.dumps(metadata,ensure_ascii=False),jid));self.db.commit()
        return dict({k:v for k,v in metadata.items() if not k.startswith('_')},image_id=aid,url='/v1/images/'+aid)

    def asset(self, aid):
        if not isinstance(aid,str) or not ID.fullmatch(aid) or not aid.startswith('img_'): raise ApiError(404,'image_not_found','Unknown image ID')
        with self.lock: row=self.db.execute('SELECT path,metadata FROM assets WHERE id=?',(aid,)).fetchone()
        if row is None: raise ApiError(404,'image_not_found','Unknown image ID')
        path=Path(row['path'])
        if not path.is_file(): raise ApiError(410,'image_missing','The image was deleted or moved')
        metadata=json.loads(row['metadata'])
        if metadata.get('sha256')!=hashlib.sha256(path.read_bytes()).hexdigest(): raise ApiError(410,'image_replaced','The original image was replaced; this ID will not return a different image')
        return path,{k:v for k,v in metadata.items() if not k.startswith('_')}

    def upload(self, payload):
        if not isinstance(payload,dict) or set(payload)-{'data_base64'}: raise ApiError(400,'invalid_parameter','Expected data_base64','data_base64')
        try:
            value=payload['data_base64']
            if not isinstance(value,str): raise ValueError()
            data=base64.b64decode(value,validate=True)
            if len(data)>24*1024*1024: raise ApiError(413,'image_too_large','Image exceeds 24 MiB')
            with Image.open(io.BytesIO(data)) as image:
                if image.width*image.height>24_000_000: raise ApiError(413,'image_too_large','Image exceeds 24 megapixels')
                fmt=image.format;image.verify()
            ext={'PNG':'.png','JPEG':'.jpg','WEBP':'.webp','BMP':'.bmp','TIFF':'.tiff'}.get(fmt)
            if not ext: raise ValueError()
        except (KeyError,ValueError,TypeError,OSError,Image.DecompressionBombError): raise ApiError(400,'invalid_image','Expected a valid PNG, JPEG, WebP, BMP or TIFF','data_base64')
        path=self.root/'uploads'/(uuid.uuid4().hex+ext);path.write_bytes(data)
        return self.register_asset(path)


def create_server(core, port=19876):
    class Handler(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*args): pass
        def send_data(self,status,data,mime='application/json; charset=utf-8'):
            if not isinstance(data,bytes): data=json.dumps(data,ensure_ascii=False,allow_nan=False).encode('utf-8')
            self.send_response(status);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(data)))
            self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(data)
        def dispatch(self):
            self.connection.settimeout(15)
            try:
                if self.headers.get('Origin'): raise ApiError(403,'browser_origin_rejected','Use a local agent client')
                host=self.headers.get('Host','').split(':')[0]
                if host not in ('127.0.0.1','localhost'): raise ApiError(403,'invalid_host','Loopback host required')
                if not secrets.compare_digest(self.headers.get('Authorization',''),'Bearer '+core.token): raise ApiError(401,'unauthorized','Local API token required')
                url=urlsplit(self.path);parts=url.path.strip('/').split('/');query=parse_qs(url.query)
                payload=None
                if self.command=='POST':
                    if self.headers.get('Content-Type','').split(';')[0]!='application/json': raise ApiError(415,'content_type','Use application/json')
                    try: length=int(self.headers.get('Content-Length','0'))
                    except ValueError: raise ApiError(400,'invalid_length','Invalid Content-Length')
                    if not 0<=length<=MAX_BODY: raise ApiError(413,'body_too_large','Request exceeds 32 MiB')
                    try:
                        raw=self.rfile.read(length)
                        payload=json.loads(raw or b'{}',parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
                    except (ValueError,UnicodeError): raise ApiError(400,'invalid_json','Expected valid JSON with finite numbers')
                if self.command=='GET' and parts==['v1','health']: return self.send_data(200,core.health())
                if self.command=='GET' and parts==['v1','models']: return self.send_data(200,dict(models=core.models()))
                if self.command=='GET' and len(parts)==2 and parts[0]=='v1' and parts[1] in ('presets','characters'):
                    return self.send_data(200,{parts[1]:core.catalog(parts[1],query.get('query',[''])[0])})
                if self.command=='POST' and parts==['v1','images']: return self.send_data(201,core.upload(payload))
                if self.command=='POST' and parts==['v1','jobs']: return self.send_data(202,core.submit(payload))
                if len(parts)>=3 and parts[:2]==['v1','jobs']:
                    jid=parts[2]
                    if self.command=='POST' and parts[3:]==['cancel']: return self.send_data(200,core.cancel(jid))
                    if self.command=='GET' and parts[3:] in ([],['wait']):
                        result=core.job(jid)
                        if parts[3:]==['wait']:
                            try: seconds=float(query.get('timeout',['30'])[0])
                            except ValueError: raise ApiError(400,'invalid_parameter','Invalid timeout','timeout')
                            if not math.isfinite(seconds) or not 0<=seconds<=30: raise ApiError(400,'invalid_parameter','timeout must be 0..30','timeout')
                            end=time.monotonic()+seconds;before=json.dumps(result,sort_keys=True)
                            while result['state'] not in TERMINAL and not result['blocked_reason'] and time.monotonic()<end:
                                time.sleep(.2);result=core.job(jid)
                                if json.dumps(result,sort_keys=True)!=before: break
                        return self.send_data(200,result)
                if self.command=='GET' and len(parts)==3 and parts[:2]==['v1','images']:
                    path,meta=core.asset(parts[2])
                    if query.get('format')==['metadata']: return self.send_data(200,dict(meta,image_id=parts[2],url='/v1/images/'+parts[2]))
                    data=path.read_bytes()
                    if query.get('format')==['json']: return self.send_data(200,dict(meta,image_id=parts[2],data_base64=base64.b64encode(data).decode('ascii')))
                    return self.send_data(200,data,meta['mime_type'])
                raise ApiError(404,'route_not_found','Unknown API route')
            except ApiError as exc:
                self.close_connection=True
                self.send_data(exc.status,dict(error=dict(code=exc.code,message=str(exc),field=exc.field,retryable=exc.retryable)))
            except (BrokenPipeError,ConnectionResetError,TimeoutError): self.close_connection=True
            except Exception:
                self.close_connection=True
                self.send_data(500,dict(error=dict(code='internal_error',message='API operation failed; task state was preserved',retryable=True)))
        do_GET=dispatch
        do_POST=dispatch
    server=ThreadingHTTPServer(('127.0.0.1',port),Handler);server.daemon_threads=True
    return server


def main():
    parser=argparse.ArgumentParser(description='Local image workbench agent API')
    parser.add_argument('--app',default=str(Path(__file__).resolve().parent));parser.add_argument('--port',type=int,default=19876)
    args=parser.parse_args();core=Core(args.app)
    try: server=create_server(core,args.port)
    except OSError:
        core.close();raise SystemExit('Local API port is occupied; refusing to replace its owner')
    atomic_json(core.root/'service.json',dict(version=VERSION,url=f'http://127.0.0.1:{server.server_port}',pid=os.getpid(),token_file=str(core.root/'token.txt')))
    try: server.serve_forever()
    finally: server.server_close();core.close()


if __name__=='__main__':main()
