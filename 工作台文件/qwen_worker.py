import argparse
import asyncio
import io
import json
import math
import os
import hashlib
from pathlib import Path
import secrets
import re
import subprocess
import time
import uuid

import aiohttp
from PIL import Image
import requests

APP = Path(__file__).resolve().parent
ROOT = APP.parent
URL = 'http://127.0.0.1:8189'


def build_prompt(config, reference=None):
    if config.get('mode') not in ('text', 'edit'):
        raise ValueError('请选择文生图或图生图。')
    if not str(config.get('prompt', '')).strip():
        raise ValueError('请填写提示词。')
    for name in ('width', 'height', 'resolution'):
        value = config[name]
        if not isinstance(value, int) or value < 256 or value > 2048 or value % 32:
            raise ValueError('尺寸须为 256～2048 之间的 32 倍数。')
    if not isinstance(config['steps'], int) or not 1 <= config['steps'] <= 100:
        raise ValueError('步数须为 1～100。')
    if not isinstance(config['seed'], int) or not 0 <= config['seed'] < 2**63:
        raise ValueError('种子须为非负整数。')
    if not math.isfinite(config['cfg']) or not 1 <= config['cfg'] <= 10:
        raise ValueError('引导强度须为 1～10。')
    profiles = json.loads((APP / 'models.json').read_text(encoding='utf-8-sig'))
    profile = next((p for p in profiles if p['id'] == config.get('model', 'qwen21')), None)
    if profile is None:
        raise ValueError('所选模型未登记，请重新选择。')
    if profile.get('fixed_sigmas') and config['steps'] != 8:
        raise ValueError('Turbo 请使用官方 8 步。')
    graph = json.loads((APP / profile['template']).read_text(encoding='utf-8-sig'))
    negative = str(config.get('negative_prompt') or '').strip()
    if profile.get('kind') in ('sd35', 'sdxl'):
        if config['mode'] == 'edit':
            raise ValueError('该模型目前只支持文生图。')
        graph['1']['inputs']['ckpt_name'] = profile['checkpoint']
        graph['2']['inputs']['text'] = config['prompt'].strip()
        graph['3']['inputs']['text'] = negative
        graph['4']['inputs'].update(width=config['width'], height=config['height'])
        graph['5']['inputs'].update(steps=config['steps'], seed=config['seed'], cfg=config['cfg'])
        graph['7']['inputs']['filename_prefix'] = profile.get('prefix', 'SDXL/App')
        return graph
    if profile.get('kind') == 'zimage':
        if config['mode'] == 'edit':
            raise ValueError('Z-Image 目前只支持文生图。')
        graph['1']['inputs']['unet_name'] = profile['diffusion_model']
        graph['4']['inputs']['text'] = config['prompt'].strip()
        graph['5']['inputs']['text'] = negative
        graph['6']['inputs'].update(width=config['width'], height=config['height'])
        graph['8']['inputs'].update(steps=config['steps'], seed=config['seed'], cfg=config['cfg'])
        graph['10']['inputs']['filename_prefix'] = 'ZImage/App'
        return graph
    graph['1']['inputs']['unet_name'] = profile['diffusion_model']
    graph['4']['inputs'].update(prompt=config['prompt'].strip(), negative_prompt=negative, resolution=config['resolution'])
    graph['5']['inputs'].update(width=config['width'], height=config['height'])
    graph['6']['inputs'].update(steps=config['steps'], seed=config['seed'], cfg=config['cfg'])
    graph['9']['inputs']['filename_prefix'] = 'Qwen21/App'
    if config['mode'] == 'edit':
        if not reference:
            raise ValueError('图生图需要选择参考图片。')
        del graph['5']
        graph['10'] = {'class_type': 'LoadImage', 'inputs': {'image': reference}}
        ref_mode = str(config.get('ref_mode', 'structure'))
        if config.get('ref_preset') is not None:
            tiers = {'structure': {'subtle': .35, 'normal': .65, 'redraw': .9},
                     'feature': {'free': 1.0, 'balanced': .85, 'close': .7}}
            tier = config['ref_preset']
            if ref_mode not in tiers or tier not in tiers[ref_mode]:
                raise ValueError('参考图档位无效，请重新选择。')
            denoise = tiers[ref_mode][tier]
            graph['4']['inputs'].pop('vae', None)
            graph['4']['inputs']['images.image_1'] = ['10', 0]
            graph['6']['inputs']['latent_image'] = ['4', 2]
            if ref_mode == 'structure':
                graph['4']['inputs']['vae'] = ['3', 0]
                instruction = '修改原图，保留未要求修改的内容。'
            else:
                elements = {
                    'character': '仅参考人物外观（脸部、发型、服饰等），场景、动作和构图按文字重新生成。',
                    'pose': '仅参考动作姿态和肢体关系，人物外观、场景和风格按文字重新生成。',
                    'style': '仅参考画风、色彩和光影，主体、动作和构图按文字重新生成。',
                    'all': '综合参考图片中的人物、姿态和风格，具体画面以文字要求为准。',
                }
                element = config.get('ref_element', 'all')
                if element not in elements:
                    raise ValueError('参考元素无效，请重新选择。')
                instruction = '创作一张新图片。' + elements[element] + '参考与文字冲突时，以文字要求为准。'
            graph['4']['inputs']['prompt'] = instruction + '\n具体要求：' + config['prompt'].strip()
            if denoise < 1.0:
                graph['16'] = {'class_type': 'ImageScaleToTotalPixels', 'inputs': {
                    'image': ['10', 0], 'upscale_method': 'lanczos',
                    'megapixels': (config['resolution'] / 1024) ** 2, 'resolution_steps': 32}}
                graph['15'] = {'class_type': 'VAEEncode', 'inputs': {'pixels': ['16', 0], 'vae': ['3', 0]}}
                graph['6']['inputs'].update(latent_image=['15', 0], denoise=denoise)
        elif ref_mode == 'feature':
            strength = config.get('ref_strength', 50)
            try:
                strength = max(0, min(100, int(strength)))
            except (TypeError, ValueError):
                strength = 50
            graph['4']['inputs'].update(**{'images.image_1': ['10', 0]})
            if strength < 20:
                # 低强度 = 只做视觉参考，结构完全交给提示词
                graph['6']['inputs']['latent_image'] = ['4', 2]
            else:
                # 参考强度越高越接近原图：100 → 0.35，20 → 0.83
                graph['15'] = {'class_type': 'VAEEncode', 'inputs': {'pixels': ['10', 0], 'vae': ['3', 0]}}
                graph['6']['inputs']['latent_image'] = ['15', 0]
                graph['6']['inputs']['denoise'] = round(0.35 + (100 - strength) / 100.0 * 0.6, 3)
        else:
            # 结构参考：参考图编码成 latent 拼进序列，尽量保持原图结构
            graph['4']['inputs'].update(vae=['3', 0], **{'images.image_1': ['10', 0]})
            graph['6']['inputs']['latent_image'] = ['4', 2]
    if profile.get('fixed_sigmas'):
        latent = graph['6']['inputs']['latent_image']
        sigmas = profile['fixed_sigmas']
        denoise = float(graph['6']['inputs'].get('denoise', 1.0))
        if denoise < 1.0:
            values = [float(item) for item in str(sigmas).split(',')]
            sigmas = ','.join(str(round(item * denoise, 6)) for item in values)
        graph['11'] = {'class_type': 'RandomNoise', 'inputs': {'noise_seed': config['seed']}}
        graph['12'] = {'class_type': 'CFGGuider', 'inputs': {
            'model': ['8', 0], 'positive': ['4', 0], 'negative': ['4', 1], 'cfg': float(config['cfg'])}}
        graph['13'] = {'class_type': 'KSamplerSelect', 'inputs': {'sampler_name': 'euler'}}
        graph['14'] = {'class_type': 'ManualSigmas', 'inputs': {'sigmas': sigmas}}
        graph['6'] = {'class_type': 'SamplerCustomAdvanced', 'inputs': {
            'noise': ['11', 0], 'guider': ['12', 0], 'sampler': ['13', 0],
            'sigmas': ['14', 0], 'latent_image': latent}}
    return graph


