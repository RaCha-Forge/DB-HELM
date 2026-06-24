#!/bin/bash

REDIS_HOST="localhost"
REDIS_PORT="6001"
PREFIX="loadtest"
REDIS_PASSWORD="qwertyuiop"


END_TIME=$((SECONDS + 120))

REDIS_CLI="redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASSWORD --no-auth-warning"

echo "Starting load test for 2 minutes..."

while [ $SECONDS -lt $END_TIME ]; do
    TS="ts:${PREFIX}:$RANDOM"

    $REDIS_CLI TS.CREATE "$TS" RETENTION 60000 >/dev/null 2>&1

    for i in $(seq 1 100); do
        $REDIS_CLI TS.ADD "$TS" '*' $((RANDOM % 1000)) >/dev/null 2>&1
    done

    NOW=$(($(date +%s) * 1000))
    FROM=$((NOW - 30000))

    $REDIS_CLI TS.DEL "$TS" "$FROM" "$NOW" >/dev/null 2>&1

    sleep 0.5
done

echo "Deleting all test series..."

$REDIS_CLI --scan --pattern "ts:${PREFIX}:*" | while read key
do
    $REDIS_CLI DEL "$key" >/dev/null
done

echo "Done."
