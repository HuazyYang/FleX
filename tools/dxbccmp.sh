#!/usr/bin/env bash
# DXBC equivalence check for one recovered shader.
#
#   tools/dxbccmp.sh <Entry>            # looks the recipe up in Shaders.cfg
#   tools/dxbccmp.sh <Entry> -v         # also prints the register-normalised diff
#
# Compiles the source named in Shaders.cfg with FXC 6.3.9600.16384 -- the compiler
# that produced the shipped blobs -- and compares against src/dxbc/<blob>.asm.
# Prints three numbers:
#   bytes   0 means the SHEX chunk is byte-identical to the shipped blob (the goal)
#   raw     differing disassembly lines, registers included
#   rn      differing lines after register normalisation (structure only)
# Run from the repository root.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
FXC="tools/fxc63/fxc.exe"
[ -x "$FXC" ] || { echo "missing $FXC"; exit 2; }
E="${1:?usage: dxbccmp.sh <Entry> [-v]}"; VERBOSE="${2:-}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ROW="$(grep -E "^\S+[[:space:]]+-T cs -E ${E}( |\$)" src/shaders/Shaders.cfg | head -1)"
[ -n "$ROW" ] || { echo "$E: not in Shaders.cfg"; exit 2; }
SRC="$(echo "$ROW" | awk '{print $1}')"
DEFS="$(echo "$ROW" | grep -oE '\-D ?[A-Za-z0-9_=]+' | sed 's/^-D /-D/' | tr '\n' ' ')"
BLOB=""
for c in "g_Flex_$E" "g_bvh_$E" "g_$(echo "${E:0:1}" | tr a-z A-Z)${E:1}"; do
  [ -f "src/dxbc/$c.asm" ] && BLOB="$c" && break
done
[ -n "$BLOB" ] || { echo "$E: no shipped blob"; exit 2; }
export MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1
if ! "$FXC" -nologo -T cs_5_0 -E "$E" -Iexternal/nvapi/include -Iexternal/ags_lib/hlsl $DEFS \
       -Fh "$(cygpath -w "$T")\o.h" -Fo "$(cygpath -w "$T")\o.bin" "src/shaders/$SRC" >"$T/log" 2>&1; then
  echo "$E: FXC FAILED"; sed -n '1,8p' "$T/log"; exit 1
fi
norm() { tr -d '\r' | sed -n '/^cs_5_0/,/^ret/p' \
  | grep -v '^dcl_' | sed 's/[[:space:]]*$//' | sed -E 's/([0-9]+[.][0-9]{6})[0-9]+/\1/g' \
  | sed -E 's/([0-9]{9})[0-9]+[.][0-9]+/\1./g'; }
norm < "$T/o.h" > "$T/new"; norm < "src/dxbc/$BLOB.asm" > "$T/old"
rn() { sed -E 's/\br[0-9]+\.[xyzw]+/R/g; s/\br[0-9]+\b/R/g' "$1"; }
rn "$T/new" > "$T/new.rn"; rn "$T/old" > "$T/old.rn"
RAW=$(diff "$T/old" "$T/new" | grep -c '^[<>]')
RN=$(diff "$T/old.rn" "$T/new.rn" | grep -c '^[<>]')
# MSYS2_ARG_CONV_EXCL is set for FXC above, so paths must be converted by hand here.
BYTES=$(python "$(cygpath -w "$ROOT/tools/shexcmp.py")" "$(cygpath -w "$ROOT/src/dxbc/$BLOB.txt")" "$(cygpath -w "$T/o.bin")") || BYTES="?"
# Instruction counts and the index of the first differing instruction. `bytes` is a
# positional compare, so it saturates once instruction counts shift and is only
# meaningful as a pass/fail at 0; firstdiff is the number to watch while iterating.
IS=$(grep -cvE '^$' "$T/old"); IO=$(grep -cvE '^$' "$T/new")
FD=$(diff --unchanged-line-format='' --old-line-format='%dn
' --new-line-format='' "$T/old" "$T/new" 2>/dev/null | head -1)
[ -n "${FD:-}" ] || FD=none
if [ "$BYTES" = "0" ]; then VERDICT=PASS; else VERDICT=----; fi
printf '%-40s %s  raw=%-5s rn=%-5s firstdiff=%-6s instr=%s/%s  (%s)
' "$E" "$VERDICT" "$RAW" "$RN" "$FD" "$IS" "$IO" "$SRC"
if [ "$VERBOSE" = "-v" ]; then
  echo "--- register-normalised diff (< shipped, > ours) ---"
  diff "$T/old.rn" "$T/new.rn"
  echo "--- raw diff (< shipped, > ours) ---"
  diff "$T/old" "$T/new"
fi
[ "$BYTES" = "0" ]
