#!/usr/bin/env node
// SessionStart 훅: 하네스 프로젝트이거나 v1 설치 흔적이 있을 때만 짧은 안내를 낸다.
// 해당 없음, 잘못된 입력, 어떤 예외에도 아무것도 출력하지 않고 종료 코드 0으로 끝낸다.
import { readFileSync, existsSync, openSync, readSync, closeSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const MARKER_PREFIX = '<!-- non-dev-harness:';
const MARKER_V1 = '<!-- non-dev-harness:v1 -->';
const HEAD_BYTES = 512;

const PROJECT_MSG = 'non-dev-harness: 지난 작업을 이어받으려면 /ci, 마칠 때는 /co 를 입력하세요.';
const PROJECT_V1_MSG = ' 이 프로젝트의 기록 파일은 옛 형식(v1)이라 /hs 로 새 형식으로 바꿀 수 있어요.';
const V1_INSTALL_MSG = 'non-dev-harness: 예전 방식(v1)으로 설치된 파일이 남아 있습니다. Claude에게 "non-dev-harness v1 정리해줘"라고 말하면 정리합니다.';

function samePath(a, b) {
  return process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
}

function firstLine(file) {
  let fd;
  try {
    fd = openSync(file, 'r');
    const buf = Buffer.alloc(HEAD_BYTES);
    const n = readSync(fd, buf, 0, HEAD_BYTES, 0);
    return buf.toString('utf8', 0, n).replace(/^﻿/, '').split(/\r?\n/)[0];
  } catch {
    return null;
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch { /* 닫기 실패는 무시 */ }
    }
  }
}

// 현재 폴더부터 위로 올라가며 1행에 표식이 있는 CLAUDE.md를 찾는다. 홈에 닿으면 홈은 검사하지 않고 멈춘다.
function findHarness(start, home) {
  let dir = resolve(start);
  for (;;) {
    if (samePath(dir, home)) return null;
    const line = firstLine(join(dir, 'CLAUDE.md'));
    if (line !== null && line.startsWith(MARKER_PREFIX)) return { root: dir, line };
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function main() {
  let input;
  try {
    input = JSON.parse(readFileSync(0, 'utf8'));
  } catch {
    return;
  }
  if (!input || typeof input !== 'object' || Array.isArray(input)) return;
  if (input.source !== 'startup' && input.source !== 'clear') return;

  const cwd = typeof input.cwd === 'string' && input.cwd ? input.cwd : process.cwd();
  const messages = [];
  const contexts = [];

  const found = findHarness(cwd, resolve(homedir()));
  if (found) {
    const hasJournal = existsSync(join(found.root, 'JOURNAL.md'));
    const hasMemory = existsSync(join(found.root, 'MEMORY.md'));
    const isV1 = found.line.startsWith(MARKER_V1) || (!hasJournal && hasMemory);
    const journal = hasJournal ? 'JOURNAL.md' : (hasMemory || isV1) ? 'MEMORY.md' : 'JOURNAL.md';
    const context = `이 폴더는 non-dev-harness 프로젝트입니다(하네스 루트: ${found.root}). 기록 파일은 CLAUDE.md, ${journal}, ERROR.md, ISSUE.md, WIKI.md입니다. 사용자는 보통 /ci로 지난 작업을 이어받고 /co로 기록을 남깁니다.`;
    messages.push(isV1 ? PROJECT_MSG + PROJECT_V1_MSG : PROJECT_MSG);
    contexts.push(isV1 ? `${context} 기록 파일이 v1 형식입니다.` : context);
  }

  const configDir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
  if (existsSync(join(configDir, 'plugins', 'non-dev-harness', 'hooks', 'session-start-hint.mjs'))) {
    const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT || dirname(dirname(fileURLToPath(import.meta.url)));
    messages.push(V1_INSTALL_MSG);
    contexts.push(`예전 설치(v1) 흔적이 있습니다. 정리 도구는 node "${join(pluginRoot, 'scripts', 'remove-v1.mjs')}" 이며, 인자 없이 실행하면 미리보기만 하고 --apply 를 붙이면 백업 뒤 정리합니다.`);
  }

  if (messages.length === 0) return;
  process.stdout.write(JSON.stringify({
    systemMessage: messages.join('\n'),
    hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: contexts.join('\n') },
  }) + '\n');
}

process.stdout.on('error', () => {});
try {
  main();
} catch {
  // 안내는 부가 기능이라 실패해도 세션 시작을 막지 않는다.
}
process.exitCode = 0;
