#!/bin/sh
#
# release_dirs_test.sh — every release ships the system's directories.
# Each job's runtime tree (.github/workflows/release.yml, its
# "for d in ...; do" copies, and build-dev-bundle.sh's) must carry
# man (the manual), doc (the papers), icons (what Tk programs load),
# appl (the source, and the .sbl files the debugger and profiler read)
# and n (the mount point for /n/local).  Without n, the profile's mount
# of the host's files failed on a fresh install's first start and it
# made the user's home inside the package.  appl is shipped without its
# .dis, which dis/ has.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

fail=0
want="dis lib fonts man doc icons module services locale usr mnt n appl"
lists=$(grep -hE '^[[:space:]]*for d in .*; do' .github/workflows/release.yml build-dev-bundle.sh | sed 's/.*for d in \(.*\); do.*/\1/')
[ -n "$lists" ] || { echo "FAIL: no staging lists found"; exit 1; }
nlists=$(echo "$lists" | wc -l | tr -d ' ')
for d in $want; do
	missing=$(echo "$lists" | while read -r l; do
		case " $l " in (*" $d "*) ;; (*) echo "$l" ;; esac
	done)
	if [ -z "$missing" ]; then
		echo "PASS: /$d is staged by all $nlists runtime copies"
	else
		echo "FAIL: /$d is not staged by: $(echo "$missing" | sort -u | tr "\n" ";")"; fail=1
	fi
done

# each copy of appl drops its .dis
ndrop=$(grep -hcE "find \"[^\"]*/appl\" -name '\*\.dis' -delete" .github/workflows/release.yml build-dev-bundle.sh | awk '{s+=$1} END {print s}')
if [ "$ndrop" = "$nlists" ]; then
	echo "PASS: every copy of appl drops its .dis"
else
	echo "FAIL: $ndrop of $nlists copies of appl drop its .dis"; fail=1
fi

# the Windows packages, whose lists are PowerShell arrays
for f in package-windows-zip.ps1 build-dev-bundle.ps1; do
	for d in man doc icons appl n; do
		if grep -qE "\"$d\"" "$f"; then :; else
			echo "FAIL: $f does not stage $d"; fail=1
		fi
	done
	if grep -q 'Filter \*\.dis' "$f"; then :; else
		echo "FAIL: $f ships appl's .dis"; fail=1
	fi
done
[ $fail = 0 ] && echo "PASS: the Windows packages stage them too"

# each is in the tree to be copied
for d in man doc icons appl n; do
	if [ -d "$d" ]; then :; else
		echo "FAIL: no $d in the tree"; fail=1
	fi
done

[ $fail = 0 ] && echo "ALL PASS"
exit $fail
