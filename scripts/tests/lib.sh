# shellcheck shell=bash
# Shared helpers for scripts/test-suite.sh. Bash 3.2 compatible (macOS /bin/bash).

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

# run_with_timeout SECONDS cmd args… (macOS has no coreutils `timeout`).
# The alarm survives exec, so the command is killed by SIGALRM (exit 142) when it overruns.
run_with_timeout() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }

# --- ffprobe helpers --------------------------------------------------------

# probe_duration FILE → seconds (float), empty if unknown.
probe_duration() {
    "$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1
}

# probe_codecs FILE TYPE(v|a) → space-separated codec names (skips attached pictures).
probe_codecs() {
    "$FFPROBE" -v error -select_streams "$2" -show_entries stream=codec_name:stream_disposition=attached_pic \
        -of csv=p=0 "$1" 2>/dev/null | awk -F, '$2 != "1" { printf "%s ", $1 }' | sed 's/ $//'
}

probe_stream_value() { # FILE STREAMSEL KEY
    "$FFPROBE" -v error -select_streams "$2" -show_entries "stream=$3" -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1
}

# float_near A B TOL → success when |A-B| <= TOL
float_near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(a != "" && d <= t) }'; }
float_lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && a < b) }'; }

# --- text helpers -----------------------------------------------------------

# Plain text of any document textutil can read (docx, odt, rtf, rtfd, html, txt).
doc_text() { /usr/bin/textutil -convert txt -stdout "$1" 2>/dev/null; }

contains() { grep -qF -- "$2" "$1" 2>/dev/null; }
