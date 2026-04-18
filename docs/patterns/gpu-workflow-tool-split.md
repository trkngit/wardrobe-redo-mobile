# Pattern: GPU Workflow Tool Split

**Problem.** A GPU training workflow touches ~8 different surfaces: a cloud provider's web UI (pod deploy), SSH (bootstrap), long-running remote processes (training), log streams (monitoring), file transfer (scp), your local repo (commits + pushes), a browser (API docs, dashboards), and sometimes a native app (CloudWatch, a terminal emulator). Using one tool for all of them is either slow (screenshot-driven computer-use) or brittle (shell alone can't click Deploy buttons on a web dashboard).

**Solution.** Map each surface to the tool class that's fastest and most reliable for it. Each tier trades speed/precision against coverage.

---

## The tool tiers

### Tier 1 — Dedicated API MCPs

If the target has an official MCP server (GitHub, Supabase, Linear, Slack, Gmail…), use it. API-backed tools are fast and structured. No DOM parsing, no pixel matching.

**Use for:** git operations via gh, database queries, chat, ticket updates.

### Tier 2 — Chrome MCP (`mcp__claude-in-chrome__*`)

Web apps that don't have a dedicated MCP but where you're already logged in via Chrome. DOM-aware clicks are much faster and more reliable than pixel-based computer-use.

**Use for:** cloud provider dashboards (RunPod, Lambda Labs, Vast.ai, AWS console), HuggingFace, Kaggle, any authenticated web workflow.

**Don't use for:** shell commands (use Bash), file system operations (use Bash), text you want to feed into a local process.

### Tier 3 — Bash (built-in)

Local shell for everything shell-shaped. SSH into remote machines, scp files, git, pip, pytest, heredoc scripts.

**Use for:** pod bootstrap, remote training launch (inside `ssh root@pod 'tmux new-session -d -s train "..."'`), scp of artifacts, local git operations, running the probe.

### Tier 4 — Monitor tool

Long-running log tails where you want to be notified when a specific pattern appears. Works well with grep filters over SSH.

**Use for:** watching `tail -f /root/train.log | grep -E "Epoch |mAP|Traceback|Error|CUDA out of memory|NaN|Killed"`. The tool streams and notifies you when new lines appear so you don't have to poll.

### Tier 5 — Computer-use

Native desktop apps (macOS Terminal, Finder, Activity Monitor, a local GUI debugger). Slowest and most brittle but the only option for apps without a better tier.

**Use for:** anything that isn't a browser and isn't shell-accessible. Avoid whenever possible.

---

## Worked example: RunPod training run

| Step | Tool tier | Why |
|---|---|---|
| Find a GPU SKU & price | Tier 2 (Chrome MCP) | RunPod dashboard in browser; DOM-aware Deploy button click is reliable |
| Copy the pod's SSH command | Tier 2 (Chrome MCP) | Same page; read the text content |
| SSH into the pod | Tier 3 (Bash) | One-shot SSH command; Bash handles this natively |
| Clone repo, install deps, run probe | Tier 3 (Bash + heredoc) | `ssh root@pod 'bash -s' <<'EOF' ... EOF` is one round-trip |
| Launch long training detached | Tier 3 (Bash + tmux) | `ssh root@pod 'tmux new-session -d -s train "..."'` survives SSH drops |
| Watch training progress | Tier 4 (Monitor) | Grep-filtered tail; notifies on epoch/error signatures |
| scp the .mlpackage back | Tier 3 (Bash) | Single scp command |
| Stop/Terminate the pod | Tier 2 (Chrome MCP) | UI click; no good SSH command equivalent |
| Commit the artifact | Tier 3 (Bash + git) | Local shell |

No Tier 5 computer-use anywhere. Every step maps to a tool class that's right for it.

---

## Fallback rules

- **Tier 2 fails (Chrome extension not connected, JS broken, weird iframe):** ask the user to install the extension, or fall back to Tier 5. Don't try to run shell-like tasks in the browser.
- **Tier 3 SSH auth fails:** fall back to the provider's web terminal via Tier 2. Same commands, slower but reliable.
- **Tier 4 silence:** if the Monitor grep hasn't matched in N minutes, SSH in and check directly with Bash — silence might mean the process died before printing anything matching the filter.

## Anti-patterns

- **Don't screenshot-drive a web app you could Chrome-MCP.** Pixel-matching a button is 10× slower and breaks on theme changes.
- **Don't Bash-loop instead of Monitor.** Polling `ssh pod tail log` in a Bash `until` loop uses context on every iteration. Monitor only wakes you up when the pattern matches.
- **Don't use computer-use for anything shell-shaped.** If you can type it, Bash can run it.
- **Don't foreground a long-running SSH-inside-tmux command.** Launch detached and poll with Monitor; that way a dropped session doesn't kill the run.
- **Don't compose a Tier 5 action out of Tier 2 actions you wouldn't trust individually.** If you wouldn't trust a single pixel click, stringing 10 of them together doesn't help.

## The "look before you assert" rule

Before claiming an app can't do something, take a screenshot or read the DOM. Don't answer from memory — the user's version or setup may differ from what you expect. Cheaper to verify than to be wrong.

## Source

This split was the tool plan for the 2026-04-18 RunPod training session in the Wardrobe Re-Do project. It's project-agnostic — swap "RunPod" for any cloud GPU provider and the pattern holds.
