realname() {
        echo "$(cd "$(dirname "$1")"; pwd)/$(basename "$1")"
}

pushd () {
    command pushd "$@" > /dev/null
}

popd () {
    command popd "$@" > /dev/null
}

# Terminal styling. Colors and the spinner are only used on an interactive
# terminal (and never when NO_COLOR is set); Unicode glyphs need a UTF-8 locale.
UI_TTY=
C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_CYAN=
if [[ -t 1 ]] && [[ "${TERM}" != "dumb" ]]; then
    UI_TTY=1
    if [[ -z "${NO_COLOR}" ]]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
        # Plain SGR "dim" is too dark on many themes; use a mid-gray where 256 colors exist
        if [[ "$(tput colors 2>/dev/null)" -ge 256 ]] 2>/dev/null; then
            C_DIM=$'\033[38;5;246m'
        else
            C_DIM=$'\033[2m'
        fi
        C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
    fi
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG}}}" in
    *[Uu][Tt][Ff]8*|*[Uu][Tt][Ff]-8*)
        S_TOP="┌"; S_BAR="│"; S_END="└"; S_STEP="◇"
        S_OK="✓"; S_ERR="✗"; S_WARN="!"; S_INFO="•"
        UI_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        ;;
    *)
        S_TOP="+"; S_BAR="|"; S_END="+"; S_STEP="*"
        S_OK="+"; S_ERR="x"; S_WARN="!"; S_INFO="-"
        UI_FRAMES=("|" "/" "-" "\\")
        ;;
esac
UI_BAR="${C_DIM}${S_BAR}${C_RESET}"

# Where ui_run sends the output of the commands it wraps
UI_LOG=

greenecho() {
        text=$1
        printf '%s\n' "${C_BOLD}${C_GREEN}${text}${C_RESET}"
}

redecho() {
        text=$1
        printf '%s\n' "${C_BOLD}${C_RED}${text}${C_RESET}"
}

ui_intro() {
    printf '\n%s  %s\n' "${C_DIM}${S_TOP}${C_RESET}" "${C_BOLD}$1${C_RESET}"
}

ui_section() {
    printf '%s\n%s  %s\n' "${UI_BAR}" "${C_CYAN}${S_STEP}${C_RESET}" "${C_BOLD}$1${C_RESET}"
}

# ui_ok <message> [detail]
ui_ok() {
    printf '%s  %s  %s%s\n' "${UI_BAR}" "${C_GREEN}${S_OK}${C_RESET}" "$1" "${2:+  ${C_DIM}$2${C_RESET}}"
}

ui_info() {
    printf '%s  %s  %s%s\n' "${UI_BAR}" "${C_CYAN}${S_INFO}${C_RESET}" "$1" "${2:+  ${C_DIM}$2${C_RESET}}"
}

ui_warn() {
    printf '%s  %s  %s\n' "${UI_BAR}" "${C_YELLOW}${S_WARN}${C_RESET}" "${C_YELLOW}$1${C_RESET}"
}

ui_err() {
    printf '%s  %s  %s\n' "${UI_BAR}" "${C_RED}${S_ERR}${C_RESET}" "${C_RED}$1${C_RESET}"
}

# ui_kv <key> <value>: a dimmed label with a value, aligned under ui_ok text
ui_kv() {
    printf '%s     %s%-9s%s %s\n' "${UI_BAR}" "${C_DIM}" "$1" "${C_RESET}" "$2"
}

ui_outro() {
    printf '%s\n%s  %s\n\n' "${UI_BAR}" "${C_GREEN}${S_END}${C_RESET}" "${C_BOLD}${C_GREEN}$1${C_RESET}"
}

# ui_die <exit code> <message>
ui_die() {
    ui_err "$2"
    printf '%s\n%s  %s\n\n' "${UI_BAR}" "${C_RED}${S_END}${C_RESET}" "${C_BOLD}${C_RED}Build failed${C_RESET}"
    exit "$1"
}

# ui_elapsed <seconds>
ui_elapsed() {
    if (( $1 >= 60 )); then
        printf '%dm %02ds' $(( $1 / 60 )) $(( $1 % 60 ))
    else
        printf '%ds' "$1"
    fi
}

# ui_run <label> <command...>
# Runs the command with its output appended to $UI_LOG, showing a spinner while
# it works. Returns the command's exit code; on failure, shows the end of the log.
ui_run() {
    local label=$1
    shift
    local log="${UI_LOG:-/dev/null}"
    local start=$SECONDS
    local rc pid line
    local frame=0

    printf '\n=== %s\n' "${label}" >> "${log}"

    if [[ -n "${UI_TTY}" ]]; then
        "$@" >> "${log}" 2>&1 < /dev/null &
        pid=$!
        # Background jobs ignore Ctrl-C in a script, so clean up by hand
        trap "pkill -P ${pid} 2>/dev/null; kill ${pid} 2>/dev/null; printf '\r\033[K\033[?25h\n'; exit 130" INT TERM
        printf '\033[?25l'
        while kill -0 "${pid}" 2>/dev/null; do
            printf '\r\033[K%s  %s  %s  %s%s%s' "${UI_BAR}" "${C_CYAN}${UI_FRAMES[frame]}${C_RESET}" "${label}" "${C_DIM}" "$(ui_elapsed $(( SECONDS - start )))" "${C_RESET}"
            frame=$(( (frame + 1) % ${#UI_FRAMES[@]} ))
            sleep 0.08
        done
        wait "${pid}"
        rc=$?
        trap - INT TERM
        printf '\r\033[K\033[?25h'
    else
        "$@" >> "${log}" 2>&1 < /dev/null
        rc=$?
    fi

    if [[ "${rc}" -eq 0 ]]; then
        if (( SECONDS - start >= 2 )); then
            ui_ok "${label}" "$(ui_elapsed $(( SECONDS - start )))"
        else
            ui_ok "${label}"
        fi
    else
        ui_err "${label} (exit code ${rc})"
        if [[ "${log}" != "/dev/null" ]]; then
            tail -n 15 "${log}" | sed '/^$/d;/^=== /d' | cut -c1-120 | while IFS= read -r line; do
                printf '%s     %s%s%s\n' "${UI_BAR}" "${C_DIM}" "${line}" "${C_RESET}"
            done
        fi
    fi
    return "${rc}"
}
