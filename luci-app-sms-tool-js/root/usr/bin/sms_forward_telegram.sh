#!/bin/sh
#
# Copyright 2026 Rafał Wabik (IceG) - From eko.one.pl forum
# Extended for Telegram auto-forwarding.
# Licensed to the GNU General Public License v3.0.
#

STATE_FILE="/tmp/sms_forward_telegram.sent"
TMP_RAW="/tmp/sms_forward_telegram.raw"
TMP_MSGS="/tmp/sms_forward_telegram.msgs"
TMP_SORTED="/tmp/sms_forward_telegram.sorted"
TMP_MERGED="/tmp/sms_forward_telegram.merged"

is_enabled() {
	[ "$(uci -q get sms_tool_js.@sms_tool_js[0].forward_sms_telegram_enabled)" = "1" ]
}

escape_markdown_v2() {
	echo "$1" | sed -e 's/\\/\\\\/g' \
		-e 's/_/\\_/g' -e 's/*/\\*/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' \
		-e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/~/\\~/g' -e 's/`/\\`/g' \
		-e 's/>/\\>/g' -e 's/#/\\#/g' -e 's/+/\\+/g' -e 's/-/\\-/g' \
		-e 's/=/\\=/g' -e 's/|/\\|/g' -e 's/{/\\{/g' -e 's/}/\\}/g' \
		-e 's/\./\\./g' -e 's/!/\\!/g'
}

send_telegram() {
	local text="$1"
	local token chat_id parse_mode timeout response

	token="$(uci -q get sms_tool_js.@sms_tool_js[0].forward_sms_telegram_bot_token)"
	chat_id="$(uci -q get sms_tool_js.@sms_tool_js[0].forward_sms_telegram_chat_id)"
	parse_mode="$(uci -q get sms_tool_js.@sms_tool_js[0].forward_sms_telegram_parse_mode)"
	timeout="$(uci -q get sms_tool_js.@sms_tool_js[0].forward_sms_telegram_timeout)"

	[ -z "$timeout" ] && timeout="15"
	[ -z "$token" ] && return 1
	[ -z "$chat_id" ] && return 1

	if [ "$parse_mode" = "MarkdownV2" ]; then
		text="$(escape_markdown_v2 "$text")"
	fi

	if [ "$parse_mode" = "none" ] || [ -z "$parse_mode" ]; then
		response="$(curl -sS --max-time "$timeout" \
			-X POST "https://api.telegram.org/bot${token}/sendMessage" \
			--data-urlencode "chat_id=${chat_id}" \
			--data-urlencode "text=${text}" 2>/dev/null)"
	else
		response="$(curl -sS --max-time "$timeout" \
			-X POST "https://api.telegram.org/bot${token}/sendMessage" \
			--data-urlencode "chat_id=${chat_id}" \
			--data-urlencode "text=${text}" \
			--data-urlencode "parse_mode=${parse_mode}" 2>/dev/null)"
	fi

	echo "$response" | grep -q '"ok":true'
}

normalize_json() {
	awk '
	BEGIN { started=0 }
	{
		if (!started) {
			p = index($0, "[")
			if (p > 0) {
				started = 1
				line = substr($0, p)
				print line
				if (index(line, "]") > 0)
					exit
			}
		} else {
			print
			if (index($0, "]") > 0)
				exit
		}
	}' "$TMP_RAW"
}

is_index_sent() {
	local idx="$1"
	[ -f "$STATE_FILE" ] || return 1
	grep -qx "$idx" "$STATE_FILE"
}

mark_index_sent() {
	local idx="$1"
	[ -z "$idx" ] && return 0
	[ -f "$STATE_FILE" ] || touch "$STATE_FILE"
	if ! grep -qx "$idx" "$STATE_FILE"; then
		echo "$idx" >> "$STATE_FILE"
	fi
}

mark_indexes_sent() {
	local ids="$1"
	local one
	for one in $(echo "$ids" | tr ',' ' '); do
		mark_index_sent "$one"
	done
}

