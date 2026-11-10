realname() {
        echo "$(cd "$(dirname "$1")"; pwd)/$(basename "$1")"
}

pushd () {
    command pushd "$@" > /dev/null
}

popd () {
    command popd "$@" > /dev/null
}

# True under Git Bash (MSYS2) or Cygwin on Windows
is_windows() {
    case "${OSTYPE}" in msys*|cygwin*) return 0 ;; esac
    return 1
}

# unix_path <path>: on Windows, turns C:\foo or C:/foo into /c/foo so it can be
# joined with other paths; elsewhere it's a no-op
unix_path() {
    if is_windows && command -v cygpath > /dev/null 2>&1; then
        cygpath -u "$1"
    else
        printf '%s\n' "$1"
    fi
}

# Zip helpers. Git for Windows and minimal Linux installs may not have unzip,
# so fall back to bsdtar (Windows 10+ ships one as System32\tar.exe; Git Bash's
# own tar is GNU tar, which can't read zips) or Python.
zip_tool() {
    local wintar
    if command -v unzip > /dev/null 2>&1; then
        echo unzip
    elif command -v bsdtar > /dev/null 2>&1; then
        echo bsdtar
    elif is_windows && [[ -n "${SYSTEMROOT}" ]] && wintar="$(unix_path "${SYSTEMROOT}")/System32/tar.exe" && [[ -x "${wintar}" ]]; then
        echo "${wintar}"
    elif command -v python3 > /dev/null 2>&1 && python3 -c 'import zipfile' > /dev/null 2>&1; then
        echo python3
    fi
}

# zip_extract <zip> <directory> [member...]: extract all, or just the members, overwriting
zip_extract() {
    local zip=$1 dir=$2 tool rc
    shift 2
    tool=$(zip_tool)
    case "${tool}" in
        unzip)
            unzip -qo "${zip}" "$@" -d "${dir}"
            rc=$?
            # unzip exit code 1 is only a warning
            (( rc <= 1 ))
            ;;
        python3)
            python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2], sys.argv[3:] or None)' "${zip}" "${dir}" "$@"
            ;;
        "")
            echo "No zip extractor found; install unzip" >&2
            return 1
            ;;
        *)
            "${tool}" -xf "${zip}" -C "${dir}" "$@"
            ;;
    esac
}

# zip_cat <zip> <member>: print one member's contents
zip_cat() {
    local tool
    tool=$(zip_tool)
    case "${tool}" in
        unzip)   unzip -p "$1" "$2" ;;
        python3) python3 -c 'import sys, zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))' "$1" "$2" ;;
        "")      echo "No zip extractor found; install unzip" >&2; return 1 ;;
        *)       "${tool}" -xOf "$1" "$2" ;;
    esac
}

