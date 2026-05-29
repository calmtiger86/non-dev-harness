<p align="center">
  <img src="assets/banner.svg" alt="non-dev-harness banner" width="100%">
</p>

<p align="center">
  <a href="https://github.com/calmtiger86/non-dev-harness/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/version-1.0.0-667eea.svg?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/node-%3E%3D16-brightgreen.svg?style=flat-square&logo=node.js&logoColor=white" alt="Node">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey.svg?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/dependencies-0-success.svg?style=flat-square" alt="Zero Dependencies">
  <img src="https://img.shields.io/badge/context-~4KB-764ba2.svg?style=flat-square" alt="Context Size">
</p>

<p align="center">
  <b>Claude Code session manager for non-developers</b><br>
  <sub>Pick up where you left off with 3 commands. No coding needed.</sub>
</p>

<p align="center">
  <a href="./README.md">한국어</a> · 
  <b>English</b>
</p>

<p align="center">
  <a href="#-installation">Install</a> · 
  <a href="#-usage">Usage</a> · 
  <a href="#-workflow">Workflow</a> · 
  <a href="#-token-optimization">Token Optimization</a> · 
  <a href="#-uninstall">Uninstall</a>
</p>

---

## Why?

If you've used Claude Code more than a few times, you know the drill.

You close a session, open a new one, and Claude has no idea what happened yesterday. The three hours you spent working together? Gone. The decision you made about how to structure things? Gone. You end up explaining the same context from scratch, every single time.

Errors are worse. You hit a problem you've already solved before, but Claude doesn't remember the fix. So you both waste time figuring it out again.

And when you're done for the day, you're supposed to commit and push — but if you forget, next time you're starting with "wait, where was I?"

**non-dev-harness turns this into 3 commands.** `/ci` to pick up where you left off, do your work, `/co` to wrap up. Next session, `/ci` tells you exactly what happened last time.

---

## 📦 Installation

### macOS / Linux

```bash
git clone https://github.com/calmtiger86/non-dev-harness.git
cd non-dev-harness
bash install.sh
```

### Windows

```powershell
git clone https://github.com/calmtiger86/non-dev-harness.git
cd non-dev-harness
powershell -File install.ps1
```

> **Restart Claude Code** after installation.

<details>
<summary><b>What gets installed?</b></summary>

```
~/.claude/
├── plugins/non-dev-harness/   ← Plugin core
├── skills/hs/, ci/, co/       ← 3 slash commands
├── rules/common/non-dev-core.md ← Base rules (~800B)
└── settings.json              ← Session hook registered
```

- If anything fails mid-install, all created files are cleaned up
- Existing skills with the same name are left untouched
- settings.json is written to a temp file first, then swapped in (safe even if interrupted)

</details>

---

## 🚀 Usage

<p align="center">
  <img src="assets/screenshot-workflow.svg" alt="Workflow screenshot" width="700">
</p>

### `/hs` — **H**arness **S**etup

Run once when you start a new project.

```
> /hs
```

- Asks a few questions about your project (name, goal, audience)
- Creates 5 context files
- Sets up Git + `.gitignore`
- Generates project-specific rules

### `/ci` — **C**heck **I**n

The first thing you type when a session starts.

```
> /ci
```

- Reads your last session and gives you a summary
- Shows unresolved issues and errors
- Tells you what to do next
- Warns you if the same error keeps showing up

### `/co` — **C**heck **O**ut

Run when you're done for the day (or switching sessions).

```
> /co
```

- Sorts today's work into 5 files
- Writes a TODO list for next time
- Blocks accidental commits of passwords and keys
- Commits to Git and pushes to remote

---

## 📁 Context Files

| File | Think of it as | What it does |
|------|---------------|-------------|
| **CLAUDE.md** | Bulletin board | Project rules. Loaded automatically every session |
| **MEMORY.md** | Work journal | Session history, decisions, TODOs. Keeps last 5 |
| **ERROR.md** | Fix log | Records what broke and how you fixed it |
| **ISSUE.md** | Task list | Open issues and bugs. 3 priority levels |
| **WIKI.md** | Knowledge base | Permanent project knowledge, sorted by category |

---

## 🔄 Workflow

<p align="center">
  <img src="assets/screenshot-flow.svg" alt="Workflow" width="700">
</p>

---

## ⚡ Token Optimization

<p align="center">
  <img src="assets/screenshot-tokens.svg" alt="Token Optimization" width="700">
</p>

Every time you start a session, Claude Code reads your rules and context files. The more it reads, the slower and more expensive things get.

non-dev-harness is designed to **read only what's needed, when it's needed.**

- The only file loaded every session is an 800-byte rules file. Everything else waits until you run `/ci` or `/co`
- Instead of reading entire files, it pulls just the counts and summaries
- Old records are trimmed automatically (5 session logs, 10 errors, 15 issues max)

The result: **~1,150 tokens** per session instead of **~5,000** when explaining everything from scratch. About 78% less.

<details>
<summary><b>Architecture diagram</b></summary>

<p align="center">
  <img src="assets/architecture.svg" alt="Architecture" width="700">
</p>

</details>

---

## 🔒 Safety

- **Secret detection** — Warns before you commit `.env*`, `*.pem`, `*.key` files
- **Install rollback** — If something breaks mid-install, created files are removed
- **Safe config writes** — settings.json is written to a temp file first, then swapped (won't corrupt on crash)
- **Skill protection** — Won't overwrite existing `/hs`, `/ci`, `/co` from other plugins
- **Partial edits** — Only touches the sections that changed, never rewrites whole files

---

## 🗑️ Uninstall

```bash
node ~/.claude/plugins/non-dev-harness/uninstall.js
```

> Your project files (CLAUDE.md, MEMORY.md, etc.) stay where they are.

---

## 📐 Design

Built on patterns from 9 open-source projects:

<details>
<summary><b>See sources</b></summary>

| Project | What we took |
|--------|-----------------|
| [RTK](https://github.com/rtk-ai/rtk) | Summary extraction, hard caps, progressive filtering |
| [revfactory/harness](https://github.com/revfactory/harness) | 7-phase workflow, context pre-check, change history |
| [Karpathy CLAUDE.md](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) | Wiki structure, surface/minimal/surgical/verify principles |
| [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) | 6-part SKILL.md layout, interview pattern |
| [anthropics/claude-md-management](https://github.com/anthropics/claude-plugins-official) | CLAUDE.md quality criteria, include/exclude rules |
| [VoltAgent context-manager](https://github.com/VoltAgent/awesome-claude-code-subagents) | Cache layers, TTL expiry, data lifecycle |
| [VoltAgent error-coordinator](https://github.com/VoltAgent/awesome-claude-code-subagents) | Error tagging, circuit breaker, learning loop |
| [claude-code-best-practice](https://github.com/shanraisshan/claude-code-best-practice) | Context 40% threshold, /compact hints |
| [multica-ai/karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills) | 4 principles (surface assumptions, minimal code, surgical edit, verifiable goals) |

</details>

---

## 🤝 Contributing

Bug reports and suggestions welcome — especially from non-developers.

---

<p align="center">
  <sub>Made with Claude Code · MIT License</sub><br>
  <a href="https://github.com/calmtiger86/non-dev-harness">
    <img src="https://img.shields.io/github/stars/calmtiger86/non-dev-harness?style=social" alt="GitHub Stars">
  </a>
</p>
