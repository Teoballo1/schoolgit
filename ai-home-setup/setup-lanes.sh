#!/usr/bin/env bash
# Sets up ~/AI-Home with separate Claude Code accounts ("lanes").
#
#   bash setup-lanes.sh                    # creates lane1 lane2 lane3
#   bash setup-lanes.sh lane4              # adds more lanes later
#   AI_HOME=~/somewhere bash setup-lanes.sh
#
# Safe to run again: it never deletes logins, chats or settings.
set -euo pipefail

AI_HOME="${AI_HOME:-$HOME/AI-Home}"
if [ "$#" -gt 0 ]; then LANES=("$@"); else LANES=(lane1 lane2 lane3); fi

for lane in "${LANES[@]}"; do
  case "$lane" in
    [A-Za-z_]*) ;;
    *) echo "Lane names must start with a letter: $lane" >&2; exit 1 ;;
  esac
  case "$lane" in
    *[!A-Za-z0-9_]*) echo "Lane names may only use letters, numbers and _: $lane" >&2; exit 1 ;;
  esac
done

command -v python3 >/dev/null || { echo "python3 is required (sudo dnf install python3)" >&2; exit 1; }

mkdir -p "$AI_HOME/.tools" "$AI_HOME/.accounts"
chmod 700 "$AI_HOME/.accounts"   # holds login tokens

# ---------------------------------------------------------------------------
# Chat saver: turns Claude Code's .jsonl transcripts into readable Markdown.
# ---------------------------------------------------------------------------
cat > "$AI_HOME/.tools/save_chat.py" <<'PYEOF'
#!/usr/bin/env python3
"""Turn Claude Code transcripts (.jsonl) into readable Markdown files.

As a hook (reads the hook's JSON on stdin, saves that one chat):
    save_chat.py --out DIR
Backfill every chat stored in an account's config folder:
    save_chat.py --out DIR --all CONFIG_DIR
"""
import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime

MAX_OUTPUT_LINES = 40
MAX_OUTPUT_CHARS = 4000


