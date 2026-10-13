#!/bin/bash
# BFME II for macOS — app launcher.
#
# Lives at "BFME II.app/Contents/MacOS/BFME2". Runs the user's own copy of
# The Battle for Middle-earth II (or Rise of the Witch-king) through the Wine
# build bundled in Contents/Resources/wine. No game files ship with the app.
#
# Usage (normally started by Finder with no arguments):
#   BFME2              first run: guided setup; afterwards: launch the game
#   BFME2 --menu       Play / reconfigure / winecfg / logs / reset menu
#   BFME2 --setup      run guided setup again
#   BFME2 --winecfg    open Wine configuration for the game prefix
#   BFME2 --reset      delete the prefix and configuration (asks first)
#   BFME2 --selftest   initialise a prefix without any game (used by CI)

set -u

APP_NAME="BFME II"
APP_ID="BFME2-macOS"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES="$(cd "$SCRIPT_DIR/../Resources" 2>/dev/null && pwd || echo "$SCRIPT_DIR")"
WINE_ROOT="${BFME2_WINE_ROOT:-$RESOURCES/wine}"

SUPPORT_DIR="${BFME2_SUPPORT_DIR:-$HOME/Library/Application Support/$APP_ID}"
LOG_DIR="${BFME2_LOG_DIR:-$HOME/Library/Logs/$APP_ID}"
CONFIG_FILE="$SUPPORT_DIR/config"
export WINEPREFIX="$SUPPORT_DIR/prefix"
GAME_DIR_UNIX="$WINEPREFIX/drive_c/Games/BFME2"

# Values the SAGE engine reads from the registry / user data folder.
BFME2_KEY='HKLM\Software\Electronic Arts\Electronic Arts\The Battle for Middle-earth II'
BFME2_KEY_ALT='HKLM\Software\Electronic Arts\The Battle for Middle-earth II'
ROTWK_KEY='HKLM\Software\Electronic Arts\Electronic Arts\The Lord of the Rings, The Rise of the Witch-king'
BFME2_LEAF='My Battle for Middle-earth(tm) II Files'
ROTWK_LEAF='My The Lord of the Rings, The Rise of the Witch-king Files'

mkdir -p "$SUPPORT_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/launcher.log"
WINE_LOG="$LOG_DIR/wine.log"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"; }

HEADLESS="${BFME2_HEADLESS:-0}"

# ---------------------------------------------------------------- UI helpers
# AppleScript strings: escape backslashes and double quotes.
as_quote() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }

alert() {
	log "ALERT: $1"
	if [ "$HEADLESS" = 1 ]; then echo "$1" >&2; return; fi
	osascript -e "display alert \"$(as_quote "$APP_NAME")\" message \"$(as_quote "$1")\" as warning" >/dev/null 2>&1
}

notify() {
	log "$1"
	[ "$HEADLESS" = 1 ] && { echo "$1"; return; }
	osascript -e "display notification \"$(as_quote "$1")\" with title \"$(as_quote "$APP_NAME")\"" >/dev/null 2>&1
}

# choose "prompt" item1 item2 ... -> prints chosen item, empty on cancel
choose() {
	local prompt="$1"; shift
	local items="" i
	for i in "$@"; do items="$items, \"$(as_quote "$i")\""; done
	items="{${items#, }}"
	local r
	r=$(osascript -e "choose from list $items with title \"$(as_quote "$APP_NAME")\" with prompt \"$(as_quote "$prompt")\" default items {\"$(as_quote "$1")\"}" 2>/dev/null)
	[ "$r" = "false" ] && r=""
	printf '%s' "$r"
}

choose_folder() {
	osascript -e "POSIX path of (choose folder with prompt \"$(as_quote "$1")\")" 2>/dev/null
}

choose_file() {
	osascript -e "POSIX path of (choose file with prompt \"$(as_quote "$1")\")" 2>/dev/null
}

ask_text() { # prompt default -> text, empty on cancel
	osascript -e "text returned of (display dialog \"$(as_quote "$1")\" default answer \"$(as_quote "$2")\" with title \"$(as_quote "$APP_NAME")\")" 2>/dev/null
}

confirm() {
	osascript -e "button returned of (display dialog \"$(as_quote "$1")\" buttons {\"Cancel\", \"OK\"} default button \"OK\" with title \"$(as_quote "$APP_NAME")\")" 2>/dev/null | grep -q OK
}

