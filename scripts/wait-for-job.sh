#!/usr/bin/env bash
#
# Polls a Job until it reaches Complete or Failed.
#
# `kubectl wait --for=condition=complete` only resolves when the Complete
# condition becomes true. A Job that fails gets condition=Failed instead, so
# the wait never resolves early on failure — it just sits until the full
# --timeout expires, no matter how fast the underlying test actually failed.
# Incident 05 hit exactly this: a 20-second smoke test took ~2m15s to
# surface because the wait had to run out its clock before reporting fail.
#
# This polls both conditions directly and returns as soon as either is true.
#
# Usage: wait-for-job.sh <job-name> <namespace> <timeout-seconds> [interval-seconds]

set -euo pipefail

JOB="$1"
NS="$2"
TIMEOUT="${3:-120}"
INTERVAL="${4:-5}"
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  COMPLETE=$(kubectl get job "$JOB" -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
  FAILED=$(kubectl get job "$JOB" -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)

  if [ "$COMPLETE" = "True" ]; then
    echo "job/$JOB reached Complete after ~${ELAPSED}s"
    exit 0
  fi

  if [ "$FAILED" = "True" ]; then
    echo "job/$JOB reached Failed after ~${ELAPSED}s"
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "job/$JOB did not reach Complete or Failed within ${TIMEOUT}s"
exit 1
