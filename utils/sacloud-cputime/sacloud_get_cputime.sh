#!/bin/sh

set -eo pipefail

if [ -z "$SACLOUD_ACCESS_TOKEN" ]; then
  echo >&2 '$SACLOUD_ACCESS_TOKEN is not set. Please set $SACLOUD_ACCESS_TOKEN'
  exit 1
fi

if [ -z "$SACLOUD_ACCESS_TOKEN_SECRET" ]; then
  echo >&2 '$SACLOUD_ACCESS_TOKEN_SECRET is not set. Please set $SACLOUD_ACCESS_TOKEN_SECRET'
  exit 1
fi

if [ -z "$SACLOUD_REGION" ]; then
  SACLOUD_REGION="is1a"
fi

API_ROOT="https://secure.sakura.ad.jp/cloud/zone/$SACLOUD_REGION/api/cloud/1.1"
START=`date -d '5 min ago' +"%FT%T%z"`
END=$START

curl -sSfk --user "$SACLOUD_ACCESS_TOKEN":"$SACLOUD_ACCESS_TOKEN_SECRET" \
  "$API_ROOT/server/$1/monitor?\{\"Start\":\"$START\",\"End\":\"$END\"\}" | \
  jq "if .Data[][] == null then 0 else .Data[][] end"
