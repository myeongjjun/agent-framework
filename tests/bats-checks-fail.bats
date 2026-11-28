#!/usr/bin/env bats
# Guards the suite itself. Under `set -e`, bash skips a failed `! cmd` on every
# version, and bash 3.2 (macOS /bin/bash) also skips a failed `[[ ]]` or `(( ))`,
# unless it is the test's last command. Such a check never fails its test.
# Every such check that is not the last line of its test MUST end in `|| false`.

@test "every [[ ]], (( )) and ! check that is not a test's last line ends in || false" {
  run python3 -I - "$BATS_TEST_DIRNAME"/*.bats <<'PY'
import re, sys
START = re.compile(r'^\s*(\[\[|\(\(|! )')
bad = []
for f in sys.argv[1:]:
    lines = open(f, encoding='utf-8').read().split('\n')
    i = 0
    while i < len(lines):
        if re.match(r'^(@test\b.*|[\w:-]+\s*\(\)\s*|function\s+\S+.*)\{\s*$', lines[i]):
            j = i + 1
            while j < len(lines) and not re.match(r'^\}\s*$', lines[j]):
                j += 1
            body = [k for k in range(i + 1, j)
                    if lines[k].strip() and not lines[k].strip().startswith('#')]
            last = body[-1] if body else None
            k = i + 1
            while k < j:
                if START.match(lines[k]):
                    e = k
                    while lines[e].rstrip().endswith('\\'):
                        e += 1
                    text = ' '.join(lines[k:e + 1])
                    tail = text[text.rfind(']]'):] if text.lstrip().startswith('[[') else text
                    if e != last and '||' not in tail:
                        bad.append('%s:%d: %s' % (f, k + 1, lines[k].strip()))
                    k = e
                k += 1
            i = j
        i += 1
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY
  [ "$status" -eq 0 ]
}
