#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2023.
# SPDX-License-Identifier: Apache-2.0
# Modified in 2026.

is_fn() {
	declare -F -- "$1" >/dev/null
}

header() {
	local title=" 🔆🔆🔆  $*  🔆🔆🔆 "
	local width=40 line

	if ((${#title} > width)); then
		width=${#title}
	fi
	printf -v line '%*s' "$width" ''
	printf '\n\n  \033[1m%s\033[0m\n━━━━━%s━━━━━━━\n' "$title" "${line// /━}" >&2
}

info() {
	printf ' 🔔 %s\n' "$*" >&2
}

ok() {
	printf '   ✅ %s\n' "$*" >&2
}

die() {
	printf 'STOP: %s\n' "$*" >&2
	exit 1
}