# ---------------------------------------------------------------- Wine
find_wine() {
	local c
	for c in "$WINE_ROOT/bin/wine" "$WINE_ROOT/bin/wine64"; do
		[ -x "$c" ] && { WINE="$c"; return 0; }
	done
	return 1
}

ensure_rosetta() {
	[ "$(uname -m)" = "arm64" ] || return 0
	arch -x86_64 /usr/bin/true 2>/dev/null && return 0
	log "Rosetta 2 missing"
	if [ "$HEADLESS" = 1 ]; then
		softwareupdate --install-rosetta --agree-to-license >>"$LOG_FILE" 2>&1
	else
		confirm "Wine needs Apple's Rosetta 2 on Apple Silicon Macs. Install it now? (requires an administrator password)" || exit 1
		osascript -e 'do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges' >>"$LOG_FILE" 2>&1
	fi
	arch -x86_64 /usr/bin/true 2>/dev/null || { alert "Rosetta 2 could not be installed. See $LOG_FILE"; exit 1; }
}

wine_env() {
	export PATH="$WINE_ROOT/bin:$PATH"
	export WINEDEBUG="${WINEDEBUG:--all}"
	export WINEMSYNC=1
	export WINEESYNC=1
	# The game is D3D9; wined3d over OpenGL is the most reliable path on macOS.
	export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
}

w() { "$WINE" "$@" >>"$WINE_LOG" 2>&1; }

wineserver_wait() {
	[ -x "$WINE_ROOT/bin/wineserver" ] && "$WINE_ROOT/bin/wineserver" -w
}

reg_add() { # key value type data
	w reg add "$1" /v "$2" /t "$3" /d "$4" /f /reg:32
}

init_prefix() {
	if [ -f "$WINEPREFIX/system.reg" ]; then return 0; fi
	notify "Creating Windows environment (first run, about a minute)…"
	log "wineboot -i in $WINEPREFIX"
	w wineboot -i
	wineserver_wait
	[ -f "$WINEPREFIX/system.reg" ] || { alert "Wine failed to create its prefix. See $WINE_LOG"; return 1; }

	# Prefix-wide tweaks that matter for BFME II:
	#  - report 2 GB VRAM; the game misdetects/crashes with huge values
	#  - Windows 7 version (game tests for XP+; 7 avoids the Vista UAC paths)
	w reg add 'HKCU\Software\Wine\Direct3D' /v VideoMemorySize /t REG_SZ /d 2048 /f
	w reg add 'HKCU\Software\Wine\Direct3D' /v csmt /t REG_DWORD /d 1 /f
	w winecfg -v win7
	# Mac keyboard: let Option act as Alt, Cmd stays Cmd.
	w reg add 'HKCU\Software\Wine\Mac Driver' /v LeftOptionIsAlt /t REG_SZ /d y /f
	w reg add 'HKCU\Software\Wine\Mac Driver' /v RightOptionIsAlt /t REG_SZ /d y /f
	wineserver_wait
	log "prefix ready"
}

# ---------------------------------------------------------------- game data
appdata_dir() {
	local d
	for d in "$WINEPREFIX"/drive_c/users/*/AppData/Roaming; do
		case "$d" in */Public/*) continue ;; esac
		[ -d "$d" ] && { printf '%s' "$d"; return; }
	done
	printf '%s' "$WINEPREFIX/drive_c/users/$USER/AppData/Roaming"
}

screen_size() {
	# Logical desktop size, e.g. "1512 982"
	local b
	b=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null)
	if [ -n "$b" ]; then
		echo "$b" | awk -F', ' '{print $3, $4}'
	else
		echo "1280 800"
	fi
}

write_options_ini() { # leafname resolution
	local dir
	dir="$(appdata_dir)/$1"
	mkdir -p "$dir"
	if [ -f "$dir/Options.ini" ]; then
		# Only refresh the resolution; keep the player's other settings.
		sed -i '' -e "s/^Resolution = .*/Resolution = $2/" "$dir/Options.ini" 2>/dev/null ||
			sed -i -e "s/^Resolution = .*/Resolution = $2/" "$dir/Options.ini"
		return
	fi
	# A missing Options.ini makes the game pick a resolution Wine cannot
	# set on macOS and crash on start; seed a sane one.
	cat >"$dir/Options.ini" <<EOF
AllHealthBars = yes
AlternateMouseSetup = no
AmbientVolume = 50
AudioLOD = High
Brightness = 50
FlashTutorial = 0
HasSeenLogoMovies = yes
IdealStaticGameLOD = High
MovieVolume = 50
MusicVolume = 50
Resolution = $2
SFXVolume = 70
ScrollFactor = 50
StaticGameLOD = High
TimesInGame = 1
UseEAX3 = no
VoiceVolume = 70
EOF
}