class BatchPlan:
    """Keep only source inputs; construct each task when the runner requests it."""
    def __init__(self, config, entries, repeats, field, numbered=False):
        self.config = config
        self.entries = entries
        self.repeats = repeats
        self.field = field
        self.numbered = numbered

    def __len__(self):
        return len(self.entries) * self.repeats

    def __getitem__(self, index):
        if index < 0:
            index += len(self)
        if not 0 <= index < len(self):
            raise IndexError(index)
        group, repeat = divmod(index, self.repeats)
        seed = self.config['seed']
        task = dict(self.config)
        task[self.field] = self.entries[group]
        task['seed'] = secrets.randbelow(2**63) if seed == -1 else (seed + index) % 2**63
        if self.numbered:
            task['name'] = f'{group+1}-{repeat+1}'
        return task


def plan_tasks(config):
    if config.get('mode') not in ('text', 'edit'):
        raise ValueError('请选择文生图或图生图。')
    seed = config['seed']
    if type(seed) is not int or not -1 <= seed < 2**63:
        raise ValueError('种子须为 -1 或非负整数。')
    prompts = config.get('prompts')
    if prompts is not None and (not isinstance(prompts, list) or not prompts):
        raise ValueError('提示词列表不能为空。')
    if prompts and config['mode'] == 'edit' and len(prompts) > 1:
        raise ValueError('图生图请合并为一段修改要求。')
    if config['mode'] == 'text':
        count = config.get('count', 1)
        if type(count) is not int or count < 1:
            raise ValueError('生成数量须为正整数。')
        if prompts:
            for item in prompts:
                if not isinstance(item, str) or not item.strip():
                    raise ValueError('提示词段不能为空。')
            return BatchPlan(config, prompts, count, 'prompt', numbered=True)
        return BatchPlan(config, [''], count, 'image')
    images = config.get('images') or [config.get('image', '')]
    if not isinstance(images, list) or not images:
        raise ValueError('请至少选择一张参考图片。')
    repeats = config.get('reference_count', 1)
    if type(repeats) is not int or repeats < 1:
        raise ValueError('每张参考图生成数量须为正整数。')
    for name in images:
        path = Path(name)
        if not path.is_file():
            raise ValueError('参考图片不存在：' + str(path))
        try:
            with Image.open(path) as image:
                image.verify()
        except (OSError, ValueError) as exc:
            raise ValueError('无法读取参考图片：' + str(path)) from exc
    return BatchPlan(config, images, repeats, 'image')


