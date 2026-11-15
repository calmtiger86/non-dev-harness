// 실행: node hooks/session-start.test.mjs
// 임시 폴더에 가짜 홈·설정 폴더·프로젝트를 만들고 훅을 실제 프로세스로 돌려 출력을 확인한다.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync, rmSync, readFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { posixDriveToWin } from './win-path.mjs';

const HOOK_DIR = dirname(fileURLToPath(import.meta.url));
const HOOK = join(HOOK_DIR, 'session-start.mjs');
const REPO = dirname(HOOK_DIR);

// 계약 D 문구 (훅에서 가져오지 않고 그대로 적는다)
const MSG = 'non-dev-harness: 지난 작업을 이어받으려면 /ci, 마칠 때는 /co 를 입력하세요.';
const MSG_V1 = MSG + ' 이 프로젝트의 기록 파일은 옛 형식(v1)이라 /hs 로 새 형식으로 바꿀 수 있어요.';
const MSG_INSTALL = 'non-dev-harness: 예전 방식(v1)으로 설치된 파일이 남아 있습니다. Claude에게 "non-dev-harness v1 정리해줘"라고 말하면 정리합니다.';
const ctx = (root, journal) => `이 폴더는 non-dev-harness 프로젝트입니다(하네스 루트: ${root}). 기록 파일은 CLAUDE.md, ${journal}, ERROR.md, ISSUE.md, WIKI.md입니다. 사용자는 보통 /ci로 지난 작업을 이어받고 /co로 기록을 남깁니다.`;
const ctxV1 = (root) => ctx(root, 'MEMORY.md') + ' 기록 파일이 v1 형식입니다.';
const ctxInstall = (pluginRoot) => `예전 설치(v1) 흔적이 있습니다. 정리 도구는 node "${join(pluginRoot, 'scripts', 'remove-v1.mjs')}" 이며, 인자 없이 실행하면 미리보기만 하고 --apply 를 붙이면 백업 뒤 정리합니다.`;
const expected = (systemMessage, additionalContext) => ({
  systemMessage,
  hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext },
});

const base = realpathSync(mkdtempSync(join(tmpdir(), 'ndh-hook-')));
const write = (file, text = '') => {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, text);
};
const dir = (...parts) => {
  const p = join(base, ...parts);
  mkdirSync(p, { recursive: true });
  return p;
};

const HOME = dir('home');
const CONFIG_EMPTY = dir('config-empty');
const CONFIG_V1 = dir('config-v1');
const PLUGIN_ROOT = dir('plugin root');
write(join(CONFIG_V1, 'plugins', 'non-dev-harness', 'hooks', 'session-start-hint.mjs'));
write(join(HOME, 'CLAUDE.md'), '<!-- non-dev-harness:v2 -->\n'); // 홈 자체의 표식은 무시되어야 한다

const V2 = dir('home', 'v2proj');
write(join(V2, 'CLAUDE.md'), '<!-- non-dev-harness:v2 -->\n# 프로젝트\n');
write(join(V2, 'JOURNAL.md'));
const V1 = dir('home', 'v1proj');
write(join(V1, 'CLAUDE.md'), '<!-- non-dev-harness:v1 -->\n# 프로젝트\n');
write(join(V1, 'MEMORY.md'), '# 프로젝트 — 메모리\n');
const V2_MEMORY = dir('home', 'v2-memory-only');
write(join(V2_MEMORY, 'CLAUDE.md'), '<!-- non-dev-harness:v2 -->\n');
write(join(V2_MEMORY, 'MEMORY.md'), '# 프로젝트 — 메모리\n');
const V2_USER_MEMORY = dir('home', 'v2-user-memory');
write(join(V2_USER_MEMORY, 'CLAUDE.md'), '<!-- non-dev-harness:v2 -->\n');
write(join(V2_USER_MEMORY, 'MEMORY.md'), '# 내가 쓴 메모\n');
const BOM_CRLF = dir('home', 'bom-crlf');
write(join(BOM_CRLF, 'CLAUDE.md'), '\uFEFF<!-- non-dev-harness:v2 -->\r\n# 프로젝트\r\n');
const SECOND_LINE = dir('home', 'second-line');
write(join(SECOND_LINE, 'CLAUDE.md'), '# 프로젝트\n<!-- non-dev-harness:v2 -->\n');
const MID_LINE = dir('home', 'mid-line');
write(join(MID_LINE, 'CLAUDE.md'), '# 프로젝트 <!-- non-dev-harness:v2 -->\n');
const PLAIN = dir('home', 'plain');
const OUTSIDE = dir('outside', 'proj');
write(join(OUTSIDE, 'CLAUDE.md'), '<!-- non-dev-harness:v2 -->\n');
const CONFIG_SYS = dir('home', 'cfg-sys'); // 예전 시스템 범용 세팅이 남은 설정 폴더
write(join(CONFIG_SYS, 'CLAUDE.md'), '<!-- non-dev-harness:v1 -->\n');
write(join(CONFIG_SYS, 'MEMORY.md'), '# 전역 — 메모리\n');

