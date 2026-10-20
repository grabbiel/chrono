#!/usr/bin/env python3
"""Exercise the actual CLI, including error exits and output preservation."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

package = Path(__file__).resolve().parents[1]
cli = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else package / '.build/debug/chronoforge'
fixture = package / 'Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj'
source = fixture / 'scenes/intro.event.dsl'
checks = 0


def run(*args, code=0):
    global checks
    result = subprocess.run([str(cli), *map(str, args)], capture_output=True, text=True, timeout=20)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    checks += 1
    return result.stdout


with tempfile.TemporaryDirectory(prefix='chronoforge-scene-') as directory:
    tmp = Path(directory)
    archive = tmp / 'intro.cfscene'
    canonical = tmp / 'intro.event.dsl'
    run('scene', 'compile', source, '--out', archive, '--project', fixture)
    assert archive.read_bytes().startswith(b'CFSC\x01\x00')
    run('scene', 'decompile', archive, '--out', canonical)
    second = tmp / 'again.cfscene'
    run('scene', 'compile', canonical, '--out', second)
    assert archive.read_bytes() == second.read_bytes()
    trace = json.loads(run('scene', 'preview', archive, '--project', fixture))
    assert trace['elapsedFrames'] == 60
    assert trace['flags'] == ['MET_LAYLA']
    assert trace['stopReason'].startswith('Stopped at external call')
    alternate = json.loads(run('scene', 'preview', source, '--project', fixture, '--flag', 'MET_LAYLA'))
    assert any(row['action'] == 'text "shop"' for row in alternate['entries'])
    assert not any(row['action'] == 'set_flag "MET_LAYLA"' for row in alternate['entries'])
    for args in [(), ('--out',), ('--entry', 'oops'), ('--unknown', 'x')]:
        run('scene', 'compile', source, *args, code=2)
    run('scene', 'compile', source, '--out', tmp / 'not-a-rom.sfc', code=2)
    run('scene', 'decompile', archive, '--out', archive, code=2)
    run('scene', 'preview', source, '--flag', 'UNKNOWN', '--project', fixture, code=1)
    bad = tmp / 'bad.dsl'
    bad.write_text('obj 0 { func 0 { wait -1 } }')
    before = archive.read_bytes()
    output = run('scene', 'compile', bad, '--out', archive, code=1)
    assert 'line 1, column' in output
    assert archive.read_bytes() == before
    bad.write_text('obj 0 { func 0 { text missing } }')
    run('scene', 'compile', bad, '--out', archive, '--project', fixture, code=1)
    assert archive.read_bytes() == before
    bad.write_text('obj 0 { func 0 { jump func0 } }')
    loop = json.loads(run('scene', 'preview', bad, '--steps', '9'))
    assert len(loop['entries']) == 9 and 'Step limit' in loop['stopReason']
    run('validate', fixture)
    # Every project scene as an object: a wait call blocks until the callee's function ends.
    import shutil
    project = tmp / 'objects.ctproj'
    shutil.copytree(fixture, project)
    (project / 'scenes/npc.event.dsl').write_text('obj 1 {\n func 1 {\n  wait 5\n  set_flag MET_LAYLA\n }\n}\n')
    (project / 'scenes/npc.event.json').write_text(json.dumps({'id': 'npc', 'scene': {'object': 1, 'layout': [], 'funcs': [
        {'index': 1, 'stmts': [{'op': 'wait', 'frames': 5}, {'op': 'set_flag', 'symbol': 'MET_LAYLA'}]}]}}))
    boss = tmp / 'boss.event.dsl'
    boss.write_text('obj 2 {\n func 0 {\n  call_obj npc#1 wait level 3\n  text intro\n }\n}\n')
    trace = json.loads(run('scene', 'run', boss, '--project', project))
    assert [(r['frame'], r['scene'], r['level'], r['action']) for r in trace['entries']] == [
        (0, 'boss', 7, 'call_obj "npc"#1 wait level 3'), (1, 'npc', 3, 'wait 5'),
        (6, 'npc', 3, 'set_flag "MET_LAYLA"'), (6, 'boss', 7, 'text "intro"')], trace['entries']
    assert trace['stopReason'] == 'All objects idle' and trace['elapsedFrames'] == 6
    run('scene', 'run', boss, code=2)
    run('scene', 'run', boss, '--project', project, '--party', '1,2,3,4', code=2)
    run('scene', 'preview', boss, '--party', '1', code=2)
    for slots in ['1,,2', '1,', ',1', '1,1', '1,no,2', '16', '']:
        run('scene', 'run', boss, '--project', project, '--party', slots, code=2)
    dotted = tmp / 'boss.intro.event.dsl'
    dotted.write_text(boss.read_text())
    trace = json.loads(run('scene', 'run', dotted, '--project', project))
    assert trace['entries'][0]['scene'] == 'boss.intro'
    dotted_archive = tmp / 'boss.event.cfscene'
    run('scene', 'compile', boss, '--out', dotted_archive, '--project', project)
    trace = json.loads(run('scene', 'run', dotted_archive, '--project', project))
    assert trace['entries'][0]['scene'] == 'boss.event'
    dotted.write_text('obj 1 { func 0 { nop } }')
    assert 'slot 1 is shared' in run('scene', 'run', dotted, '--project', project, code=1)
print(f'{checks} scene CLI checks passed')
