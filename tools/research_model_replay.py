#!/usr/bin/env python3
"""Bounded prompt/schema replay through an already-held local LM Studio broker lease.

Inputs are frozen research request records, not live market data. This measures the
prompt/schema contract only; it does not replay collection, earnings-window checks,
app retries or trading outcomes.
All artifacts go to the explicitly supplied output directory. No load/unload is performed.
"""
import argparse
import copy
import hashlib
import json
import re
import subprocess
import textwrap
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

BROKER = Path('/Users/salman/bin/system-files/lmstudio/resource-trade/resource_trade.py')
LMS = Path('/Users/salman/.lmstudio/bin/lms')
SOURCE = 'StockSage/Sources/StockSage/StockSageAIAssessment.swift'


def stamp():
    return datetime.now(timezone.utc).isoformat()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def block(source, marker):
    """Extract the existing balanced Swift declaration, recording its exact bytes."""
    index = source.index(marker)
    start = source.rfind('\n', 0, index) + 1
    brace = source.index('{', index)
    depth, end = 1, brace + 1
    while depth and end < len(source):
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    if depth:
        raise ValueError('Unbalanced source extraction')
    return source[start:end]


def prepare(repo, ref, cases, output, phase):
    worktree = ref == 'WORKTREE'
    commit = command('git', 'rev-parse', 'HEAD' if worktree else ref, cwd=repo)
    def source_at(path):
        return (repo / path).read_bytes() if worktree else subprocess.check_output(
            ['git', 'show', f'{commit}:{path}'], cwd=repo)
    source_bytes = source_at(SOURCE)
    src = source_bytes.decode('utf-8')
    instructions = textwrap.dedent(re.search(
        r'static let instructions = """\n(.*?)\n    """', src, re.S)[1])
    action = source_at('StockSage/Sources/StockSage/StockSageAdvisor.swift').decode()
    narrator = source_at('StockSage/Sources/StockSage/StockSageCatalystNarrator.swift').decode()
    declarations = [block(src, marker) for marker in [
        'nonisolated static func responseSchema(', 'nonisolated struct Verdict:',
        'nonisolated enum ValidationFailure:', 'nonisolated static func validate(']]
    for marker in ['nonisolated enum PromptVersion:',
                   'private nonisolated static func unsupportedResearchClaim(']:
        if marker in src:
            declarations.append(block(src, marker))
    if 'nonisolated static let qualitativeProsePattern:' in src:
        # Upstream's schema depends on the actual Unicode range generator. Preserve it
        # in the extracted contract instead of substituting a hand-written regex.
        declarations.insert(0, block(src, 'nonisolated static let qualitativeProsePattern:') + '()')
    swift = 'import Foundation\nstruct TradeAdvice {\n' + block(action, 'enum Action:') + '\n}\n'
    if 'StockSageMassiveEarnings.Window' in '\n'.join(declarations):
        earnings = source_at('StockSage/Sources/StockSage/StockSageMassiveEarnings.swift').decode()
        # Compile-only shape: validate receives its default nil window. Extract the
        # real relation cases; this prompt replay does not construct calendar evidence.
        window = block(earnings, 'nonisolated struct Window:')
        swift += 'enum StockSageMassiveEarnings { struct Window {\n'
        swift += block(window, 'enum Relation:') + '\nlet relation: Relation\n} }\n'
    swift += 'struct StockSageCatalystNarrator {\n'
    for marker in ['nonisolated static func numericTokens(', 'nonisolated static func introducesForeignNumbers(']:
        swift += block(narrator, marker) + '\n'
    swift += '}\nstruct StockSageAIAssessment {\n' + '\n'.join(declarations) + '\n}\n'
    swift += '''
let rows = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
var results: [[String: Any]] = []
for row in rows {
 let facts = row["facts"] as! [String]
 if let text = row["text"] as? String {
  switch StockSageAIAssessment.validate(text, facts: facts, symbol: row["symbol"] as? String) {
  case .success(let v): results.append(["result": "accepted", "action": v.action.rawValue])
  case .failure(let f): results.append(["result": f.rawValue])
  }
 } else {
  results.append(try JSONSerialization.jsonObject(with: StockSageAIAssessment.responseSchema(facts: facts)!) as! [String: Any])
 }
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
'''
    swift_path = output / f'{phase}-contract.swift'
    binary = output / f'{phase}-contract'
    swift_path.write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-O', str(swift_path), '-o', str(binary)], check=True)
    schemas = json.loads(subprocess.check_output([str(binary)], input=json.dumps(cases).encode()))
    return {'commit': commit, 'source_state': 'uncommitted-worktree' if worktree else 'commit',
            'source_sha256': digest(source_bytes),
            'extraction_sha256': digest(swift.encode()), 'binary': str(binary),
            'instructions': instructions, 'schemas': schemas}


def verify_lease(session, request_id, instance):
    status = json.loads(command('python3', str(BROKER), 'status'))
    active = status.get('active') or {}
    if not (active.get('owner') == 'stocksage' and active.get('session_id') == session
            and active.get('id') == request_id and active.get('status') == 'held'
            and active.get('model_instance_id') == instance):
        raise RuntimeError('StockSage does not hold the requested model lease')
    models = json.loads(command(str(LMS), 'ps', '--json'))
    model = next((m for m in models if m.get('identifier') == instance and m.get('deviceIdentifier') is None), None)
    if not model or model.get('status') != 'idle' or model.get('queued', 0):
        raise RuntimeError('Owned local model is absent or busy; no competing inference sent')
    if model.get('modelKey') != active.get('model_key') or model.get('contextLength') != active.get('metadata', {}).get('context_length'):
        raise RuntimeError('Model key/context does not match the held research profile')
    return model


