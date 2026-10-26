"""Structured CLI client for Codex, DeepSeek and other local agents."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import quote, urlsplit
import uuid


class Client:
    def __init__(self, app):
        self.app=Path(app).resolve();self.root=self.app/'agent_api'

    def call(self, route, payload=None, raw=False):
        service=json.loads((self.root/'service.json').read_text(encoding='utf-8-sig'))
        token=(self.root/'token.txt').read_text(encoding='ascii').strip()
        address=urlsplit(service['url'])
        if address.scheme!='http' or address.hostname!='127.0.0.1' or address.username or address.password or address.path not in ('','/') or address.query or address.fragment:
            raise ValueError('Refusing non-loopback service URL')
        data=None if payload is None else json.dumps(payload,ensure_ascii=False,allow_nan=False).encode('utf-8')
        request=urllib.request.Request(service['url']+route,data=data,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request,timeout=40) as response:
            return response.read() if raw else json.load(response)

    def ensure_service(self):
        try: return self.call('/v1/health')
        except (OSError,ValueError,KeyError): pass
        self.root.mkdir(parents=True,exist_ok=True)
        options=dict(cwd=str(self.app),stdin=subprocess.DEVNULL)
        if os.name=='nt': options['creationflags']=subprocess.CREATE_NO_WINDOW
        with (self.root/'service.stdout.log').open('ab') as out,(self.root/'service.stderr.log').open('ab') as err:
            subprocess.Popen([sys.executable,'-s',str(self.app/'agent_api.py'),'--app',str(self.app)],stdout=out,stderr=err,**options)
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            try: return self.call('/v1/health')
            except (OSError,ValueError,KeyError): time.sleep(.15)
        raise RuntimeError('Local service could not start; check agent_api/service.stderr.log (port 19876 may be occupied)')

    def start(self, script=None):
        state=self.ensure_service()
        if state['workbench_online']: return state
        script=Path(script) if script else Path.home()/'Desktop'/'本地生图工作台.ps1'
        if not script.is_file(): raise FileNotFoundError('Workbench script not found: '+str(script))
        options=dict(stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if os.name=='nt': options['creationflags']=subprocess.CREATE_NO_WINDOW
        subprocess.Popen(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-STA','-File',str(script),'-AppDirectory',str(self.app)],**options)
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            state=self.call('/v1/health')
            if state['workbench_online']: return state
            time.sleep(.2)
        raise RuntimeError('Service is ready but workbench bridge is offline; restart the updated workbench')


def main():
    for stream in (sys.stdout,sys.stderr):
        if hasattr(stream,'reconfigure'):stream.reconfigure(encoding='utf-8')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',default=str(Path(__file__).resolve().parent))
    commands=parser.add_subparsers(dest='command',required=True)
    commands.add_parser('serve',help='Ensure the local HTTP service is running')
    start=commands.add_parser('start',help='Ensure service and visible workbench are running');start.add_argument('--workbench-script')
    commands.add_parser('health');commands.add_parser('models')
    for name in ('presets','characters'):
        child=commands.add_parser(name);child.add_argument('--query',default='')
    upload=commands.add_parser('upload');upload.add_argument('file')
    submit=commands.add_parser('submit');submit.add_argument('--json');submit.add_argument('--file',help='JSON file, or - for stdin')
    submit.add_argument('--model');submit.add_argument('--prompt');submit.add_argument('--request-id');submit.add_argument('--source',default='agent')
    for name in ('status','cancel','wait'):
        child=commands.add_parser(name);child.add_argument('job_id')
        if name=='wait': child.add_argument('--timeout',type=float,default=30)
    image=commands.add_parser('image');image.add_argument('image_id');image.add_argument('--base64',action='store_true');image.add_argument('--raw',action='store_true');image.add_argument('--out')
    args=parser.parse_args();client=Client(args.app)
    try:
        if args.command=='serve': result=client.ensure_service()
        elif args.command=='start': result=client.start(args.workbench_script)
        elif args.command in ('health','models'): result=client.call('/v1/'+args.command)
        elif args.command in ('presets','characters'): result=client.call('/v1/'+args.command+'?query='+quote(args.query))
        elif args.command=='upload': result=client.call('/v1/images',dict(data_base64=base64.b64encode(Path(args.file).read_bytes()).decode('ascii')))
        elif args.command=='submit':
            if args.json: payload=json.loads(args.json)
            elif args.file: payload=json.loads(sys.stdin.read() if args.file=='-' else Path(args.file).read_text(encoding='utf-8-sig'))
            else: payload=dict(model=args.model,prompt=args.prompt,source=args.source,request_id=args.request_id or str(uuid.uuid4()))
            result=client.call('/v1/jobs',payload)
        elif args.command in ('status','wait','cancel'):
            route='/v1/jobs/'+quote(args.job_id,safe='')
            if args.command=='wait': route+='/wait?timeout='+str(args.timeout)
            if args.command=='cancel': result=client.call(route+'/cancel',{})
            else: result=client.call(route)
        elif args.command=='image':
            route='/v1/images/'+quote(args.image_id,safe='')
            if args.base64: result=client.call(route+'?format=json')
            elif args.raw or args.out:
                data=client.call(route,raw=True)
                if args.out:
                    target=Path(args.out)
                    with target.open('xb') as stream:stream.write(data)
                    result=dict(saved=str(target.resolve()),image_id=args.image_id)
                else: sys.stdout.buffer.write(data);return
            else: result=client.call(route+'?format=metadata')
        print(json.dumps(result,ensure_ascii=False))
    except urllib.error.HTTPError as exc:
        try: result=json.load(exc)
        except ValueError: result=dict(error=dict(code='http_error',message=str(exc)))
        print(json.dumps(result,ensure_ascii=False),file=sys.stderr);raise SystemExit(1)
    except (OSError,ValueError,KeyError,RuntimeError) as exc:
        print(json.dumps(dict(error=dict(code='client_error',message=str(exc))),ensure_ascii=False),file=sys.stderr);raise SystemExit(1)


if __name__=='__main__':main()