def parse_time(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
    except (AttributeError, ValueError):
        return None


def clean_user_text(text):
    """Strip Claude Code's internal markup from a user message."""
    text = re.sub(r"<system-reminder>.*?</system-reminder>", "", text, flags=re.S)
    if "<local-command-caveat>" in text:
        return ""
    cmd = re.search(r"<command-name>(.*?)</command-name>", text, re.S)
    if cmd:
        args = re.search(r"<command-args>(.*?)</command-args>", text, re.S)
        line = cmd.group(1).strip()
        if args and args.group(1).strip():
            line += " " + args.group(1).strip()
        return f"*Ran `{line}`*"
    out = re.search(r"<local-command-stdout>(.*?)</local-command-stdout>", text, re.S)
    if out:
        body = out.group(1).strip()
        return details("command output", body) if body else ""
    return text.strip()


def truncate(text):
    lines = text.splitlines()
    cut = False
    if len(lines) > MAX_OUTPUT_LINES:
        lines, cut = lines[:MAX_OUTPUT_LINES], True
    text = "\n".join(lines)
    if len(text) > MAX_OUTPUT_CHARS:
        text, cut = text[:MAX_OUTPUT_CHARS], True
    return text + ("\n… (cut)" if cut else "")


def fence(text, lang=""):
    ticks = "```"
    while ticks in text:
        ticks += "`"
    return f"{ticks}{lang}\n{text}\n{ticks}"


def details(summary, body, lang=""):
    return f"<details><summary>{summary}</summary>\n\n{fence(truncate(body), lang)}\n\n</details>"


def demote(text):
    """Push Markdown headings down two levels so they nest under You/Claude."""
    lines, in_code = [], False
    for line in text.splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            in_code = not in_code
        elif not in_code and re.match(r"#{1,4} ", line):
            line = "##" + line
        lines.append(line)
    return "\n".join(lines)


def thinking(text):
    """Claude's thinking, folded away so the chat stays easy to read."""
    return f"<details><summary>💭 Thinking</summary>\n\n{demote(text)}\n\n</details>"


def block_text(content):
    if isinstance(content, str):
        return content
    parts = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            parts.append(b.get("text", ""))
        elif isinstance(b, dict) and b.get("type") == "image":
            parts.append("[image]")
    return "\n".join(parts)


def tool_call(block):
    name = block.get("name", "tool")
    inp = block.get("input") or {}
    if name == "Bash" and isinstance(inp.get("command"), str):
        head = f"**🔧 {name}**" + (f" — {inp['description']}" if inp.get("description") else "")
        return head + "\n\n" + fence(truncate(inp["command"]), "bash")
    for key in ("file_path", "path", "pattern", "url", "query", "description", "prompt"):
        if isinstance(inp.get(key), str):
            val = inp[key].strip().splitlines()[0] if inp[key].strip() else ""
            if len(val) > 150:
                val = val[:150] + "…"
            return f"**🔧 {name}** `{val}`"
    return f"**🔧 {name}**"


def load(path):
    entries = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except ValueError:
                pass  # half-written line while the chat is still going
    return entries


def render(entries):
    """Returns (title, first_time, markdown) or None if the chat is empty."""
    out, speaker, title, first, last, sid, cwd = [], None, None, None, None, None, None
    tool_names = {}

    for e in entries:
        kind = e.get("type")
        if kind not in ("user", "assistant") or e.get("isSidechain") or e.get("isMeta"):
            continue
        msg = e.get("message") or {}
        content = msg.get("content")
        when = parse_time(e.get("timestamp", ""))
        sid = sid or e.get("sessionId")
        cwd = cwd or e.get("cwd")

        if kind == "user":
            if e.get("isCompactSummary"):
                out.append("\n" + details("— earlier part of the chat was summarized —", block_text(content)))
                continue
            blocks = content if isinstance(content, list) else [{"type": "text", "text": content or ""}]
            texts, results = [], []
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_result":
                    label = tool_names.get(b.get("tool_use_id"), "tool") + " output"
                    if b.get("is_error"):
                        label += " (error)"
                    body = block_text(b.get("content")).strip()
                    if body:
                        results.append(details(label, body))
                elif b.get("type") in ("text", "image"):
                    t = clean_user_text(block_text([b]))
                    if t:
                        texts.append(t)
            out.extend("\n" + r for r in results)
            if texts:
                text = "\n\n".join(texts)
                if title is None and not text.startswith(("*Ran", "<details>", "[Request interrupted")):
                    title = text
                    first = first or when
                stamp = f" · {when:%H:%M}" if when else ""
                out.append(f"\n## 🧑 You{stamp}\n\n{demote(text)}")
                speaker = "user"
                last = when or last
        else:
            blocks = content if isinstance(content, list) else [{"type": "text", "text": content or ""}]
            parts = []
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "thinking" and b.get("thinking", "").strip():
                    parts.append(thinking(b["thinking"].strip()))
                elif b.get("type") == "text" and b.get("text", "").strip():
                    parts.append(demote(b["text"].strip()))
                elif b.get("type") == "tool_use":
                    tool_names[b.get("id")] = b.get("name", "tool")
                    parts.append(tool_call(b))
            if not parts:
                continue
            if speaker != "claude":
                stamp = f" · {when:%H:%M}" if when else ""
                out.append(f"\n## 🤖 Claude{stamp}")
                speaker = "claude"
            out.append("\n" + "\n\n".join(parts))
            last = when or last

    if title is None:
        return None
    one_line = " ".join(title.split())
    short = one_line[:80] + ("…" if len(one_line) > 80 else "")
    header = [f"# {short}", ""]
    if first:
        header.append(f"- **Started:** {first:%Y-%m-%d %H:%M}")
    if last:
        header.append(f"- **Last message:** {last:%Y-%m-%d %H:%M}")
    if cwd:
        header.append(f"- **Folder:** `{cwd}`")
    if sid:
        header.append(f"- **Continue it:** `claude --resume {sid}`")
    header += ["", "---"]
    return one_line, first, "\n".join(header + out) + "\n"


def slug(text):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:40].rstrip("-") or "chat"


