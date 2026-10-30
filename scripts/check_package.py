"""Static package checks. No AutoCAD, imports of toolkit code, or writes to the package."""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def check():
    manifest = json.loads((ROOT / 'package.json').read_text(encoding='utf-8'))
    assert manifest['name'] == 'autocad-rd', 'Unexpected Pi package name'
    assert manifest['private'] is True, 'Package must remain private'
    assert manifest['pi']['skills'] == ['./skills'], 'Unexpected skill roots'
    assert manifest['repository']['url'] == 'https://github.com/yegori/agent-skill-autocad-rd.git'
    plugin = json.loads((ROOT / '.claude-plugin/plugin.json').read_text(encoding='utf-8'))
    market = json.loads((ROOT / '.claude-plugin/marketplace.json').read_text(encoding='utf-8'))
    assert plugin['name'] == 'rd-ci', 'Keep existing Claude plugin identity'
    assert market['name'] == 'rd-ci-arkhyz', 'Keep existing marketplace identity'
    assert market['plugins'][0]['name'] == plugin['name']
    assert market['plugins'][0]['source'] == './'
    expected = {'autocad-rd', 'check-set'}
    assert {p.parent.name for p in (ROOT / 'skills').glob('*/SKILL.md')} == expected
    for name in sorted(expected):
        skill = ROOT / 'skills' / name / 'SKILL.md'
        text = skill.read_text(encoding='utf-8')
        assert text.startswith('---\n'), f'{name}: missing frontmatter'
        frontmatter = text.split('---', 2)[1]
        assert re.search(rf'^name: {re.escape(name)}$', frontmatter, re.M)
        description = re.search(r'^description: (.+)$', frontmatter, re.M)
        assert description and 0 < len(description[1]) <= 1024, f'{name}: invalid description'
        assert skill.parent.parent.parent == ROOT
    for name in ('README.md', 'CLAUDE.md', 'docs/INSTALL.md', 'docs/03_checks.md',
                 'docs/10_playbook.md', 'docs/11_pitfalls.md', 'docs/12_arkhyz_test_cases.md',
                 'docs/PROJECT_CLAUDE_TEMPLATE.md', 'toolkit/README.md',
                 'toolkit/check_env.ps1', 'toolkit/common.ps1', 'toolkit/spds_text/SpdsText.cs',
                 'examples/reports/build_check_xlsx_example.py', 'scripts/install.ps1'):
        assert (ROOT / name).is_file(), f'Missing resource: {name}'
    for name in ('01_spec.md', '02_architecture.md', '04_passports.md', '05_roadmap.md',
                 '07_open_questions.md'):
        assert not (ROOT / 'docs' / name).exists(), f'Service document duplicated: {name}'
    # Check local Markdown links in maintained package docs (historical snapshots excluded).
    for doc in [ROOT / 'README.md', *(ROOT / 'docs').glob('*.md')]:
        for target in re.findall(r'\]\(([^)]+)\)', doc.read_text(encoding='utf-8')):
            if '://' in target or target.startswith('#'):
                continue
            target = target.split('#', 1)[0]
            assert (doc.parent / target).exists(), f'{doc.name}: broken link {target}'
    sources = [*(ROOT / 'toolkit').rglob('*.py'), *(ROOT / 'scripts').glob('*.py')]
    for source in sources:
        compile(source.read_text(encoding='utf-8-sig'), str(source), 'exec')
    print(f'OK: 2 skills, Pi/Claude manifests, resources, links, {len(sources)} Python sources')


if __name__ == '__main__':
    try:
        check()
    except (AssertionError, KeyError, OSError, ValueError, SyntaxError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
