#!/bin/sh

if [ "$1" = "--version" ]; then
  printf '0.0.0\n'
  exit 0
fi

exit 64