def get_output_character_name(config):
    prompt = config.get('prompt', '')
    names = []
    for role in config.get('output_characters') or []:
        text = role['text']
        if text and re.search(r'(?:^|,|\r?\n)[ \t]*' + re.escape(text) + r'[ \t]*(?=,|\r?$)', prompt, re.M):
            if role['name'] not in names:
                names.append(role['name'])
    return '+'.join(names)


def save_result(data, folder, seed, name=None, character_name=None):
    with Image.open(io.BytesIO(data)) as image:
        image.verify()
    folder = Path(folder)
    if not folder.is_absolute():
        raise ValueError('请选择完整的输出文件夹路径。')
    folder.mkdir(parents=True, exist_ok=True)
    image_extensions = {'.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tif', '.tiff', '.gif', '.avif'}
    prefix = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', character_name or '').strip(' .')[:120]
    prefix = prefix + '_' if prefix else ''
    pattern = re.compile(re.escape(prefix) + r'([0-9]+)', re.I)
    numbers = (int(match[1]) for path in folder.iterdir()
               if path.is_file() and path.suffix.lower() in image_extensions
               and (match := pattern.fullmatch(path.stem)))
    number = max(numbers, default=0) + 1
    while True:
        destination = folder / f'{prefix}{number}.png'
        try:
            stream = destination.open('xb')
        except FileExistsError:
            number += 1
            continue
        with stream:
            stream.write(data)
        break
    return destination


def write_json(path, values):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        temporary.write_text(json.dumps(values, ensure_ascii=False), encoding='utf-8')
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def write_status(job, **values):
    write_json(job / 'status.json', values)


class GenerationStopped(Exception):
    pass


def check_stop(job):
    if (job / 'stop').exists():
        raise GenerationStopped()


async def cancel_owned_prompt(session, pid):
    timeout = aiohttp.ClientTimeout(total=5)
    async with session.post(URL + '/queue', json={'delete': [pid]}, timeout=timeout) as response:
        response.raise_for_status()
    async with session.post(URL + '/interrupt', json={'prompt_id': pid}, timeout=timeout) as response:
        response.raise_for_status()
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        async with session.get(URL + '/queue', timeout=timeout) as response:
            response.raise_for_status()
            queue = await response.json()
        if not any(item[1] == pid for key in ('queue_running', 'queue_pending') for item in queue.get(key, [])):
            return
        await asyncio.sleep(0.5)
    raise RuntimeError('引擎未确认任务停止，请检查引擎状态。')