# kill_tree <pid>: kill a process and everything it started. pkill isn't in Git
# Bash, but "ps -ef" is everywhere and always has PID in column 2, PPID in 3.
kill_tree() {
    local child
    for child in $(ps -ef 2> /dev/null | awk -v p="$1" '$3 == p { print $2 }'); do
        kill_tree "${child}"
    done
    kill "$1" 2> /dev/null
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

# ui_detail <line...>: dimmed lines indented under the previous message. Paths
# under $HOME are shortened to ~, and on a terminal long lines wrap to fit.
ui_detail() {
    local width=0 line
    if [[ -n "${UI_TTY}" ]]; then
        width=$(( $(tput cols 2>/dev/null || echo 120) - 6 ))
        (( width < 40 )) && width=40
    fi
    printf '%s\n' "$@" | sed "s|${HOME}/|~/|g" | if (( width > 0 )); then fold -s -w "${width}"; else cat; fi \
        | while IFS= read -r line; do
            printf '%s     %s%s%s\n' "${UI_BAR}" "${C_DIM}" "${line}" "${C_RESET}"
        done
}

# ui_die <exit code> <message> [detail...]
ui_die() {
    ui_err "$2"
    (( $# > 2 )) && ui_detail "${@:3}"
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

# ui_log_excerpt <log> <first line>
# Prints the part of a step's output worth showing when it fails: compiler
# errors plus Gradle's "What went wrong" blocks, or Ant's BUILD FAILED message,
# falling back to the last few lines of output.
ui_log_excerpt() {
    local section
    # tr: Java tools on Windows end lines with \r\n, which would break the matching below
    section=$(tail -n +"$2" "$1" | tr -d '\r' | sed '/^=== /d')
    if grep -q '^\* What went wrong:' <<< "${section}"; then
        grep -E '^(\[javac\] )?.+\.java:[0-9]+: error: ' <<< "${section}" | head -n 10
        awk '
            /^\* What went wrong:/ { grab = 1; if (n++) print ""; next }
            /^\* [A-Z][a-z ]+:$/ || /^=====/ { grab = 0 }
            grab && NF { print }
        ' <<< "${section}"
    elif grep -q '^BUILD FAILED' <<< "${section}"; then
        grep -E '\.java:[0-9]+: error: ' <<< "${section}" | sed 's/^ *//' | head -n 10
        awk '/^BUILD FAILED/ { grab = 1 } /^Total time:/ { grab = 0 } grab && NF { print }' <<< "${section}"
    else
        sed '/^$/d' <<< "${section}" | tail -n 15
    fi
}

# ui_run <label> <command...>
# Runs the command with its output appended to $UI_LOG, showing a spinner while
# it works. Returns the command's exit code; on failure, shows what went wrong.
ui_run() {
    local label=$1
    shift
    local log="${UI_LOG:-/dev/null}"
    local start=$SECONDS
    local rc pid
    local frame=0
    local from=1

    # Line where this step's output will start, so a failure shows only this step
    [[ -f "${log}" ]] && from=$(( $(wc -l < "${log}") + 1 ))
    printf '\n=== %s\n' "${label}" >> "${log}"

    if [[ -n "${UI_TTY}" ]]; then
        # Run the command in the background (&) so we can draw the spinner.
        # stdout and stderr (2>&1) both go to the log; stdin is /dev/null so
        # anything that prompts for input fails instead of hanging unseen.
        # The $! variable is the PID of the last background job, which we use to 
        # check whether the command is still running (kill -0) and to wait for it 
        # to finish (wait).
        "$@" >> "${log}" 2>&1 < /dev/null &
        pid=$!
        # Background jobs ignore Ctrl-C in a script, so on Ctrl-C (INT) or kill
        # (TERM): kill the job and everything it started, clear the spinner line
        # (\r = line start, \033[K = erase line), show the cursor (\033[?25h),
        # and exit 130, the conventional "interrupted" code
        trap "kill_tree ${pid}; printf '\r\033[K\033[?25h\n'; exit 130" INT TERM
        printf '\033[?25l'  # hide the cursor
        # kill -0 sends no signal; it just tests whether the process still exists
        while kill -0 "${pid}" 2>/dev/null; do
            printf '\r\033[K%s  %s  %s  %s%s%s' "${UI_BAR}" "${C_CYAN}${UI_FRAMES[frame]}${C_RESET}" "${label}" "${C_DIM}" "$(ui_elapsed $(( SECONDS - start )))" "${C_RESET}"
            frame=$(( (frame + 1) % ${#UI_FRAMES[@]} ))
            sleep 0.08
        done
        # wait collects the finished job's exit code
        wait "${pid}"
        rc=$?
        trap - INT TERM  # restore normal Ctrl-C handling
        printf '\r\033[K\033[?25h'
    else
        # Not a terminal (piped, CI): no spinner, run in the foreground
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
            local excerpt
            excerpt=$(ui_log_excerpt "${log}" "${from}")
            [[ -n "${excerpt}" ]] && ui_detail "${excerpt}"
        fi
    fi
    return "${rc}"
}
