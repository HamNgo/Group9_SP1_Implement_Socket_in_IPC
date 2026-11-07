# Shared by the demo scripts (source it). All demos write into ONE history file,
# output.txt, and only ever APPEND to it. Each demo announces itself with a banner.
#
#   hist_banner "title" "line 2" ...   append a banner (timestamp + script name added)
#   hist_note   "text"                 append one "[DEMO] ..." line (a note in the timeline)
#   hist_end    "text"                 append a closing line
#   hist_size                          current size in bytes (use as a start/end marker)
#   hist_section START [END]           print only the bytes START..END of the file

HIST="${HIST:-$PWD/output.txt}"

hist_size() { stat -c %s "$HIST" 2>/dev/null || echo 0; }

hist_banner() {
    {
        printf '\n################################################################\n'
        local l
        for l in "$@"; do printf '# %s\n' "$l"; done
        printf '# %s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(basename "$0")"
        printf '################################################################\n'
    } >> "$HIST"
}

hist_note() { printf '[%s] [DEMO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$HIST"; }

hist_end() { printf '# ---- %s ----\n' "$*" >> "$HIST"; }

hist_section() {
    if [ -n "${2:-}" ]; then
        tail -c +"$(($1 + 1))" "$HIST" 2>/dev/null | head -c "$(($2 - $1))"
    else
        tail -c +"$(($1 + 1))" "$HIST" 2>/dev/null
    fi
}
