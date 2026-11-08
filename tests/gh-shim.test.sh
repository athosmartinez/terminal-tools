#!/usr/bin/env bash
# Tests for gh-shim. A fake gh on PATH logs which token it got, so no test
# touches GitHub or a real keyring.
set -uo pipefail

SHIM=$(cd "$(dirname "$0")/.." && pwd -P)/gh-shim
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/real" "$WORK/shims" "$WORK/home"
ln -s "$SHIM" "$WORK/shims/gh"

# Fake gh: "auth token -u <login>" prints token-<login> for known logins;
# any other call prints the token it received in GH_TOKEN.
cat >"$WORK/real/gh" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == auth && $2 == token ]]; then
  while [[ $# -gt 0 ]]; do
    [[ $1 == -u ]] && { case $2 in work-login|home-login) echo "token-$2"; exit 0 ;; esac; exit 1; }
    shift
  done
  exit 1
fi
echo "token=${GH_TOKEN:-<active>} args=$*"
EOF
chmod +x "$WORK/real/gh"

export PATH=$WORK/shims:$WORK/real:$PATH
export HOME=$WORK/home
export GIT_CONFIG_GLOBAL=$WORK/gitconfig GIT_CONFIG_NOSYSTEM=1
export GH_SHIM_CONF=$WORK/gh-shim.conf
unset GH_TOKEN GITHUB_TOKEN GH_ACCOUNT GH_HOST GH_SHIM_REAL

cat >"$GIT_CONFIG_GLOBAL" <<EOF
[credential "https://github.com"]
	username = home-login
[includeIf "hasconfig:remote.*.url:https://github.com/work-org/**"]
	path = $WORK/work.gitconfig
EOF
printf '[credential "https://github.com"]\n\tusername = work-login\n' >"$WORK/work.gitconfig"
printf '# owner login\nwork-org work-login\n' >"$GH_SHIM_CONF"

git init -q "$WORK/work-repo" && git -C "$WORK/work-repo" remote add origin https://github.com/work-org/app.git
git init -q "$WORK/home-repo" && git -C "$WORK/home-repo" remote add origin https://github.com/me/notes.git
mkdir -p "$WORK/plain"

passed=0
failed=0
check() {
  local name=$1 expected=$2 actual=$3
  if [[ $actual == *"$expected"* ]]; then
    echo "ok   $name"
    passed=$((passed + 1))
  else
    echo "FAIL $name: expected '$expected', got '$actual'"
    failed=$((failed + 1))
  fi
}

check "work repo uses the work account" "token=token-work-login args=pr list" \
  "$(cd "$WORK/work-repo" && gh pr list)"
check "personal repo uses the default account" "token=token-home-login" \
  "$(cd "$WORK/home-repo" && gh pr list)"
check "outside a repo uses the active account" "token=<active>" \
  "$(cd "$WORK/plain" && gh api user)"
check "--repo owner from the conf" "token=token-work-login" \
  "$(cd "$WORK/plain" && gh pr view 1 --repo work-org/app)"
check "-R with a URL" "token=token-work-login" \
  "$(cd "$WORK/home-repo" && gh pr view 1 -R https://github.com/work-org/app.git)"
check "--repo=owner/repo form" "token=token-work-login" \
  "$(cd "$WORK/plain" && gh issue list --repo=work-org/app)"
check "gh repo clone owner/repo uses the conf" "token=token-work-login args=repo clone work-org/app dir" \
  "$(cd "$WORK/plain" && gh repo clone work-org/app dir)"
check "gh repo view with a URL uses the conf" "token=token-work-login" \
  "$(cd "$WORK/home-repo" && gh repo view https://github.com/work-org/app)"
check "gh repo create name keeps the repo rule" "token=token-home-login" \
  "$(cd "$WORK/home-repo" && gh repo create notes2 --private)"
check "unknown --repo owner falls back to the active account" "token=<active>" \
  "$(cd "$WORK/work-repo" && gh pr list -R someone/else)"
check "GH_ACCOUNT wins over the repo" "token=token-home-login" \
  "$(cd "$WORK/work-repo" && GH_ACCOUNT=home-login gh pr list)"
check "GH_TOKEN passes through" "token=preset" \
  "$(cd "$WORK/work-repo" && GH_TOKEN=preset gh pr list)"
check "auth commands pass through" "token=<active> args=auth status" \
  "$(cd "$WORK/work-repo" && gh auth status)"
check "other host passes through" "token=<active>" \
  "$(cd "$WORK/work-repo" && GH_HOST=ghe.example.com gh pr list)"
check "arguments with spaces survive" "args=pr create --title a b c" \
  "$(cd "$WORK/work-repo" && gh pr create --title "a b c")"
check "a login that is not in gh fails loudly" "is not logged in" \
  "$(cd "$WORK/work-repo" && GH_ACCOUNT=missing gh pr list 2>&1)"
check "the shim never runs itself" "token=<active>" \
  "$(cd "$WORK/plain" && "$WORK/shims/gh" version)"

echo
echo "$passed passed, $failed failed"
((failed == 0))
