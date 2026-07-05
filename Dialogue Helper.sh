#!/bin/sh
printf '\033c\033]0;%s\a' Dialogue Helper
base_path="$(dirname "$(realpath "$0")")"
"$base_path/Dialogue Helper.x86_64" "$@"
