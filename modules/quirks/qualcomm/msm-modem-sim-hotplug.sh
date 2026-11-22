# Picks up a SIM card inserted while the phone runs.
#
# msm-modem-uim-selection activates the card's USIM application (the
# primary GW provisioning session) once, at boot. The modem does not do it
# by itself when a card is inserted later; on Android the RIL does. Without
# that session ModemManager reports the SIM as missing (sim-missing), even
# after its own reprobe on the slot status change.
#
# So: watch the UIM slot status indications. When a card is present and no
# primary GW session exists, run the selection, then restart ModemManager
# if it is stuck in failed/sim-missing. Nothing is done while a session
# exists: msm-modem-uim-selection deactivates an existing session before
# selecting, which would drop service in a call.

QMI="qmicli --silent -pd qrtr://0"

# Value of a `mmcli -K` key, or nothing.
mm_field() {
	printf '%s\n' "$2" | awk -F': ' -v key="$1" '{ k = $1; sub(/ +$/, "", k) } k == key { print $2; exit }'
}

no_session() {
	printf '%s\n' "$1" | grep -Eq "Primary GW: +session doesn't exist"
}

# ModemManager read the card before the session existed and gave up
# (failed, sim-missing); it does not look again by itself. Restart it, but
# only in that state: with no SIM there is no call or data to lose.
reprobe_modemmanager() {
	local status state reason
	for _ in $(seq 10); do
		sleep 3
		status=$(mmcli -m any -K 2>/dev/null) || continue
		state=$(mm_field modem.generic.state "$status")
		reason=$(mm_field modem.generic.state-failed-reason "$status")
		case "$state" in
		failed)
			if [ "$reason" = sim-missing ]; then
				echo "ModemManager still reports sim-missing, restarting it."
				systemctl restart ModemManager.service
			else
				echo "ModemManager failed ($reason), leaving it."
			fi
			return 0
			;;
		""|unknown|initializing) ;;
		*)
			echo "ModemManager sees the SIM (state $state)."
			return 0
			;;
		esac
	done
	echo "ModemManager did not settle within 30 s, leaving it."
}

# A card's applications show up a moment after the card itself, so retry
# for up to 20 s. Returns quietly if no card shows up (a removal).
check() {
	local status attempts=0
	for _ in $(seq 20); do
		if status=$($QMI --uim-get-card-status 2>/dev/null) &&
			printf '%s\n' "$status" | grep -Fq "Card state: 'present'"; then
			if ! no_session "$status"; then
				if [ "$attempts" -gt 0 ]; then
					echo "USIM application activated."
					reprobe_modemmanager
				fi
				return 0
			fi
			if printf '%s\n' "$status" | grep -Fq "usim (2)" && [ "$attempts" -lt 3 ]; then
				echo "Card present without a provisioning session, selecting it."
				attempts=$((attempts + 1))
				# Its exit status is unreliable here (the systemd-notify
				# EXIT trap); the next card status tells whether it worked.
				SIM_WAIT_TIME=0 "$UIM_SELECTION" || true
				continue
			fi
		fi
		sleep 1
	done
	if [ "$attempts" -gt 0 ]; then
		echo "Could not activate the USIM application."
	fi
}

# A card inserted between the boot-time selection and now.
check </dev/null

# qmicli prints each indication as several lines, the first one
# "[...] Received slot status indication:"; read the rest, then check.
$QMI --uim-monitor-slot-status | while IFS= read -r line; do
	case "$line" in
	*"slot status indication"*) ;;
	*) continue ;;
	esac
	while IFS= read -r -t 1 _; do :; done
	check </dev/null
done
