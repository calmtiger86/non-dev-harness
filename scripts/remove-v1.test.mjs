// 실행: node scripts/remove-v1.test.mjs
// 임시 설정 폴더(CLAUDE_CONFIG_DIR)에 v1 설치 흔적을 만들고 정리 도구를 실제 프로세스로 돌려 확인한다.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, lstatSync,
  readlinkSync, realpathSync, rmSync, symlinkSync, existsSync, chmodSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), 'remove-v1.mjs');
const base = realpathSync(mkdtempSync(join(tmpdir(), 'ndh-remove-')));
const HOME = join(base, 'home');
mkdirSync(HOME);

const OUR_HOOK = { type: 'command', command: 'node "/Users/x/.claude/plugins/non-dev-harness/hooks/session-start-hint.mjs"', timeout: 5 };
const OUR_HOOK_WIN = { type: 'command', command: 'node "C:\\Users\\x\\.claude\\plugins\\non-dev-harness\\hooks\\session-start-hint.mjs"' };
const OTHER_HOOK = { type: 'command', command: 'node other.mjs' };
const DECOY_HOOK = { type: 'command', command: 'node "/Users/x/Desktop/non-dev-harness/hooks/session-start.mjs"' };
const STOP_HOOK = { type: 'command', command: 'node stop.mjs' };

const SETTINGS = {
  model: 'opus',
  hooks: {
    SessionStart: [
      { hooks: [OUR_HOOK] },
      { matcher: 'startup', hooks: [OUR_HOOK_WIN, OTHER_HOOK] },
      { hooks: [DECOY_HOOK] },
    ],
    Stop: [{ hooks: [STOP_HOOK] }],
  },
  permissions: { allow: ['Read'] },
};
const SETTINGS_AFTER = {
  model: 'opus',
  hooks: {
    SessionStart: [
      { matcher: 'startup', hooks: [OTHER_HOOK] },
      { hooks: [DECOY_HOOK] },
    ],
    Stop: [{ hooks: [STOP_HOOK] }],
  },
  permissions: { allow: ['Read'] },
};

let fixtureCount = 0;
function write(file, text) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, text);
}

// v1 설치 흔적 + 남의 파일이 섞인 설정 폴더를 만든다.
function makeConfig({ settingsText = JSON.stringify(SETTINGS, null, 4), foreignCi = false } = {}) {
  fixtureCount += 1;
  const dir = join(base, `config-${fixtureCount}`);
  write(join(dir, 'skills', 'hs', 'SKILL.md'), '---\nname: hs\n---\n`<!-- non-dev-harness:v1 -->` 표식 확인\n');
  write(join(dir, 'skills', 'hs', 'references', 'guide.md'), '참고\n');
  write(join(dir, 'skills', 'ci', 'SKILL.md'), foreignCi ? '---\nname: ci\n---\n남의 CI 스킬\n' : '<!-- non-dev-harness:v1 --> ci\n');
  write(join(dir, 'skills', 'co', 'SKILL.md'), '<!-- non-dev-harness:v1 --> co\n');
  write(join(dir, 'skills', 'other', 'SKILL.md'), '다른 스킬\n');
  write(join(dir, 'rules', 'common', 'non-dev-core.md'), '# Non-Dev Harness\n\n규칙\n');
  write(join(dir, 'rules', 'common', 'user-config.md'), '# User Config\n');
  write(join(dir, 'plugins', 'non-dev-harness', 'hooks', 'session-start-hint.mjs'), '// v1\n');
  write(join(dir, 'plugins', 'non-dev-harness', 'install.js'), '// v1\n');
  write(join(dir, 'plugins', 'cache', 'keep.txt'), '유지\n');
  if (settingsText !== null) write(join(dir, 'settings.json'), settingsText);
  return dir;
}

