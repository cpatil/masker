#!/bin/zsh
set -euo pipefail

target_dir="${1:?Masker Presidio support directory is required}"

python_candidates=(
  "${MASKER_PRESIDIO_BASE_PYTHON:-}"
  /usr/local/bin/python3
  /opt/homebrew/bin/python3
  /usr/bin/python3
)

base_python=""
for candidate in "${python_candidates[@]}"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" -c 'import sys; raise SystemExit(0 if (3, 10) <= sys.version_info[:2] < (3, 15) else 1)' 2>/dev/null; then
    base_python="$candidate"
    break
  fi
done

[[ -n "$base_python" ]] || exit 10
mkdir -p "$target_dir"
"$base_python" -m venv "$target_dir/venv"
"$target_dir/venv/bin/python3" -m pip install --disable-pip-version-check --upgrade pip
"$target_dir/venv/bin/python3" -m pip install --disable-pip-version-check 'presidio-analyzer==2.2.364'
"$target_dir/venv/bin/python3" -m spacy download en_core_web_sm
chmod -R go-rwx "$target_dir"