write_registry() { # install_dir_win
	local dir="$1"
	local key
	for key in "$BFME2_KEY" "$BFME2_KEY_ALT"; do
		reg_add "$key" InstallPath REG_SZ "$dir\\"
		reg_add "$key" Language REG_SZ "${BFME2_LANG:-english}"
		reg_add "$key" MapPackVersion REG_DWORD 0x00010000
		reg_add "$key" UserDataLeafName REG_SZ "$BFME2_LEAF"
		reg_add "$key" Version REG_DWORD 0x00010000
	done
	if [ -n "${CD_KEY:-}" ]; then
		w reg add "$BFME2_KEY\\ergc" /ve /t REG_SZ /d "$CD_KEY" /f /reg:32
	fi
	if [ -n "${ROTWK_EXE:-}" ]; then
		local rdir="${ROTWK_DIR_WIN:-$dir}"
		reg_add "$ROTWK_KEY" InstallPath REG_SZ "$rdir\\"
		reg_add "$ROTWK_KEY" Language REG_SZ "${BFME2_LANG:-english}"
		reg_add "$ROTWK_KEY" UserDataLeafName REG_SZ "$ROTWK_LEAF"
		reg_add "$ROTWK_KEY" Version REG_DWORD 0x00020001
		if [ -n "${ROTWK_CD_KEY:-}" ]; then
			w reg add "$ROTWK_KEY\\ergc" /ve /t REG_SZ /d "$ROTWK_CD_KEY" /f /reg:32
		fi
	fi
	wineserver_wait
}

unix_to_win() { # path inside drive_c -> C:\...
	local rel="${1#"$WINEPREFIX/drive_c/"}"
	printf 'C:\\%s' "${rel//\//\\}"
}

find_exe() { # root name -> first match
	find "$1" -iname "$2" -type f 2>/dev/null | head -n 1
}

save_config() {
	{
		printf 'BFME2_EXE=%q\n' "$BFME2_EXE"
		printf 'ROTWK_EXE=%q\n' "${ROTWK_EXE:-}"
		printf 'DEFAULT_GAME=%q\n' "${DEFAULT_GAME:-bfme2}"
		printf 'RESOLUTION=%q\n' "$RESOLUTION"
		printf 'WINDOWED=%q\n' "${WINDOWED:-0}"
		printf 'BFME2_LANG=%q\n' "${BFME2_LANG:-english}"
	} >"$CONFIG_FILE"
	log "config saved: $(tr '\n' ' ' <"$CONFIG_FILE")"
}