def save(transcript, out_dir):
    entries = load(transcript)
    result = render(entries)
    if result is None:
        return None
    title, first, md = result
    sid = os.path.splitext(os.path.basename(transcript))[0]
    os.makedirs(out_dir, exist_ok=True)
    existing = glob.glob(os.path.join(glob.escape(out_dir), f"*_{sid[:8]}.md"))
    if existing:
        path = existing[0]
    else:
        stamp = f"{first:%Y-%m-%d_%H%M}" if first else "undated"
        path = os.path.join(out_dir, f"{stamp}_{slug(title)}_{sid[:8]}.md")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(md)
    os.replace(tmp, path)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="folder to write .md files into")
    ap.add_argument("--all", metavar="CONFIG_DIR", help="convert every chat in this account's config folder")
    args = ap.parse_args()

    if args.all:
        count = 0
        for t in sorted(glob.glob(os.path.join(glob.escape(args.all), "projects", "*", "*.jsonl"))):
            if save(t, args.out):
                count += 1
        print(f"Saved {count} chat(s) to {args.out}")
        return

    # Hook mode: never block or break Claude Code, whatever happens.
    try:
        data = json.load(sys.stdin)
        transcript = data.get("transcript_path")
        if transcript and os.path.exists(transcript):
            save(transcript, args.out)
    except Exception as exc:  # noqa: BLE001
        print(f"save_chat: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
PYEOF
chmod +x "$AI_HOME/.tools/save_chat.py"

# ---------------------------------------------------------------------------
# Shell commands (loaded from ~/.bashrc).
# ---------------------------------------------------------------------------
{
  printf '# AI-Home lanes: separate Claude Code accounts. Made by setup-lanes.sh.\n'
  printf 'export AI_HOME="${AI_HOME:-%s}"\n' "$AI_HOME"
  cat <<'SHEOF'

# Prints the lane for the current folder, if it is inside $AI_HOME/<lane>.
_lane_here() {
  local rel lane
  case "$PWD" in
    "$AI_HOME"/*) rel="${PWD#"$AI_HOME"/}"; lane="${rel%%/*}" ;;
    *) return 1 ;;
  esac
  [ -n "$lane" ] && [ -d "$AI_HOME/.accounts/$lane" ] || return 1
  printf '%s\n' "$lane"
}

# _lane_run <lane> [claude args...]
_lane_run() {
  local lane="$1"; shift
  if [ ! -d "$AI_HOME/.accounts/$lane" ]; then
    echo "No lane called '$lane'. Lanes: $(ls "$AI_HOME/.accounts" | tr '\n' ' ')" >&2
    return 1
  fi
  CLAUDE_CONFIG_DIR="$AI_HOME/.accounts/$lane" command claude "$@"
}

# Inside ~/AI-Home/<lane>, plain `claude` uses that lane's account.
claude() {
  local lane
  if [ -z "${CLAUDE_CONFIG_DIR:-}" ] && lane="$(_lane_here)"; then
    _lane_run "$lane" "$@"
  else
    command claude "$@"
  fi
}

# lane1, lane2, ... : use that account from any folder.
for _lane_dir in "$AI_HOME"/.accounts/*/; do
  [ -d "$_lane_dir" ] || continue
  _lane_name="$(basename "$_lane_dir")"
  case "$_lane_name" in
    [A-Za-z_]*) case "$_lane_name" in *[!A-Za-z0-9_]*) continue ;; esac ;;
    *) continue ;;
  esac
  eval "$_lane_name() { _lane_run $_lane_name \"\$@\"; }"
done
unset _lane_dir _lane_name

# lanes : list lanes and which account each is logged into.
lanes() {
  local d lane here email
  here="$(_lane_here 2>/dev/null || true)"
  for d in "$AI_HOME"/.accounts/*/; do
    [ -d "$d" ] || continue
    lane="$(basename "$d")"
    email="$(python3 - "$d" <<'PY' 2>/dev/null
import json, os, sys
for name in (".claude.json", "config.json"):
    p = os.path.join(sys.argv[1], name)
    try:
        acct = json.load(open(p)).get("oauthAccount") or {}
    except (OSError, ValueError):
        continue
    if acct.get("emailAddress"):
        print(acct["emailAddress"]); break
PY
)"
    printf '%s %-8s %s\n' "$([ "$lane" = "$here" ] && echo '*' || echo ' ')" "$lane" \
      "${email:-(not logged in yet, or run /status inside to check)}"
  done
}

# lane-chats [lane] : open a lane's saved chats folder.
lane-chats() {
  local lane="${1:-$(_lane_here 2>/dev/null)}"
  if [ -z "$lane" ]; then echo "Usage: lane-chats lane1" >&2; return 1; fi
  mkdir -p "$AI_HOME/$lane/chats"
  if command -v xdg-open >/dev/null; then xdg-open "$AI_HOME/$lane/chats" >/dev/null 2>&1 &
  else echo "$AI_HOME/$lane/chats"; fi
}

# lane-save-all : re-save every stored chat of every lane as Markdown.
lane-save-all() {
  local d lane
  for d in "$AI_HOME"/.accounts/*/; do
    [ -d "$d" ] || continue
    lane="$(basename "$d")"
    printf '%s: ' "$lane"
    python3 "$AI_HOME/.tools/save_chat.py" --out "$AI_HOME/$lane/chats" --all "$d"
  done
}
SHEOF
} > "$AI_HOME/.tools/lanes.sh"

