#!/usr/bin/env zsh
emulate -L zsh
set -u
setopt pipefail

root=${0:A:h:h}
comp=$root/completions/_icloud-keychain
failed=0
passed=0

fail() {
    print -u2 "FAIL: $1"
    failed=$((failed + 1))
}

pass() {
    passed=$((passed + 1))
}

zsh -n -- $comp || { print -u2 'zsh -n failed'; exit 1 }
pass 'syntax'

if grep -n -- "awk -F ' / '" $comp; then
    fail 'still parses human list output with awk'
else
    pass 'no awk'
fi
if grep -n -- 'compadd -Q' $comp; then
    fail 'compadd -Q disables quoting'
else
    pass 'no -Q'
fi
if grep -E -- '\$\{\(@f\)' $comp; then
    fail 'must not split NUL records on newlines with (@f)'
else
    pass 'no (@f) split'
fi

tmp=$(mktemp -d)
trap 'rm -rf -- $tmp' EXIT
path_bin=$tmp/icloud-keychain
argv_log=$tmp/argv
cat > $path_bin <<EOF
#!/bin/sh
printf '%s\0' "\$@" > "$argv_log"
if [ "\$1" != list ]; then
  echo "helpers must not complete secrets; got: \$*" >&2
  exit 2
fi
shift
names=0
accounts=0
nul=0
exact=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --names-only) names=1 ;;
    --accounts-only) accounts=1 ;;
    --null) nul=1 ;;
    --local|--sync) ;;
    --scope) shift ;;
    --scope=*) ;;
    --)
      shift
      exact="\$1"
      break
      ;;
    --*)
      echo "unexpected flag \$1" >&2
      exit 2
      ;;
    *)
      exact="\$1"
      ;;
  esac
  shift
done
if [ "\$nul" -ne 1 ]; then
  echo "mock requires --null" >&2
  exit 2
fi
if [ "\$names" -eq 1 ]; then
  printf 'dotfiles/github-token\0dotfiles/a b:c/d\0dotfiles/with / delim\0dotfiles/new\nline\0system.wifi\0'
  exit 0
fi
if [ "\$accounts" -eq 1 ]; then
  if [ "\$exact" = "dotfiles/a b:c/d" ] || [ "\$exact" = "dotfiles/new
line" ]; then
    printf 'piotr rojek\0acc / delim\0new\nacc\0'
    exit 0
  fi
  if [ -n "\$exact" ]; then
    exit 0
  fi
  printf 'piotr rojek\0'
  exit 0
fi
echo "unexpected invocation" >&2
exit 2
EOF
chmod +x $path_bin
PATH=$tmp:$PATH

sed '$d' $comp > $tmp/comp.zsh
source $tmp/comp.zsh

typeset -a COMPADD_OPTS COMPADD_WORDS
compadd() {
    COMPADD_OPTS=()
    COMPADD_WORDS=()
    while (( $# )); do
        case $1 in
            --) shift; break ;;
            -*) COMPADD_OPTS+=("$1"); shift ;;
            *) break ;;
        esac
    done
    COMPADD_WORDS=("$@")
}

contains() {
    local needle=$1
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

typeset -A opt_args
opt_args=()
COMPADD_WORDS=()
__icloud_keychain_services
logged=("${(@0)$(cat $argv_log)}")

if [[ "${logged[1]}" == list ]]; then pass 'default argv starts with list'; else fail "argv[1]=${logged[1]-}"; fi
if contains --names-only "$logged[@]"; then pass 'default --names-only'; else fail 'missing --names-only'; fi
if contains --null "$logged[@]"; then pass 'default --null'; else fail 'missing --null'; fi
if contains --local "$logged[@]" || contains --sync "$logged[@]" || contains --scope "$logged[@]"; then
    fail 'default must not force a scope'
else
    pass 'default no forced scope'
fi
if contains -- -Q "$COMPADD_OPTS[@]" || contains -Q "$COMPADD_OPTS[@]"; then
    fail 'compadd used -Q'
else
    pass 'compadd quoting enabled'
fi
if contains 'dotfiles/github-token' "$COMPADD_WORDS[@]"; then pass 'plain service'; else fail 'missing github-token'; fi
if contains 'dotfiles/a b:c/d' "$COMPADD_WORDS[@]"; then pass 'space colon slash'; else fail 'missing space/colon service'; fi
if contains 'dotfiles/with / delim' "$COMPADD_WORDS[@]"; then pass 'literal / delim'; else fail 'missing / delim service'; fi
nl=$'dotfiles/new\nline'
if contains "$nl" "$COMPADD_WORDS[@]"; then pass 'newline remains one candidate'; else fail 'newline service split'; fi
if contains 'system.wifi' "$COMPADD_WORDS[@]"; then fail 'system entry offered'; else pass 'system entries filtered'; fi

opt_args=(--local '')
COMPADD_WORDS=()
__icloud_keychain_services
logged=("${(@0)$(cat $argv_log)}")
if contains --local "$logged[@]"; then pass 'explicit --local forwarded'; else fail 'missing --local'; fi
if contains --sync "$logged[@]" || contains --scope "$logged[@]"; then fail 'local also forwarded other scope'; else pass 'local exclusive'; fi

opt_args=(--sync '')
COMPADD_WORDS=()
__icloud_keychain_services
logged=("${(@0)$(cat $argv_log)}")
if contains --sync "$logged[@]"; then pass 'explicit --sync forwarded'; else fail 'missing --sync'; fi

opt_args=(--scope icloud)
COMPADD_WORDS=()
__icloud_keychain_services
logged=("${(@0)$(cat $argv_log)}")
if contains --scope "$logged[@]" && contains icloud "$logged[@]"; then
    pass 'explicit --scope icloud forwarded'
else
    fail "scope argv: ${logged[*]}"
fi

opt_args=()
COMPADD_WORDS=()
__icloud_keychain_accounts 'dotfiles/a b:c/d'
logged=("${(@0)$(cat $argv_log)}")
if contains --accounts-only "$logged[@]"; then pass 'accounts-only'; else fail 'missing --accounts-only'; fi
if contains -- "$logged[@]"; then pass 'exact service after --'; else fail 'missing -- before service'; fi
if contains 'piotr rojek' "$COMPADD_WORDS[@]"; then pass 'account with space'; else fail 'missing spaced account'; fi
if contains 'acc / delim' "$COMPADD_WORDS[@]"; then pass 'account with / delim'; else fail 'missing / account'; fi
accnl=$'new\nacc'
if contains "$accnl" "$COMPADD_WORDS[@]"; then pass 'newline account one candidate'; else fail 'newline account split'; fi
if contains -Q "$COMPADD_OPTS[@]"; then fail 'accounts used -Q'; else pass 'accounts quoting enabled'; fi

opt_args=(--local '')
COMPADD_WORDS=()
__icloud_keychain_accounts $'dotfiles/new\nline'
logged=("${(@0)$(cat $argv_log)}")
if contains --local "$logged[@]"; then pass 'accounts forwards --local'; else fail 'accounts missing --local'; fi
if contains -- "$logged[@]"; then pass 'newline service after --'; else fail 'accounts missing --'; fi
if contains "$accnl" "$COMPADD_WORDS[@]"; then pass 'accounts for newline service'; else fail 'accounts not exact-matched'; fi

if (( failed )); then
    print -u2 "completions: $passed passed, $failed failed"
    exit 1
fi
print "ok: $passed/$passed"