load_config() {
	# shellcheck source=/dev/null
	[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
}

# ---------------------------------------------------------------- setup
import_folder() {
	local src="$1"
	if [ -z "$(find_exe "$src" lotrbfme2.exe)" ] && [ -z "$(find_exe "$src" lotrbfme2ep1.exe)" ]; then
		alert "That folder doesn't contain lotrbfme2.exe or lotrbfme2ep1.exe. Pick the folder the game is installed in (on Windows typically C:\\Program Files (x86)\\Electronic Arts\\The Battle for Middle-earth II)."
		return 1
	fi
	notify "Copying game files into the app's Windows drive…"
	mkdir -p "$GAME_DIR_UNIX"
	if ! ditto "$src" "$GAME_DIR_UNIX/$(basename "$src")" >>"$LOG_FILE" 2>&1; then
		alert "Copying failed (out of disk space?). See $LOG_FILE"
		return 1
	fi
}

run_installer() {
	local exe="$1"
	notify "Starting the Windows installer. Install to the default location."
	log "running installer $exe"
	(cd "$(dirname "$exe")" && "$WINE" start /wait /unix "$exe" >>"$WINE_LOG" 2>&1)
	wineserver_wait
}

install_from_image() {
	local img="$1" mnt
	mnt=$(hdiutil attach -nobrowse -readonly "$img" 2>>"$LOG_FILE" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
	if [ -z "$mnt" ]; then alert "Could not mount $img"; return 1; fi
	local setup
	setup=$(find_exe "$mnt" AutoRun.exe)
	[ -z "$setup" ] && setup=$(find_exe "$mnt" setup.exe)
	if [ -z "$setup" ]; then
		alert "No AutoRun.exe or setup.exe found on the image."
		hdiutil detach "$mnt" >/dev/null 2>&1
		return 1
	fi
	run_installer "$setup"
	hdiutil detach "$mnt" >/dev/null 2>&1
}

locate_installed() {
	BFME2_EXE=$(find_exe "$WINEPREFIX/drive_c" lotrbfme2.exe)
	ROTWK_EXE=$(find_exe "$WINEPREFIX/drive_c" lotrbfme2ep1.exe)
}

setup() {
	init_prefix || exit 1

	local SRC_FOLDER="Copy an existing installation (folder with lotrbfme2.exe)"
	local SRC_INSTALLER="Run a Windows installer (setup.exe / AutoRun.exe)"
	local SRC_IMAGE="Install from a disc image (.iso / .dmg / .cdr)"
	local how
	how=$(choose "Where are your Battle for Middle-earth II game files? You need your own copy of the game; nothing is downloaded." \
		"$SRC_FOLDER" "$SRC_INSTALLER" "$SRC_IMAGE")
	[ -z "$how" ] && exit 0

	case "$how" in
	"$SRC_FOLDER")
		local f; f=$(choose_folder "Select the BFME II installation folder") || exit 0
		[ -z "$f" ] && exit 0
		import_folder "${f%/}" || exit 1
		;;
	"$SRC_INSTALLER")
		local s; s=$(choose_file "Select the installer (AutoRun.exe or setup.exe)") || exit 0
		[ -z "$s" ] && exit 0
		run_installer "$s"
		;;
	"$SRC_IMAGE")
		local i; i=$(choose_file "Select the disc image") || exit 0
		[ -z "$i" ] && exit 0
		install_from_image "$i" || exit 1
		;;
	esac

	locate_installed
	if [ -z "$BFME2_EXE" ] && [ -z "$ROTWK_EXE" ]; then
		alert "Setup finished but lotrbfme2.exe was not found in the Windows drive. See $LOG_FILE and $WINE_LOG."
		exit 1
	fi

	DEFAULT_GAME=bfme2
	if [ -n "$BFME2_EXE" ] && [ -n "$ROTWK_EXE" ]; then
		local g
		g=$(choose "Both games were found. Which should the app start by default? (Change later with --menu)" \
			"The Battle for Middle-earth II" "The Rise of the Witch-king")
		[ "$g" = "The Rise of the Witch-king" ] && DEFAULT_GAME=rotwk
	elif [ -z "$BFME2_EXE" ]; then
		DEFAULT_GAME=rotwk
	fi

	# CD keys: only the player's own key. The installer usually writes it
	# already; ask only when the registry has none.
	if ! "$WINE" reg query "$BFME2_KEY\\ergc" /reg:32 >/dev/null 2>&1 && [ -n "$BFME2_EXE" ]; then
		CD_KEY=$(ask_text "Enter your BFME II CD key (leave empty to skip — the game may refuse to start without one)." "")
	fi
	if [ -n "${ROTWK_EXE:-}" ] && ! "$WINE" reg query "$ROTWK_KEY\\ergc" /reg:32 >/dev/null 2>&1; then
		ROTWK_CD_KEY=$(ask_text "Enter your Rise of the Witch-king CD key (leave empty to skip)." "")
	fi

	local exe_for_dir="${BFME2_EXE:-$ROTWK_EXE}"
	[ -n "$ROTWK_EXE" ] && ROTWK_DIR_WIN=$(unix_to_win "$(dirname "$ROTWK_EXE")")
	write_registry "$(unix_to_win "$(dirname "$exe_for_dir")")"

	RESOLUTION=$(screen_size)
	local r
	r=$(choose "Game resolution (your screen is $RESOLUTION):" "$RESOLUTION" "1920 1080" "1680 1050" "1440 900" "1280 800" "1024 768")
	[ -n "$r" ] && RESOLUTION="$r"
	if confirm "Run in a window instead of fullscreen? (Recommended if fullscreen flickers; press Cancel for fullscreen.)"; then
		WINDOWED=1
	else
		WINDOWED=0
	fi
	save_config
	notify "Setup complete."
}

