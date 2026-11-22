#!/bin/sh
#
# wpt-fetch.sh DIR - web-platform-tests at the commit tools/ref/wpt-commit
# names, only the directories tools/ref/wpt-suites and tools/ref/wpt-paths
# list, into DIR.
#
# The commit is fetched by its hash and git checks every object it
# checks out against its hash, so DIR holds exactly that commit's files:
# the pin is the check.  Fetched again into a DIR that has it, nothing
# is downloaded.  About 200 MB.
#
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DIR=${1:?usage: wpt-fetch.sh DIR}
URL=${WPT_URL:-https://github.com/web-platform-tests/wpt.git}
SHA=$(tr -d ' \n' < "$ROOT/tools/ref/wpt-commit")
case "$SHA" in
*[!0-9a-f]*|"") echo "wpt-fetch: tools/ref/wpt-commit is not a commit hash" >&2; exit 1 ;;
esac
[ ${#SHA} -eq 40 ] || { echo "wpt-fetch: tools/ref/wpt-commit is not a whole commit hash" >&2; exit 1; }

mkdir -p "$DIR"
cd "$DIR"
[ -d .git ] || git init -q
git config core.sparseCheckout true
cat "$ROOT/tools/ref/wpt-suites" "$ROOT/tools/ref/wpt-paths" | grep -v '^#' | grep -v '^$' |
	sed 's|^|/|; s|$|/|' > .git/info/sparse-checkout
if [ "$(git rev-parse -q --verify HEAD 2>/dev/null || true)" != "$SHA" ]; then
	git fetch -q --depth 1 --filter=blob:none "$URL" "$SHA"
	git -c advice.detachedHead=false checkout -q "$SHA"
else
	git read-tree -mu HEAD	# the paths may have changed
fi
[ "$(git rev-parse HEAD)" = "$SHA" ] || { echo "wpt-fetch: checked out $(git rev-parse HEAD), not $SHA" >&2; exit 1; }
echo "wpt $SHA in $DIR"
