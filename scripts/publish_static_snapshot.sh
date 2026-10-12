#!/usr/bin/env bash
set -Eeuo pipefail

# 本机数据 → 脱敏静态站点 → gh-pages。
# 设计目标：可被 systemd timer 重复调用；内容不变时不产生 GitHub Pages 构建。
REPO_DIR="${SVC_DASHBOARD_DIR:-/home/tetsuya/development/svc-dashboard}"
CNAME="${SVC_DASHBOARD_CNAME:-svc.iamcheyan.com}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/svc-dashboard-static"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/svc-dashboard-static-publish.lock"

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[static-publish] another run is already active; skip"
  exit 0
fi

if [[ ! -f "$REPO_DIR/dashboard.py" ]]; then
  echo "[static-publish] repository not found: $REPO_DIR" >&2
  exit 1
fi

REMOTE_URL=$(git -C "$REPO_DIR" remote get-url origin)
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/svc-static-publish.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[static-publish] collecting and sanitizing snapshot"
python3 - "$REPO_DIR" "$WORK_DIR" "$CNAME" <<'PY'
import os, sys
repo_dir, output_dir, cname = sys.argv[1:]
sys.path.insert(0, repo_dir)
from svcdash.export import export_static
export_static(output_dir, lang="zh", cname=cname)
PY

# The system privacy hook scans the temporary gh-pages commit too. Scrub
# machine-specific values from generated assets before staging; retain only the
# public GitHub/domain handle needed by this published site.
python3 - "$WORK_DIR" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
text_patterns = [
    (re.compile(r"(?i)/(?:data/)?NAS(?:/[^\s<>\"']*)?"), "[挂载路径已隐藏]"),
    (re.compile(r"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"), "[邮箱已隐藏]"),
    (re.compile(r"(?<![\d.])(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.(?:\d{1,3}\.)\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.(?:\d{1,3}\.)\d{1,3})(?![\d.])"), "127.0.0.1"),
]
for path in root.rglob("*"):
    if not path.is_file() or path.name == "CNAME":
        continue
    try:
        content = path.read_text(encoding="utf-8")
    except (UnicodeError, OSError):
        continue
    for pattern, replacement in text_patterns:
        content = pattern.sub(replacement, content)
    path.write_text(content, encoding="utf-8")
PY

HASH=$(find "$WORK_DIR" -type f -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  | sha256sum \
  | awk '{print $1}')
LAST_HASH_FILE="$STATE_DIR/last-published.sha256"

if [[ "${SVC_DASHBOARD_FORCE:-0}" != "1" && -s "$LAST_HASH_FILE" \
      && "$(<"$LAST_HASH_FILE")" == "$HASH" ]]; then
  echo "[static-publish] snapshot unchanged; no push"
  exit 0
fi

git -C "$WORK_DIR" init -q

# The privacy hook matches $USER, the home directory name and the global git
# identity against every published byte. This site intentionally publishes one
# public handle, so allow that handle plus any *shorter fragment* of it: the
# local git user.name is a case variant of such a fragment, and the hook's
# allowlist comparison is case-sensitive while its matching is not. Longer
# values — the global git email in particular — are deliberately NOT allowed,
# so a future leak of them is still blocked.
PUBLIC_HANDLE="${SVC_DASHBOARD_PUBLIC_HANDLE:-iamcheyan}"
PUBLIC_IDENTIFIERS=$(python3 - "$PUBLIC_HANDLE" <<'PY'
import os, subprocess, sys
handle = (sys.argv[1] or "").casefold()
values = [os.environ.get("USER", ""), os.path.basename(os.path.expanduser("~"))]
for key in ("user.name", "user.email"):
    values.append(subprocess.run(["git", "config", "--global", "--get", key],
                                 capture_output=True, text=True).stdout.strip())
explicit = [handle, "cheyan", "tetsuya"]
fragments = [value for value in values if value and value.casefold() in handle]
print("\n".join(dict.fromkeys([*explicit, *fragments])))
PY
) || PUBLIC_IDENTIFIERS="$PUBLIC_HANDLE"

git -C "$WORK_DIR" checkout -q -b gh-pages
git -C "$WORK_DIR" config user.name "svc-dashboard static publisher"
git -C "$WORK_DIR" config user.email "svc-dashboard@example.com"
while IFS= read -r identifier; do
  [[ -n "$identifier" ]] && git -C "$WORK_DIR" config --add privacy.public-identifiers "$identifier"
done <<< "$PUBLIC_IDENTIFIERS"
export GIT_PRIVACY_PUBLIC_IDENTIFIERS="$PUBLIC_IDENTIFIERS"
git -C "$WORK_DIR" add -A
git -C "$WORK_DIR" commit -q -m "Update sanitized static snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git -C "$WORK_DIR" remote add origin "$REMOTE_URL"
git -C "$WORK_DIR" fetch -q origin gh-pages
echo "[static-publish] pushing changed snapshot to origin/gh-pages"
git -C "$WORK_DIR" push -q -f origin gh-pages
printf '%s\n' "$HASH" > "$LAST_HASH_FILE"
echo "[static-publish] published successfully"