def ensure_service(job):
    check_stop(job)
    try:
        response = requests.get(URL + '/object_info/TextEncodeQwenImage21', timeout=3)
        if response.ok and 'TextEncodeQwenImage21' in response.json():
            return
    except requests.RequestException:
        pass
    write_status(job, state='running', message='正在启动生图引擎，首次启动请稍等…', progress=0)
    with (APP / 'engine.log').open('ab') as log:
        process = subprocess.Popen(
            [str(ROOT / 'python_embeded' / 'python.exe'), '-s', str(ROOT / 'launch_qwen21.py')],
            cwd=ROOT, stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        check_stop(job)
        if process.poll() is not None:
            raise RuntimeError('生图引擎未能启动，请查看应用目录中的 engine.log。')
        try:
            response = requests.get(URL + '/object_info/TextEncodeQwenImage21', timeout=2)
            if response.ok and 'TextEncodeQwenImage21' in response.json():
                return
        except requests.RequestException:
            pass
        time.sleep(1)
    raise RuntimeError('引擎启动超时，请稍后重试。')


async def generate(config, job, index=0, total=1, previous_output=None):
    check_stop(job)
    last_progress = 0
    def report(message, progress=0, **values):
        nonlocal last_progress
        last_progress = max(last_progress, progress)
        write_status(job, state='running', message=f'第 {index+1}/{total} 张 · {message}',
                     progress=int((index + last_progress/100) * 100/total),
                     item_progress=last_progress, completed=index, total=total,
                     output=previous_output, **values)
    client = uuid.uuid4().hex
    timeout = aiohttp.ClientTimeout(total=120)
    async with aiohttp.ClientSession(timeout=timeout, trust_env=False) as session:
        reference = None
        if config['mode'] == 'edit':
            path = Path(config.get('image', ''))
            if not path.is_file():
                raise ValueError('请选择存在的参考图片。')
            with Image.open(path) as image:
                image.verify()
            report(message='正在读取参考图片…', progress=0)
            with path.open('rb') as stream:
                form = aiohttp.FormData()
                form.add_field('image', stream, filename=f'app_{uuid.uuid4().hex}{path.suffix.lower()}')
                async with session.post(URL + '/upload/image', data=form) as response:
                    response.raise_for_status()
                    uploaded = await response.json()
            reference = '/'.join(filter(None, [uploaded.get('subfolder'), uploaded['name']]))
        check_stop(job)
        graph = build_prompt(config, reference)
        async with session.ws_connect(URL.replace('http:', 'ws:') + '/ws', params={'clientId': client}) as ws:
            async with session.post(URL + '/prompt', json={'prompt': graph, 'client_id': client}) as response:
                result = await response.json()
                if response.status != 200 or result.get('node_errors'):
                    raise RuntimeError('参数或模型配置未通过检查：' + json.dumps(result, ensure_ascii=False)[:800])
            pid = result['prompt_id']
            report(message='任务已提交，正在准备模型…', progress=0, prompt_id=pid)
            deadline = time.monotonic() + 3600
            while time.monotonic() < deadline:
                if (job / 'stop').exists():
                    write_status(job, state='stopping', message='正在终止当前任务，等待引擎确认…',
                                 progress=int(index*100/total), completed=index, total=total, output=previous_output)
                    await cancel_owned_prompt(session, pid)
                    raise GenerationStopped()
                try:
                    message = await ws.receive(timeout=1)
                except asyncio.TimeoutError:
                    message = None
                if message and message.type == aiohttp.WSMsgType.TEXT:
                    event = json.loads(message.data)
                    data = event.get('data', {})
                    if data.get('prompt_id') == pid:
                        if event['type'] == 'progress':
                            value, maximum = data['value'], data['max']
                            report(message=f'正在生成：{value} / {maximum} 步',
                                         progress=int(value * 95 / maximum), prompt_id=pid)
                        elif event['type'] == 'executing' and data.get('node'):
                            labels = {'4': '正在理解提示词 / 参考图…', '6': '正在生成图片…', '7': '正在还原图片…', '9': '正在保存结果…'}
                            report(message=labels.get(data['node'], '正在加载模型…'), progress=0, prompt_id=pid)
                async with session.get(URL + '/history/' + pid) as response:
                    response.raise_for_status()
                    history = (await response.json()).get(pid)
                if history:
                    if history['status']['status_str'] != 'success':
                        errors = [v[1].get('exception_message', '') for v in history['status'].get('messages', []) if v[0] == 'execution_error']
                        raise RuntimeError('生成失败：' + ('；'.join(errors) or '请检查引擎日志。'))
                    save_id = next((nid for nid, node in graph.items() if node.get('class_type') == 'SaveImage'), '9')
                    image = history['outputs'][save_id]['images'][0]
                    async with session.get(URL + '/view', params={k: image[k] for k in ('filename', 'subfolder', 'type')}) as response:
                        response.raise_for_status()
                        content = await response.read()
                    output = save_result(content, Path(config['output']), config['seed'], config.get('name'), character_name=get_output_character_name(config))
                    return {'output': str(output), 'seed': config['seed'], 'sha256': hashlib.sha256(content).hexdigest(), 'effective_prompt': graph.get('4', {}).get('inputs', {}).get('prompt', config['prompt'])}
                if message and message.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                    raise RuntimeError('与引擎的连接已断开，请检查引擎后重试。')
            raise TimeoutError('任务等待超过一小时，请检查引擎。')


def prepare_random_presets(task, previous):
    groups = task.get('random_presets') or []
    if not isinstance(groups, list):
        raise ValueError('随机预设配置无效。')
    picked = dict(previous)
    parts = [str(task.get('prompt', '')).strip()]
    keys = set()
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get('key'), str) or not group['key'] or group['key'] in keys:
            raise ValueError('随机预设分类无效或重复。')
        key = group['key']
        keys.add(key)
        values = group.get('choices')
        if not isinstance(values, list) or not values or any(not isinstance(v, str) or not v.strip() for v in values):
            raise ValueError('随机预设分类需要至少一个有效选项。')
        values = list(dict.fromkeys(v.strip() for v in values))
        candidates = [v for v in values if v != previous.get(key)] or values
        picked[key] = secrets.choice(candidates)
        parts.append(picked[key])
    if not groups:
        return task, picked
    return dict(task, prompt=', '.join(p for p in parts if p)), picked


