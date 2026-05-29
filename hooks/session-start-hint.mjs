#!/usr/bin/env node
import { readFileSync, existsSync, openSync, readSync, closeSync } from 'fs';
import { join } from 'path';

const MARKER_PREFIX = '<!-- non-dev-harness:';

function out(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

let cwd = process.cwd();
try {
  const raw = readFileSync(0, 'utf-8');
  const input = JSON.parse(raw);
  if (input.cwd) cwd = input.cwd;
} catch {
  // stdin may be empty or unavailable — fall back to process.cwd()
}

const projectClaudeMd = join(cwd, 'CLAUDE.md');
let hasMarker = false;
let hasClaudeMd = false;

if (existsSync(projectClaudeMd)) {
  hasClaudeMd = true;
  try {
    const fd = openSync(projectClaudeMd, 'r');
    const buf = Buffer.alloc(512);
    readSync(fd, buf, 0, 512, 0);
    closeSync(fd);
    hasMarker = buf.toString().includes(MARKER_PREFIX);
  } catch {
    // file exists but unreadable — emit no hint (safer than wrong hint)
  }
}

let hint = '';
if (hasMarker) {
  hint = '[non-dev-harness] /ci 로 체크인하세요.';
} else if (!hasClaudeMd) {
  hint = '[non-dev-harness] /hs 로 프로젝트를 세팅하세요.';
}

const result = { hookSpecificOutput: { hookEventName: 'SessionStart' } };
if (hint) {
  result.hookSpecificOutput.additionalContext = hint;
}

out(result);