def normalize_cases(cases):
    """Preserve the F1..Fn mapping used in the captured user message."""
    normalized = copy.deepcopy(cases)
    for case in normalized:
        facts = case['facts']
        if isinstance(facts, dict):
            expected = [f'F{i}' for i in range(1, len(facts) + 1)]
            if set(facts) != set(expected):
                raise ValueError('Facts must have contiguous F1..Fn IDs')
            facts = [facts[key] for key in expected]
        if not isinstance(facts, list) or not facts or not all(isinstance(f, str) for f in facts):
            raise ValueError('Facts must be a nonempty string list or F-ID mapping')
        user_text = '\n'.join(m['content'] for m in case['request']['messages'] if m['role'] == 'user')
        expected_text = '\n'.join(f'F{i}: {fact}' for i, fact in enumerate(facts, 1))
        if user_text.strip() != expected_text:
            raise ValueError('Captured user message does not match its numbered facts exactly')
        case['facts'] = facts
    return normalized


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo', type=Path, required=True)
    p.add_argument('--input', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--before-ref', required=True)
    p.add_argument('--after-ref', default='HEAD')
    p.add_argument('--run', action='store_true')
    p.add_argument('--session-id')
    p.add_argument('--request-id')
    p.add_argument('--instance')
    p.add_argument('--repetitions', type=int, default=1, choices=range(1, 4))
    args = p.parse_args()
    if args.run and not all([args.session_id, args.request_id, args.instance]):
        p.error('--run requires the saved session, request and held instance IDs')
    cases = json.loads(args.input.read_text())
    if not isinstance(cases, list) or not 1 <= len(cases) <= 12:
        p.error('Use one to twelve frozen cases, never a full research universe')
    cases = normalize_cases(cases)
    args.output.mkdir(parents=True, exist_ok=True)
    receipt_path = args.output / 'replay.json'
    if receipt_path.exists():
        p.error('Choose a new output directory; never overwrite a benchmark receipt')
    profiles = {phase: prepare(args.repo, ref, cases, args.output, phase)
                for phase, ref in [('before', args.before_ref), ('after', args.after_ref)]}
    receipt = {'started_at': stamp(), 'scope': __doc__, 'input_sha256': digest(args.input.read_bytes()),
               'profiles': profiles, 'repetitions': args.repetitions,
               'controls': 'Fixed historical facts; actual extracted Swift prompt/schema/validator. Alternating AB/BA. Output 192, temperature 0.2, no seed/cache reset/thermal isolation. First request may include warmup. Whole-request output throughput is not decode tok/s. No app retry/collection replay.',
               'calls': [], 'status': 'prepared' if not args.run else 'running'}
    def save():
        temp = receipt_path.with_suffix('.tmp')
        temp.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + '\n')
        temp.replace(receipt_path)
    save()
    if not args.run:
        print(json.dumps({'status': 'prepared', 'cases': len(cases), 'receipt': str(receipt_path)}))
        return
    try:
        for repetition in range(args.repetitions):
            for index, case in enumerate(cases):
                for phase in (['before', 'after'] if (index + repetition) % 2 == 0 else ['after', 'before']):
                    loaded = verify_lease(args.session_id, args.request_id, args.instance)
                    request = {k: copy.deepcopy(case['request'][k]) for k in ['messages', 'response_format']}
                    request.update(model=args.instance, max_tokens=192, temperature=0.2, stream=False)
                    # Retain the exact original horizon's opening line; replace the shared contract.
                    opening = request['messages'][0]['content'].split('\n', 1)[0]
                    request['messages'][0]['content'] = opening + '\n' + '\n'.join(profiles[phase]['instructions'].split('\n')[1:])
                    request['response_format']['json_schema']['schema'] = profiles[phase]['schemas'][index]
                    entry = {'symbol': case['symbol'], 'phase': phase, 'repetition': repetition,
                             'started_at': stamp(), 'loaded_model': loaded, 'request': request, 'facts': case['facts']}
                    start = time.perf_counter()
                    try:
                        req = urllib.request.Request('http://127.0.0.1:1234/v1/chat/completions',
                              data=json.dumps(request).encode(), headers={'Content-Type': 'application/json'})
                        with urllib.request.urlopen(req, timeout=90) as response:
                            entry['response'] = json.load(response)
                    except (urllib.error.URLError, TimeoutError, ValueError) as error:
                        entry['error'] = type(error).__name__ + ': ' + str(error)
                    entry['wall_seconds'] = time.perf_counter() - start
                    reply = entry.get('response', {})
                    choice = (reply.get('choices') or [{}])[0]
                    text = choice.get('message', {}).get('content') or ''
                    entry['finish_reason'] = choice.get('finish_reason')
                    validated = json.loads(subprocess.check_output([profiles[phase]['binary']],
                        input=json.dumps([{'symbol': case['symbol'], 'facts': case['facts'], 'text': text}]).encode()))[0]
                    entry['contract_validation'] = validated
                    entry['complete_accepted'] = validated['result'] == 'accepted' and entry['finish_reason'] == 'stop'
                    completion = reply.get('usage', {}).get('completion_tokens')
                    entry['whole_request_output_tok_s'] = completion / entry['wall_seconds'] if isinstance(completion, int) else None
                    receipt['calls'].append(entry)
                    save()
                    print(json.dumps({k:entry.get(k) for k in ['symbol','phase','wall_seconds','finish_reason','contract_validation','complete_accepted']}), flush=True)
                    if 'error' in entry:
                        raise RuntimeError(entry['error'] + '; stopped without retry')
        receipt['status'] = 'completed'
    except Exception as error:
        receipt['status'] = 'stopped'
        receipt['stopped_reason'] = str(error)
        raise
    finally:
        receipt['finished_at'] = stamp()
        save()


if __name__ == '__main__':
    main()