# ---------------------------------------------------------------- play
play() {
	load_config
	local exe leaf
	if [ "${DEFAULT_GAME:-bfme2}" = rotwk ] && [ -n "${ROTWK_EXE:-}" ]; then
		exe="$ROTWK_EXE"; leaf="$ROTWK_LEAF"
	else
		exe="$BFME2_EXE"; leaf="$BFME2_LEAF"
	fi
	if [ ! -f "$exe" ]; then
		alert "Game executable missing ($exe). Run setup again."
		setup; play; return
	fi
	write_options_ini "$leaf" "$RESOLUTION"

	local args=(-xres "${RESOLUTION% *}" -yres "${RESOLUTION#* }")
	[ "${WINDOWED:-0}" = 1 ] && args+=(-win)
	log "launching $exe ${args[*]}"
	: >"$WINE_LOG"
	(cd "$(dirname "$exe")" && "$WINE" "$(basename "$exe")" "${args[@]}" >>"$WINE_LOG" 2>&1)
	local rc=$?
	wineserver_wait
	log "game exited rc=$rc"
	if [ $rc -ne 0 ] && grep -qiE 'err:|exception' "$WINE_LOG"; then
		alert "The game exited with an error (code $rc). Log: $WINE_LOG"
	fi
}

menu() {
	load_config
	local c
	c=$(choose "What do you want to do?" "Play" "Switch game (BFME II / Rise of the Witch-king)" "Change resolution / window mode" "Run setup again" "Wine configuration" "Show logs" "Reset everything")
	case "$c" in
	"Play") play ;;
	"Switch game"*)
		[ "${DEFAULT_GAME:-bfme2}" = rotwk ] && DEFAULT_GAME=bfme2 || DEFAULT_GAME=rotwk
		save_config; notify "Default game: $DEFAULT_GAME" ;;
	"Change resolution"*)
		local r; r=$(ask_text "Resolution (width height):" "${RESOLUTION:-1280 800}")
		[ -n "$r" ] && RESOLUTION="$r"
		if confirm "Windowed mode? (Cancel = fullscreen)"; then WINDOWED=1; else WINDOWED=0; fi
		save_config ;;
	"Run setup again") setup ;;
	"Wine configuration") w winecfg ;;
	"Show logs") open "$LOG_DIR" ;;
	"Reset everything") reset_all ;;
	esac
}

reset_all() {
	confirm "Delete the app's Windows drive (including copied game files and saved games) at: $SUPPORT_DIR ?" || return
	[ -x "$WINE_ROOT/bin/wineserver" ] && "$WINE_ROOT/bin/wineserver" -k 2>/dev/null
	rm -rf "$SUPPORT_DIR"
	notify "Reset done."
}

selftest() {
	HEADLESS=1
	init_prefix || exit 1
	write_registry 'C:\Games\BFME2'
	write_options_ini "$BFME2_LEAF" "1280 800"
	"$WINE" reg query "$BFME2_KEY" /reg:32 || exit 1
	[ -f "$(appdata_dir)/$BFME2_LEAF/Options.ini" ] || { echo "Options.ini missing" >&2; exit 1; }
	echo "selftest OK: $("$WINE" --version)"
}

# ---------------------------------------------------------------- main
log "---- start: $* (macOS $(sw_vers -productVersion 2>/dev/null), $(uname -m))"
if ! find_wine; then
	alert "The bundled Wine runtime is missing from the app ($WINE_ROOT). Re-download the app."
	exit 1
fi
ensure_rosetta
wine_env

case "${1:-}" in
--menu) menu ;;
--setup) setup ;;
--winecfg) init_prefix && w winecfg ;;
--reset) reset_all ;;
--selftest) selftest ;;
-psn_*|"")
	load_config
	if [ -z "${BFME2_EXE:-}${ROTWK_EXE:-}" ]; then
		setup && play
	else
		play
	fi
	;;
*) echo "unknown option: $1" >&2; exit 2 ;;
esac
