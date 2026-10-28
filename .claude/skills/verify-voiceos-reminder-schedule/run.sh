#!/usr/bin/env bash
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION=1.7.4
SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
JAR="$DIR/tools/tla2tools-$VERSION.jar"

if [ ! -f "$JAR" ]; then
  mkdir -p "$DIR/tools"
  TMP=$(mktemp "$DIR/tools/tla2tools.XXXXXX.jar")
  echo "run: downloading TLA+ tools v$VERSION"
  curl -fL --retry 3 --retry-delay 1 --max-time 900 \
    -o "$TMP" "https://github.com/tlaplus/tlaplus/releases/download/v$VERSION/tla2tools.jar"
  ACTUAL=$(shasum -a 256 "$TMP" | awk '{print $1}')
  if [ "$ACTUAL" != "$SHA256" ]; then
    rm -f "$TMP"
    echo "run: tla2tools.jar checksum mismatch: $ACTUAL" >&2
    exit 1
  fi
  mv "$TMP" "$JAR"
fi

run_tlc() {
  java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -cleanup -nowarning -workers auto "$@"
}

if [ "${1:-}" = "--broken" ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  for MODE in resend confirm observed preflight; do
    case "$MODE" in
      resend) INVARIANT=AtMostOneWrite; FILE=BrokenResend ;;
      confirm) INVARIANT=ConfirmedSound; FILE=BrokenConfirm ;;
      observed) INVARIANT=ObservedSound; FILE=BrokenObserved ;;
      preflight) INVARIANT=PreflightConflictNoWrite; FILE=BrokenPreflight ;;
    esac
    python3 "$DIR/spec/broken/make_broken.py" "$MODE" "$TMP/$FILE.tla"
    cat > "$TMP/$FILE.cfg" <<EOF
SPECIFICATION Spec
CONSTANTS
  BaseDue = 1
  DesiredDue = 2
  ManualDue = 3
INVARIANTS
  $INVARIANT
EOF
    set +e
    OUTPUT=$(cd "$TMP" && run_tlc -config "$FILE.cfg" "$FILE.tla" 2>&1)
    STATUS=$?
    set -e
    echo "$OUTPUT" | grep -E "Invariant|states generated|No error" | tail -3
    if [ "$STATUS" -eq 0 ] || ! grep -q "Invariant $INVARIANT is violated" <<<"$OUTPUT"; then
      echo "broken[$MODE]: expected $INVARIANT to fail, but it did not" >&2
      exit 1
    fi
    echo "broken[$MODE]: $INVARIANT violated as expected"
  done
  exit 0
fi

cd "$DIR/spec"
run_tlc -config ReminderSchedule.cfg ReminderSchedule.tla