async def run_batch(tasks, job):
    results = []
    previous_presets = {}
    total = len(tasks)
    for index, task in enumerate(tasks):
        if (job / 'stop').exists():
            write_status(job, state='cancelled',
                         message=f'已停止，共保存 {len(results)} 张。',
                         progress=int(len(results)*100/total), completed=len(results), total=total,
                         outputs=results, output=(results[-1]['output'] if results else ''))
            break
        previous = results[-1]['output'] if results else None
        write_status(job, state='running', message=f'第 {index+1}/{total} 张 · 正在准备…',
                     progress=int(index*100/total), completed=index, total=total, output=previous)
        try:
            task, previous_presets = prepare_random_presets(task, previous_presets)
            result = await generate(task, job, index, total, previous)
            if previous_presets:
                result['random_presets'] = dict(previous_presets)
            for key in ('model', 'mode', 'prompt', 'negative_prompt', 'steps', 'cfg', 'width', 'height'):
                if key in task:
                    result.setdefault(key, task[key])
            results.append(result)
            write_json(job / 'results.json', results)
        except GenerationStopped:
            write_status(job, state='cancelled', message=f'已停止，共保留 {len(results)} 张已完成图片。',
                         progress=int(index*100/total), completed=len(results), total=total,
                         outputs=results, output=previous)
            return results
        except Exception as exc:
            write_status(job, state='error',
                         message=f'第 {index+1}/{total} 张失败：{exc}。已保存 {len(results)} 张，其余任务已停止。',
                         progress=int(index*100/total), completed=len(results), total=total,
                         outputs=results, output=previous)
            raise
        write_status(job, state='done' if len(results) == total else 'running',
                     message=f'生成完成，共 {len(results)} 张' if len(results) == total else f'已完成 {len(results)}/{total} 张',
                     progress=int(len(results)*100/total), completed=len(results), total=total,
                     outputs=results, output=result['output'], seed=result['seed'])
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('request')
    args = parser.parse_args()
    request = Path(args.request)
    job = request.parent
    batch_started = False
    try:
        config = json.loads(request.read_text(encoding='utf-8-sig'))
        tasks = plan_tasks(config)
        first_task, _ = prepare_random_presets(tasks[0], {})
        build_prompt(first_task, 'validate-reference' if config['mode'] == 'edit' else None)
        output = Path(config['output'])
        if not output.is_absolute():
            raise ValueError('请选择完整的输出文件夹路径。')
        output.mkdir(parents=True, exist_ok=True)
        probe = output / ('.qwen_write_check_' + uuid.uuid4().hex)
        with probe.open('xb') as stream:
            stream.write(b'')
        probe.unlink()
        ensure_service(job)
        batch_started = True
        asyncio.run(run_batch(tasks, job))
    except GenerationStopped:
        write_status(job, state='cancelled', message='已停止。', progress=0, completed=0)
    except Exception as exc:
        if not batch_started:
            write_status(job, state='error', message=str(exc), progress=0)
        raise


if __name__ == '__main__':
    main()
