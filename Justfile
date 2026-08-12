
dvr:
	tmux new -s dvr ssh -t raspberrypi 'picocom -b 115200 --omap crcrlf --logfile dvr.log /dev/serial0'