function run(stdin, { env = {}, cwd = base, cmd = process.execPath, args = [HOOK] } = {}) {
  const fullEnv = {
    ...process.env,
    HOME,
    USERPROFILE: HOME,
    CLAUDE_CONFIG_DIR: CONFIG_EMPTY,
    CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
    ...env,
  };
  for (const key of Object.keys(fullEnv)) if (fullEnv[key] === undefined) delete fullEnv[key];
  const input = typeof stdin === 'string' ? stdin : JSON.stringify(stdin);
  const r = spawnSync(cmd, args, { input, env: fullEnv, cwd, encoding: 'utf8' });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr };
}

function assertOutput(r, want) {
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stderr, '');
  assert.deepEqual(JSON.parse(r.stdout), want);
}

function assertSilent(r) {
  assert.equal(r.status, 0);
  assert.equal(r.stdout, '');
  assert.equal(r.stderr, '');
}

const start = (cwd) => ({ hook_event_name: 'SessionStart', source: 'startup', cwd });

const tests = [
  ['v2 프로젝트', () => assertOutput(run(start(V2)), expected(MSG, ctx(V2, 'JOURNAL.md')))],
  ['source가 clear여도 동작', () => assertOutput(run({ source: 'clear', cwd: V2 }), expected(MSG, ctx(V2, 'JOURNAL.md')))],
  ['v1 프로젝트', () => assertOutput(run(start(V1)), expected(MSG_V1, ctxV1(V1)))],
  ['v2 표식이어도 JOURNAL.md 없이 하네스 형식 MEMORY.md(— 메모리)만 있으면 v1', () =>
    assertOutput(run(start(V2_MEMORY)), expected(MSG_V1, ctxV1(V2_MEMORY)))],
  ['v2 표식에 사용자가 만든 MEMORY.md만 있으면 v1로 보지 않음', () =>
    assertOutput(run(start(V2_USER_MEMORY)), expected(MSG, ctx(V2_USER_MEMORY, 'JOURNAL.md')))],
  ['하네스 루트가 설정 폴더 자체이거나 그 안이면 프로젝트 안내 없음', () => {
    const env = { CLAUDE_CONFIG_DIR: CONFIG_SYS };
    assertSilent(run(start(CONFIG_SYS), { env }));
    assertSilent(run(start(dir('home', 'cfg-sys', 'projects', 'x')), { env }));
    write(join(CONFIG_SYS, 'inner', 'CLAUDE.md'), '<!-- non-dev-harness:v2 -->\n'); // 설정 폴더 하위의 하네스
    assertSilent(run(start(join(CONFIG_SYS, 'inner')), { env }));
  }],
  ['하위 폴더에서 상위 하네스 찾기', () =>
    assertOutput(run(start(dir('home', 'v2proj', 'a', 'b'))), expected(MSG, ctx(V2, 'JOURNAL.md')))],
  ['BOM과 CRLF가 있는 CLAUDE.md', () => assertOutput(run(start(BOM_CRLF)), expected(MSG, ctx(BOM_CRLF, 'JOURNAL.md')))],
  ['홈 밖 폴더는 루트 쪽으로 계속 찾기', () =>
    assertOutput(run(start(dir('outside', 'proj', 'sub'))), expected(MSG, ctx(OUTSIDE, 'JOURNAL.md')))],
  ['입력에 cwd가 없으면 프로세스 폴더 사용', () =>
    assertOutput(run({ source: 'startup' }, { cwd: V2 }), expected(MSG, ctx(V2, 'JOURNAL.md')))],
  ['하네스 없는 폴더는 출력 없음 (홈에서 멈춤)', () => assertSilent(run(start(PLAIN)))],
  ['홈 자체는 검사하지 않음', () => assertSilent(run(start(HOME)))],
  ['표식이 1행이 아니면 출력 없음', () => assertSilent(run(start(SECOND_LINE)))],
  ['1행이 표식으로 시작하지 않으면 출력 없음', () => assertSilent(run(start(MID_LINE)))],
  ['source가 compact·resume·fork면 출력 없음', () => {
    for (const source of ['compact', 'resume', 'fork']) assertSilent(run({ source, cwd: V2 }));
  }],
  ['잘못된 입력은 출력 없이 종료 코드 0', () => {
    for (const bad of ['', 'not json', 'null', '[]', '"startup"', '{}', '{"cwd":"/x"}']) assertSilent(run(bad));
  }],
  ['v1 설치 흔적만 있음', () =>
    assertOutput(run(start(PLAIN), { env: { CLAUDE_CONFIG_DIR: CONFIG_V1 } }), expected(MSG_INSTALL, ctxInstall(PLUGIN_ROOT)))],
  ['v1 설치 흔적과 v2 프로젝트는 줄바꿈으로 이어 붙임', () =>
    assertOutput(
      run(start(V2), { env: { CLAUDE_CONFIG_DIR: CONFIG_V1 } }),
      expected(`${MSG}\n${MSG_INSTALL}`, `${ctx(V2, 'JOURNAL.md')}\n${ctxInstall(PLUGIN_ROOT)}`),
    )],
  ['설정 폴더 기본값 ~/.claude(안의 v1 표식은 프로젝트로 보지 않음), 플러그인 루트 기본값 스크립트 상위 폴더', () => {
    const home = dir('home-default');
    write(join(home, '.claude', 'plugins', 'non-dev-harness', 'hooks', 'session-start-hint.mjs'));
    write(join(home, '.claude', 'CLAUDE.md'), '<!-- non-dev-harness:v1 -->\n');
    const env = { HOME: home, USERPROFILE: home, CLAUDE_CONFIG_DIR: undefined, CLAUDE_PLUGIN_ROOT: undefined };
    assertOutput(run(start(join(home, '.claude')), { env }), expected(MSG_INSTALL, ctxInstall(REPO)));
  }],
  ['대소문자만 다른 cwd도 홈에서 멈춤 (대소문자 무시 파일시스템에서 의미 있음)', () =>
    assertSilent(run(start(join(dirname(HOME), basename(HOME).toUpperCase(), 'plain'))))],
  ['Git Bash 형식 Windows 경로 변환 (/c/Users → C:\\Users)', () => {
    assert.equal(posixDriveToWin('/c/Users/x/my proj'), 'C:\\Users\\x\\my proj');
    assert.equal(posixDriveToWin('/d'), 'D:\\');
    assert.equal(posixDriveToWin('/c/'), 'C:\\');
    for (const same of ['C:\\Users\\x', '/home/x', '/cygdrive/c/x', 'relative/c']) assert.equal(posixDriveToWin(same), same);
  }],
  ['스크립트에 보이지 않는 BOM 글자가 없음 (정규식은 \\uFEFF 표기)', () => {
    for (const file of [HOOK, join(REPO, 'scripts', 'remove-v1.mjs')]) {
      assert.equal(readFileSync(file, 'utf8').includes(String.fromCharCode(0xfeff)), false, file);
    }
  }],
];

if (process.platform !== 'win32') {
  const command = JSON.parse(readFileSync(join(HOOK_DIR, 'hooks.json'), 'utf8')).hooks.SessionStart[0].hooks[0].command;
  const sh = (env) => run(start(V2), { cmd: '/bin/sh', args: ['-c', command], env: { CLAUDE_PLUGIN_ROOT: REPO, ...env } });
  tests.push(
    ['hooks.json 명령: 공백 있는 경로에서도 실행', () => assertOutput(sh({}), expected(MSG, ctx(V2, 'JOURNAL.md')))],
    ['hooks.json 명령: Node가 없으면 조용히 건너뜀', () => assertSilent(sh({ PATH: dir('empty-path') }))],
    ['심볼릭 링크로 들어온 cwd도 실제 경로로 판단 (홈에서 멈추고, 루트는 실제 경로)', () => {
      const link = join(base, 'link-home');
      symlinkSync(HOME, link);
      assertSilent(run(start(join(link, 'plain'))));
      assertOutput(run(start(join(link, 'v2proj'))), expected(MSG, ctx(V2, 'JOURNAL.md')));
    }],
  );
}

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
