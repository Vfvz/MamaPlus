#!/bin/sh
# Runs every tests/test_*.lua in its own Lua 5.1 interpreter, then luacheck,
# then tools/package.sh --check.
# Usage (from the MamaPlus folder): sh tests/run.sh
set -e
cd "$(dirname "$0")/.."
fail=0
for t in tests/test_*.lua; do
  if lua5.1 -e 'TEST_ADDON_DIR="./"; QUIET=true' -e "dofile('$t')" \
       -e 'if handlerErrors and #handlerErrors > 0 then error(#handlerErrors .. " handler error(s), see above", 0) end' \
       > /tmp/mp_test.log 2>&1; then
    echo "PASS $t"
  else
    echo "FAIL $t"; cat /tmp/mp_test.log; fail=1
  fi
done
if command -v luacheck >/dev/null 2>&1; then
  luacheck --no-color -q . || fail=1
else
  echo "luacheck not installed: skipped"
fi
# Secret values: issecretvalue must be asked before any compare or boolean
# test. A test mock cannot catch the wrong order (a Lua stand-in never
# errors on "== nil"), so look for the pattern in the source instead.
if grep -nE '([A-Za-z_][A-Za-z0-9_.]*)( (==|~=) nil)? (and|or) (not )?(ns\.)?IsSecret\(\1\)' *.lua; then
  echo "FAIL secret check order: ask IsSecret(v) before comparing or testing v (lines above)"
  fail=1
fi
# TOC and folder agree: every TOC file exists, every .lua/.xml is listed.
sh tools/package.sh --check || fail=1
exit $fail
