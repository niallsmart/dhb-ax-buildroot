
dvr:
	tmux new -s dvr ssh -t raspberrypi 'flock -n /tmp/dvr-uart.lock picocom -b 115200 --omap crcrlf --logfile dvr.log /dev/serial0'
