#!/bin/zsh
# usage: watch.sh <wave> <lead-name> ; exits with a reason line in /tmp/iris-mother/watch.out
wave=$1; lead=$2; mkdir -p /tmp/iris-mother; out=/tmp/iris-mother/watch.out
cd ~/SourceRoot/iris
start=$(date +%s); last_head=$(git rev-parse origin/master); last_move=$start
while true; do
  git fetch -q origin master 2>/dev/null
  head=$(git rev-parse origin/master)
  now=$(date +%s)
  [[ $head != $last_head ]] && { last_head=$head; last_move=$now; }
  if git show origin/master:docs/waves/PLAN.md | grep -qE "^## Wave $wave .*status: done"; then echo "DONE wave $wave at $(date)" > $out; exit 0; fi
  agents=$(rd agents 2>&1)
  if echo "$agents" | grep -E "iris|w$wave" | grep -q blocked; then echo "BLOCKED $(date)"$'\n'"$agents" > $out; exit 0; fi
  if ! echo "$agents" | grep -q "$lead"; then echo "LEAD GONE $(date)"$'\n'"$agents" > $out; exit 0; fi
  (( now - last_move > 3600 )) && { echo "STALE master unmoved 60m $(date)"$'\n'"$agents" > $out; exit 0; }
  (( now - start > 5400 )) && { echo "HEARTBEAT 90m $(date) head=$head"$'\n'"$agents" > $out; exit 0; }
  sleep 120
done
