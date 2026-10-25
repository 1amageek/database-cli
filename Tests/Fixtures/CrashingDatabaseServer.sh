#!/bin/sh

if [ "$1" = "--version" ]; then
  printf '26.1026.0\n'
  exit 0
fi

exit 23
