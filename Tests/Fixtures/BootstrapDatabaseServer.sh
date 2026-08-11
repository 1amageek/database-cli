#!/bin/sh

if [ "$1" = "--version" ]; then
  printf '26.0812.0\n'
  exit 0
fi

if [ "$1" != "bootstrap" ]; then
  exit 64
fi

payload='{"createdCredential":true,"databaseID":"main","endpoint":"http://127.0.0.1:7878/v1/database","formatVersion":1,"tenantID":null,"token":"bootstrap-secret","workspaceID":null}'
length=${#payload}
if [ "$length" -ge 256 ]; then
  exit 65
fi
octal_length=$(printf '%03o' "$length")
printf '\000\000\000'
printf "\\$octal_length"
printf '%s' "$payload"

acknowledgement=$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
if [ "$acknowledgement" = "1" ]; then
  exit 0
fi
exit 42
