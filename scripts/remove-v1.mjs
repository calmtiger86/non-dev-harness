#!/usr/bin/env node
// 예전 설치기(v1)가 설정 폴더에 남긴 non-dev-harness 파일을 정리한다.
// 인자 없이 실행하면 미리보기만 하고, --apply 를 붙이면 백업한 뒤 정리한다.
import {
  existsSync, readFileSync, writeFileSync, renameSync, rmSync, mkdirSync,
  cpSync, copyFileSync, realpathSync, statSync, unlinkSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const HOOK_PATH_PART = 'plugins/non-dev-harness/hooks/session-start-hint.mjs';
const SKILL_OWNER_MARK = 'non-dev-harness:';
const RULE_FIRST_LINE = '# Non-Dev Harness';
const MARKER_V1 = '<!-- non-dev-harness:v1 -->';
const RESTART_MSG = 'Claude Code를 다시 시작하세요. 그래야 /ci가 새 플러그인을 가리킵니다.';

const apply = process.argv.slice(2).includes('--apply');
const configDir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');

const readText = (file) => readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
const isV1Hook = (h) => !!h && typeof h.command === 'string' && h.command.replace(/\\/g, '/').includes(HOOK_PATH_PART);

function timestamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  // 같은 초에 다시 실행해도 이름이 겹치지 않게 밀리초까지 붙인다
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}-${String(d.getMilliseconds()).padStart(3, '0')}`;
}

// 지울 대상(targets)과 건드리지 않는 것(skipped)을 모은다. 이 단계는 아무것도 바꾸지 않는다.
function collect() {
  const targets = [];
  const skipped = [];

  for (const name of ['hs', 'ci', 'co']) {
    const dir = join(configDir, 'skills', name);
    if (!existsSync(dir)) continue;
    let owned = false;
    try { owned = readText(join(dir, 'SKILL.md')).includes(SKILL_OWNER_MARK); } catch { /* SKILL.md 없음 */ }
    if (owned) targets.push({ kind: 'path', path: dir, label: `/${name} 스킬 폴더` });
    else skipped.push(`${dir}: 다른 스킬이라 건드리지 않음`);
  }

  const rule = join(configDir, 'rules', 'common', 'non-dev-core.md');
  if (existsSync(rule)) {
    let firstLine = null;
    try { firstLine = readText(rule).split(/\r?\n/)[0].trimEnd(); } catch { /* 읽기 실패 */ }
    if (firstLine === RULE_FIRST_LINE) targets.push({ kind: 'path', path: rule, label: '규칙 파일' });
    else skipped.push(`${rule}: 첫 줄이 "${RULE_FIRST_LINE}"가 아니라 건드리지 않음`);
  }

  // 예전 /hs의 "시스템 범용" 세팅은 설정 폴더 CLAUDE.md에 표식을 남겼다. 사용자 내용이 섞여 있을 수 있어 알리기만 한다.
  const globalClaudeMd = join(configDir, 'CLAUDE.md');
  let globalFirstLine = '';
  try { globalFirstLine = readText(globalClaudeMd).split(/\r?\n/)[0]; } catch { /* 없거나 읽기 실패 */ }
  if (globalFirstLine.startsWith(MARKER_V1)) {
    skipped.push(`${globalClaudeMd}: 첫 줄에 v1 표식이 있습니다. 예전 시스템 범용 세팅의 흔적이라 지우지 않습니다. 이 파일은 직접 확인하세요`);
  }

  // settings.json을 읽지 못하면 그 안에 남은 v1 훅이 가리키는 옛 플러그인 폴더도 남긴다 (훅 오류 줄 방지)
  const settingsPath = join(configDir, 'settings.json');
  let settingsTarget = null;
  let settingsBroken = false;
  if (existsSync(settingsPath)) {
    let settings;
    try {
      settings = JSON.parse(readText(settingsPath));
    } catch (err) {
      settingsBroken = true;
      skipped.push(`${settingsPath}: settings.json을 읽지 못해(JSON 오류: ${err.message}) settings.json과 옛 플러그인 폴더는 그대로 둡니다. settings.json을 고친 뒤 다시 실행하세요`);
    }
    const groups = settings && settings.hooks && settings.hooks.SessionStart;
    if (Array.isArray(groups)) {
      let removed = 0;
      const kept = [];
      for (const group of groups) {
        if (!group || !Array.isArray(group.hooks)) { kept.push(group); continue; }
        const hooks = group.hooks.filter((h) => !isV1Hook(h));
        removed += group.hooks.length - hooks.length;
        if (hooks.length === group.hooks.length) kept.push(group);
        else if (hooks.length > 0) kept.push({ ...group, hooks });
      }
      if (removed > 0) {
        const { SessionStart: _removed, ...otherEvents } = settings.hooks;
        const hooks = kept.length > 0 ? { ...settings.hooks, SessionStart: kept } : otherEvents; // 비게 된 SessionStart 키는 지운다
        const next = { ...settings, hooks };
        settingsTarget = { kind: 'settings', path: settingsPath, next, label: `settings.json의 SessionStart 훅 ${removed}개` };
      }
    }
  }

  const pluginDir = join(configDir, 'plugins', 'non-dev-harness');
  if (existsSync(pluginDir)) {
    if (!existsSync(join(pluginDir, 'hooks', 'session-start-hint.mjs'))) {
      skipped.push(`${pluginDir}: v1 훅 파일이 없어 건드리지 않음`);
    } else if (settingsBroken) {
      skipped.push(`${pluginDir}: settings.json을 읽지 못해 옛 플러그인 폴더도 그대로 둡니다`);
    } else {
      targets.push({ kind: 'path', path: pluginDir, label: 'v1 플러그인 폴더' });
    }
  }
  if (settingsTarget) targets.push(settingsTarget);

  return { targets, skipped };
}

function backup(targets, backupDir) {
  mkdirSync(dirname(backupDir), { recursive: true });
  mkdirSync(backupDir); // 같은 이름이 이미 있으면 실패시켜 덮어쓰지 않는다
  for (const t of targets) {
    const dest = join(backupDir, relative(configDir, t.path));
    mkdirSync(dirname(dest), { recursive: true });
    if (t.kind === 'settings') copyFileSync(t.path, dest); // 심볼릭 링크면 실제 내용이 복사된다
    else cpSync(t.path, dest, { recursive: true, dereference: true });
  }
}

function writeSettings(t) {
  const real = realpathSync(t.path);
  const tmp = join(dirname(real), `.settings.json.non-dev-harness-${process.pid}.tmp`);
  try {
    writeFileSync(tmp, JSON.stringify(t.next, null, 2) + '\n', { mode: statSync(real).mode & 0o777 });
    renameSync(tmp, real);
  } catch (err) {
    try { unlinkSync(tmp); } catch { /* 임시 파일이 없으면 무시 */ }
    throw err;
  }
}

function main() {
  const { targets, skipped } = collect();
  console.log(`non-dev-harness v1 정리 — ${apply ? '실행' : '미리보기 (아무것도 바꾸지 않습니다)'}`);
  console.log(`설정 폴더: ${configDir}\n`);
  if (skipped.length) {
    console.log('건드리지 않는 것:');
    for (const s of skipped) console.log(`  - ${s}`);
    console.log('');
  }
  if (targets.length === 0) {
    console.log('정리할 v1 흔적이 없습니다.');
    return 0;
  }
  console.log(apply ? '정리할 것:' : '--apply 로 실행하면 백업한 뒤 정리할 것:');
  for (const t of targets) console.log(`  - ${t.label}: ${t.path}`);
  console.log('');

  if (!apply) {
    console.log(`실제로 정리하려면: node "${fileURLToPath(import.meta.url)}" --apply`);
    return 0;
  }

  const backupDir = join(configDir, 'backups', `non-dev-harness-v1-${timestamp()}`);
  try {
    backup(targets, backupDir);
  } catch (err) {
    console.error(`백업에 실패해서 아무것도 지우지 않았습니다: ${err.message}`);
    console.error(`만들다 만 백업 폴더가 남아 있을 수 있습니다: ${backupDir} (원본은 그대로이니 필요 없으면 지워도 됩니다)`);
    return 1;
  }
  console.log(`백업 위치: ${backupDir}`);

  // settings.json을 먼저 고친다. 실패하면 훅 파일을 남겨 두어 세션 시작 때 오류가 나지 않게 한다.
  const settingsTarget = targets.find((t) => t.kind === 'settings');
  if (settingsTarget) {
    try {
      writeSettings(settingsTarget);
      console.log(`  ✓ ${settingsTarget.label} 제거`);
    } catch (err) {
      console.error(`settings.json을 고치지 못해 나머지도 지우지 않았습니다: ${err.message}`);
      return 1;
    }
  }

  let failed = 0;
  for (const t of targets.filter((x) => x.kind === 'path')) {
    try {
      rmSync(t.path, { recursive: true });
      console.log(`  ✓ ${t.label} 삭제`);
    } catch (err) {
      failed += 1;
      console.error(`  ✗ ${t.label} 삭제 실패: ${err.message}`);
    }
  }
  console.log(`\n${RESTART_MSG}`);
  return failed ? 1 : 0;
}

try {
  process.exitCode = main();
} catch (err) {
  console.error(`예상하지 못한 오류로 멈췄습니다: ${err.message}`);
  process.exitCode = 1;
}