// 폴더 전체를 { 상대경로: 내용 } 으로 찍는다. 심볼릭 링크는 링크 자체를 기록한다.
function snapshot(root) {
  const out = {};
  const walk = (dir, rel) => {
    for (const name of readdirSync(dir).sort()) {
      const p = join(dir, name);
      const r = rel ? `${rel}/${name}` : name;
      const st = lstatSync(p);
      if (st.isSymbolicLink()) out[r] = `link -> ${readlinkSync(p)}`;
      else if (st.isDirectory()) { out[r] = 'dir'; walk(p, r); }
      else out[r] = readFileSync(p, 'utf8');
    }
  };
  walk(root, '');
  return out;
}

function run(configDir, args = []) {
  assert.ok(configDir.startsWith(base + sep), '임시 폴더 밖의 설정 폴더로는 실행하지 않는다');
  const env = { ...process.env, CLAUDE_CONFIG_DIR: configDir, HOME, USERPROFILE: HOME };
  const r = spawnSync(process.execPath, [SCRIPT, ...args], { env, encoding: 'utf8' });
  return { status: r.status, out: r.stdout + r.stderr };
}

const backupsOf = (dir) => (existsSync(join(dir, 'backups')) ? readdirSync(join(dir, 'backups')) : []);
const RESTART = 'Claude Code를 다시 시작하세요. 그래야 /ci가 새 플러그인을 가리킵니다.';

function assertCleaned(dir, { foreignCi = false } = {}) {
  assert.equal(existsSync(join(dir, 'skills', 'hs')), false, '/hs 스킬이 남음');
  assert.equal(existsSync(join(dir, 'skills', 'co')), false, '/co 스킬이 남음');
  assert.equal(existsSync(join(dir, 'skills', 'ci')), foreignCi, foreignCi ? '남의 ci 스킬이 지워짐' : '/ci 스킬이 남음');
  assert.equal(existsSync(join(dir, 'rules', 'common', 'non-dev-core.md')), false, '규칙 파일이 남음');
  assert.equal(existsSync(join(dir, 'plugins', 'non-dev-harness')), false, 'v1 플러그인 폴더가 남음');
  assert.ok(existsSync(join(dir, 'skills', 'other', 'SKILL.md')), '다른 스킬이 지워짐');
  assert.ok(existsSync(join(dir, 'rules', 'common', 'user-config.md')), '다른 규칙이 지워짐');
  assert.ok(existsSync(join(dir, 'plugins', 'cache', 'keep.txt')), '다른 플러그인 파일이 지워짐');
}