# ---------------------------------------------------------------------------
# Per-lane folders and account settings.
# ---------------------------------------------------------------------------
for lane in "${LANES[@]}"; do
  mkdir -p "$AI_HOME/$lane/chats" "$AI_HOME/.accounts/$lane"
  python3 - "$AI_HOME/.accounts/$lane/settings.json" "$AI_HOME/.tools/save_chat.py" "$AI_HOME/$lane/chats" <<'PY'
import json, os, shlex, sys
settings_path, script, chats = sys.argv[1:]
try:
    with open(settings_path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}

command = f"python3 {shlex.quote(script)} --out {shlex.quote(chats)}"
hooks = settings.setdefault("hooks", {})
for event in ("Stop", "SessionEnd"):
    groups = hooks.setdefault(event, [])
    already = any(h.get("command", "").find("save_chat.py") != -1
                  for g in groups for h in g.get("hooks", []))
    if not already:
        groups.append({"hooks": [{"type": "command", "command": command, "timeout": 30}]})

# Keep the raw transcripts (used by --resume) for 10 years instead of 30 days.
settings.setdefault("cleanupPeriodDays", 3650)

tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, settings_path)
PY
done

# ---------------------------------------------------------------------------
# README for the folder.
# ---------------------------------------------------------------------------
cat > "$AI_HOME/README.md" <<'MDEOF'
# AI-Home

Each `laneN` folder is tied to its own Claude Code account.

| What | How |
|---|---|
| Use a lane's account in its folder | `cd ~/AI-Home/lane1` then `claude` |
| Use a lane's account from anywhere | `lane1` (or `lane2`, `lane3`) |
| See which account each lane uses | `lanes` |
| Continue an older chat | `lane1 --resume` (pick from the list) or `claude --continue` in the folder |
| Read saved chats | `~/AI-Home/lane1/chats/` or run `lane-chats lane1` |
| Re-save every chat (e.g. after an update) | `lane-save-all` |
| Save the current chat by hand, right now | type `/export` inside Claude |
| Add another lane | `bash setup-lanes.sh lane4` |

Chats are saved automatically as Markdown after every reply, into the
`chats` folder of the lane whose account you used. Claude's thinking is
included as a folded "💭 Thinking" section whenever Claude Code recorded it. Open them in VS Code
and press `Ctrl+Shift+V` for a nicely formatted preview.

Logins live in `~/AI-Home/.accounts/` - don't share or upload that folder.
MDEOF

# ---------------------------------------------------------------------------
# Hook into the shell.
# ---------------------------------------------------------------------------
MARK="# AI-Home Claude lanes"
LINE="[ -f \"$AI_HOME/.tools/lanes.sh\" ] && . \"$AI_HOME/.tools/lanes.sh\""
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ "$rc" = "$HOME/.bashrc" ] || [ -f "$rc" ]; then
    touch "$rc"
    grep -qF "$MARK" "$rc" || printf '\n%s\n%s\n' "$MARK" "$LINE" >> "$rc"
  fi
done

cat <<EOF

Done! Set up in $AI_HOME:
$(for l in "${LANES[@]}"; do echo "  $l/   (account files in .accounts/$l)"; done)

Next steps:
  1. Open a NEW terminal (or run: source ~/.bashrc)
  2. Log each lane into its account, one at a time:
       cd "$AI_HOME/${LANES[0]}" && claude      # sign in, then /exit
     ...and the same for the other lanes.
     Tip: if the browser auto-logs you into the wrong account, copy the
     login link Claude prints into a private window instead.
  3. Run 'lanes' to check which account each lane uses.

Chats save themselves as Markdown in each lane's chats/ folder.
EOF