all_indexes_sent() {
	local ids="$1"
	local one
	for one in $(echo "$ids" | tr ',' ' '); do
		[ -z "$one" ] && continue
		if ! is_index_sent "$one"; then
			return 1
		fi
	done
	return 0
}

build_messages() {
	local mem dev json mergesms algo direction

	mem="$(uci -q get sms_tool_js.@sms_tool_js[0].storage)"
	dev="$(uci -q get sms_tool_js.@sms_tool_js[0].readport)"
	mergesms="$(uci -q get sms_tool_js.@sms_tool_js[0].mergesms)"
	algo="$(uci -q get sms_tool_js.@sms_tool_js[0].algorithm)"
	direction="$(uci -q get sms_tool_js.@sms_tool_js[0].direction)"

	[ -z "$mem" ] && mem="SM"
	[ -z "$dev" ] && return 1

	sms_tool -s "$mem" -d "$dev" -f '%Y-%m-%d %H:%M' -j recv 2>/dev/null > "$TMP_RAW"
	json="$(normalize_json)"
	[ -z "$json" ] && return 1

	: > "$TMP_MSGS"

	local i sender timestamp part total index content
	i=0
	while :; do
		sender="$(jsonfilter -s "$json" -e "@[$i].sender")"
		[ -z "$sender" ] && break
		timestamp="$(jsonfilter -s "$json" -e "@[$i].timestamp")"
		part="$(jsonfilter -s "$json" -e "@[$i].part")"
		total="$(jsonfilter -s "$json" -e "@[$i].total")"
		index="$(jsonfilter -s "$json" -e "@[$i].index")"
		content="$(jsonfilter -s "$json" -e "@[$i].content")"

		[ -z "$part" ] && part="0"
		[ -z "$total" ] && total="0"
		content="$(echo "$content" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g')"

		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sender" "$timestamp" "$part" "$total" "$index" "$content" >> "$TMP_MSGS"
		i=$((i + 1))
	done

	[ -s "$TMP_MSGS" ] || return 1

	if [ "$mergesms" = "1" ]; then
		if [ "$algo" = "Advanced" ] && [ "$direction" = "End" ]; then
			sort -t $'\t' -k2,2r -k1,1 -k3,3nr "$TMP_MSGS" > "$TMP_SORTED"
		else
			sort -t $'\t' -k2,2r -k1,1 -k3,3n "$TMP_MSGS" > "$TMP_SORTED"
		fi

		awk -F'\t' '
		BEGIN { OFS="\t" }
		{
			sender=$1; ts=$2; total=$4; idx=$5; content=$6
			if (total != "" && total != "0")
				key = sender "|" ts "|" total
			else
				key = sender "|" ts "|" idx

			if (!(key in seen)) {
				seen[key]=1
				s[key]=sender
				t[key]=ts
				ids[key]=idx
				msg[key]=content
				ord[++n]=key
			} else {
				ids[key]=ids[key] "," idx
				msg[key]=msg[key] " " content
			}
		}
		END {
			for (i=1; i<=n; i++) {
				k=ord[i]
				printf "%s\t%s\t%s\t%s\n", s[k], t[k], ids[k], msg[k]
			}
		}' "$TMP_SORTED" > "$TMP_MERGED"
	else
		sort -t $'\t' -k2,2r "$TMP_MSGS" | awk -F'\t' 'BEGIN{OFS="\t"} {print $1,$2,$5,$6}' > "$TMP_MERGED"
	fi

	[ -s "$TMP_MERGED" ]
}

main() {
	is_enabled || exit 0

	command -v curl >/dev/null 2>&1 || exit 0
	command -v sms_tool >/dev/null 2>&1 || exit 0
	command -v jsonfilter >/dev/null 2>&1 || exit 0

	build_messages || exit 0

	local sender ts idxs content text
	while IFS=$'\t' read -r sender ts idxs content; do
		[ -z "$idxs" ] && continue
		if all_indexes_sent "$idxs"; then
			continue
		fi

		text="SMS\nFrom: $sender\nDate: $ts\n\n$content"
		if send_telegram "$text"; then
			mark_indexes_sent "$idxs"
		fi
	done < "$TMP_MERGED"
}

main "$@"