const tests = [
  ['미리보기는 아무것도 바꾸지 않음 (backups 폴더도 만들지 않음)', () => {
    const dir = makeConfig();
    const before = snapshot(dir);
    const r = run(dir);
    assert.equal(r.status, 0, r.out);
    assert.match(r.out, /미리보기/);
    assert.ok(r.out.includes(join(dir, 'plugins', 'non-dev-harness')));
    assert.ok(r.out.includes('settings.json의 SessionStart 훅 2개'));
    assert.deepEqual(snapshot(dir), before);
  }],
  ['--apply는 백업을 만들고 우리 것만 지움, settings.json은 v1 훅만 뺌', () => {
    const settingsText = JSON.stringify(SETTINGS, null, 4);
    const dir = makeConfig({ settingsText });
    const r = run(dir, ['--apply']);
    assert.equal(r.status, 0, r.out);
    assertCleaned(dir);
    assert.equal(readFileSync(join(dir, 'settings.json'), 'utf8'), JSON.stringify(SETTINGS_AFTER, null, 2) + '\n');
    assert.ok(r.out.includes(RESTART));

    const backups = backupsOf(dir);
    assert.equal(backups.length, 1);
    assert.match(backups[0], /^non-dev-harness-v1-\d{8}-\d{6}$/);
    const b = join(dir, 'backups', backups[0]);
    assert.equal(readFileSync(join(b, 'settings.json'), 'utf8'), settingsText);
    assert.ok(existsSync(join(b, 'skills', 'hs', 'references', 'guide.md')));
    assert.ok(existsSync(join(b, 'skills', 'ci', 'SKILL.md')));
    assert.ok(existsSync(join(b, 'skills', 'co', 'SKILL.md')));
    assert.ok(existsSync(join(b, 'rules', 'common', 'non-dev-core.md')));
    assert.ok(existsSync(join(b, 'plugins', 'non-dev-harness', 'install.js')));
    assert.equal(existsSync(join(b, 'skills', 'other')), false, '대상이 아닌 것까지 백업함');
  }],
  ['두 번째 실행은 정리할 것이 없고 새 백업도 만들지 않음', () => {
    const dir = makeConfig();
    assert.equal(run(dir, ['--apply']).status, 0);
    const r = run(dir, ['--apply']);
    assert.equal(r.status, 0, r.out);
    assert.match(r.out, /정리할 v1 흔적이 없습니다/);
    assert.equal(backupsOf(dir).length, 1);
  }],
  ['남의 ci 스킬은 남김', () => {
    const dir = makeConfig({ foreignCi: true });
    const r = run(dir, ['--apply']);
    assert.equal(r.status, 0, r.out);
    assertCleaned(dir, { foreignCi: true });
    assert.match(r.out, /다른 스킬이라 건드리지 않음/);
    assert.equal(readFileSync(join(dir, 'skills', 'ci', 'SKILL.md'), 'utf8'), '---\nname: ci\n---\n남의 CI 스킬\n');
  }],
  ['첫 줄이 다른 규칙 파일은 남김', () => {
    const dir = makeConfig();
    write(join(dir, 'rules', 'common', 'non-dev-core.md'), '# 내가 쓴 규칙\n');
    assert.equal(run(dir, ['--apply']).status, 0);
    assert.equal(readFileSync(join(dir, 'rules', 'common', 'non-dev-core.md'), 'utf8'), '# 내가 쓴 규칙\n');
  }],
  ['깨진 settings.json이면 settings.json과 옛 플러그인 폴더는 남기고 스킬·규칙만 정리', () => {
    const broken = '{ "hooks": { "SessionStart": [ broken';
    const dir = makeConfig({ settingsText: broken });
    const pluginBefore = snapshot(join(dir, 'plugins', 'non-dev-harness'));
    const r = run(dir, ['--apply']);
    assert.equal(r.status, 0, r.out);
    assert.equal(readFileSync(join(dir, 'settings.json'), 'utf8'), broken);
    assert.deepEqual(snapshot(join(dir, 'plugins', 'non-dev-harness')), pluginBefore, '옛 플러그인 폴더가 바뀜');
    for (const name of ['hs', 'ci', 'co']) assert.equal(existsSync(join(dir, 'skills', name)), false, `/${name} 스킬이 남음`);
    assert.equal(existsSync(join(dir, 'rules', 'common', 'non-dev-core.md')), false, '규칙 파일이 남음');
    assert.match(r.out, /settings\.json을 읽지 못해\(JSON 오류: .*\) settings\.json과 옛 플러그인 폴더는 그대로 둡니다\. settings\.json을 고친 뒤 다시 실행하세요/);
  }],
  ['깨진 settings.json을 고친 뒤 다시 실행하면 남은 것을 정리', () => {
    const dir = makeConfig({ settingsText: '{ broken' });
    assert.equal(run(dir, ['--apply']).status, 0);
    writeFileSync(join(dir, 'settings.json'), JSON.stringify(SETTINGS));
    const r = run(dir, ['--apply']);
    assert.equal(r.status, 0, r.out);
    assertCleaned(dir);
    assert.deepEqual(JSON.parse(readFileSync(join(dir, 'settings.json'), 'utf8')), SETTINGS_AFTER);
  }],
  ['BOM이 붙은 settings.json도 읽어서 처리', () => {
    const dir = makeConfig({ settingsText: '\uFEFF' + JSON.stringify(SETTINGS) });
    assert.equal(run(dir, ['--apply']).status, 0);
    assert.deepEqual(JSON.parse(readFileSync(join(dir, 'settings.json'), 'utf8')), SETTINGS_AFTER);
  }],
  ['심볼릭 링크 settings.json은 링크를 유지하고 실제 파일에 씀', () => {
    if (process.platform === 'win32') return; // Windows는 링크 생성에 관리자 권한이 필요할 수 있음
    const dir = makeConfig({ settingsText: null });
    const realFile = join(base, `real-settings-${fixtureCount}.json`);
    const original = JSON.stringify(SETTINGS, null, 2);
    writeFileSync(realFile, original);
    symlinkSync(realFile, join(dir, 'settings.json'));
    const r = run(dir, ['--apply']);
    assert.equal(r.status, 0, r.out);
    assert.ok(lstatSync(join(dir, 'settings.json')).isSymbolicLink(), '링크가 일반 파일로 바뀜');
    assert.equal(readFileSync(realFile, 'utf8'), JSON.stringify(SETTINGS_AFTER, null, 2) + '\n');
    const b = join(dir, 'backups', backupsOf(dir)[0], 'settings.json');
    assert.ok(!lstatSync(b).isSymbolicLink(), '백업이 링크로 남음');
    assert.equal(readFileSync(b, 'utf8'), original);
  }],
  ['백업에 실패하면 아무것도 지우지 않고 종료 코드 1', () => {
    const dir = makeConfig();
    write(join(dir, 'backups'), '폴더 자리에 놓인 파일\n');
    const before = snapshot(dir);
    const r = run(dir, ['--apply']);
    assert.equal(r.status, 1, r.out);
    assert.match(r.out, /백업에 실패해서 아무것도 지우지 않았습니다/);
    assert.deepEqual(snapshot(dir), before);
  }],
  ['settings.json을 고치지 못하면 나머지를 지우지 않고 종료 코드 1', () => {
    if (process.platform === 'win32') return; // 폴더 쓰기 금지(chmod) 흉내가 POSIX 전용
    const dir = makeConfig({ settingsText: null });
    const roDir = join(base, `read-only-${fixtureCount}`);
    write(join(roDir, 'settings.json'), JSON.stringify(SETTINGS, null, 2));
    symlinkSync(join(roDir, 'settings.json'), join(dir, 'settings.json'));
    chmodSync(roDir, 0o555);
    try {
      const r = run(dir, ['--apply']);
      assert.equal(r.status, 1, r.out);
      assert.match(r.out, /settings.json을 고치지 못해 나머지도 지우지 않았습니다/);
      assert.ok(existsSync(join(dir, 'plugins', 'non-dev-harness', 'hooks', 'session-start-hint.mjs')), 'v1 훅 파일이 지워짐');
      assert.ok(existsSync(join(dir, 'skills', 'hs', 'SKILL.md')), '/hs 스킬이 지워짐');
      assert.deepEqual(readdirSync(roDir), ['settings.json'], '임시 파일이 남음');
    } finally {
      chmodSync(roDir, 0o755);
    }
  }],
  ['v1 흔적이 없는 설정 폴더', () => {
    const dir = join(base, 'config-empty');
    mkdirSync(dir);
    const r = run(dir, ['--apply']);
    assert.equal(r.status, 0, r.out);
    assert.match(r.out, /정리할 v1 흔적이 없습니다/);
    assert.deepEqual(readdirSync(dir), []);
  }],
];

let failed = 0;
for (const [name, fn] of tests) {
  try {
    fn();
    console.log(`ok   ${name}`);
  } catch (err) {
    failed += 1;
    console.log(`FAIL ${name}\n${err.message}`);
  }
}
rmSync(base, { recursive: true, force: true });
console.log(`\n${tests.length - failed}/${tests.length} 통과`);
process.exitCode = failed ? 1 : 0;
