#!/bin/bash

shopt -s extglob

# Let's do some colors: C0..9.
C0='\e[0m'
for i in {1..9}; do
    declare -- C$i="\e[38;5;${i}m"
done

debug=0
timeout=5
lockfile=/var/lock/event-callback.lock

# https://github.com/util-linux/util-linux/commit/8a0dc11a5b204c7d43adae9f42abcebe41c5b66e
exec 3> "$lockfile" && flock -x -w $timeout --fcntl 3
if (($? != 0)); then
    echo "Error: Could not obtain a lock."
    exit 1
fi

# static API structure (use: touch -a <api>).
declare -A API=(
    [/opt/event-callback/api/help]="help: API: info, help, kill, name, version."
    [/opt/event-callback/api/info]="Info: Event monitor with busy/idle callback."
    [/opt/event-callback/api/kill]="Quit..."
    [/opt/event-callback/api/name]="Name: event-callback"
    [/opt/event-callback/api/version]="Version: 0.1"
)

# Create file structure.
mkdir -m 0750 -p /opt/event-callback/api && touch "${!API[@]}" || exit 1

# create fifo.
[[ -p /opt/event-callback/event.fifo ]] || mkfifo -m 0660 /opt/event-callback/event.fifo

# Inotify monitor files.
declare -a WATCH_API=(${!API[@]}) \
           WATCH_EVENT=(/dev/input/event{0,4})

# Watch for api and input events.
add_watch(){
    coproc "$1" {
        eval "${@:2}"
    } > /opt/event-callback/event.fifo
}
add_watch W1 inotifywait -e access -qm --format %w "${WATCH_API[@]}"
add_watch W2 inotifywait -e access -qm --format %w "${WATCH_EVENT[@]}" "|" sed -u -n "1~2p"

# Send sigpipe to GPID (...to close inotifywait on exit).
signal_coproc(){
    kill -s PIPE -- -$$

}
trap signal_coproc EXIT

# Event queue:
# Consolidate duplicate entries and
# flush buffer after `-t time`.
# Serialize response as a ´declare -p´ statement.
coproc event_queue {
    declare -A queue=()
    declare -- RT=0.1 LT=200000
    while read -r event; do
        queue=()
        ET=${EPOCHREALTIME/.}
        while :; do
            [[ -n $event ]] || { read -r -t $RT event || unset event; }
            if [[ $event = @(*/hook/*|*/api/*) ]]; then
                echo "declare -A queue=([$event]=${queue[$event]})"
            else
                ER=${EPOCHREALTIME/.}
                [[ -n $event ]] && { [[ -v queue[$event] ]] || queue[$event]=$ER; }
                if ((ER - ET > LT)); then
                    for event in ${!queue[@]}; do
                        if ((ER - ${queue[$event]} > LT)); then
                            echo "declare -A queue=([$event]=${queue[$event]})"; unset queue[$event]
                        fi
                    done
                fi
            fi
            ((${#queue[@]} > 0)) && unset event || break
        done
    done
} < /opt/event-callback/event.fifo

# Hook worker:
# Create busy and idle hook for $event.
coproc hook_worker {
    declare -A work=() \
        LT=([/dev/input/event0]=1000000 [/dev/input/event4]=500000)
    declare -- RT=0.1 DT=300000
    while read -r event; do
        while :; do
               [[ -n $event ]] || { read -r -t $RT event || unset event; }
            ER=${EPOCHREALTIME/.}
            if [[ -n $event ]]; then
                if [[ ! -v work[$event] ]]; then
                    echo "$event/hook/busy"
                fi
                work[$event]=$ER
            fi
            for event in "${!work[@]}"; do
                if ((ER - ${work[$event]} > ${LT[$event]:-$DT})); then
                    echo "$event/hook/idle"; unset work[$event]
                fi
            done
            ((${#work[@]} > 0)) && unset event || break
        done
    done
} > /opt/event-callback/event.fifo

# API:
# Output some information.
api_func(){
    local -n __e__=$1
    local -g API C0 C7

    case $__e__ in
        */kill)
            EXIT=1 ;&
        */@(info|name|version))
            printf '%b%s%b\n' $C7 "${API[$__e__]}" $C0 ;;
    esac
    return ${EXIT:-0}
}

declare -A X=()

# Hook:
# Print colored message for busy/idle hooks.
hook_func(){
    local -n __e__=$1
    local -g C0 C2 C9 X
    local -a a
    local -- b
    IFS=/ a=($__e__) b=${a[*]:(-3):1}

    case $__e__ in
        */busy)
            printf '%b%s%b\n' $C2 "${b^} busy hook activated $((++X[$__e__])) time(s)." $C0 ;;
        */idle)
            printf '%b%s%b\n' $C9 "${b^} idle." $C0 ;;
    esac
    return ${EXIT:-0}
}

# Queue function:
# Delegate queue events to its respective function.
queue_func(){
    local -n __q__=$1
    local -- event

    for event in "${!__q__[@]}"; do
        case $event in
            #/dev/input/event0)
            #    echo $event ;;
            /dev/input/event*/hook/*)
                hook_func event ;;
            /dev/input/event*)
                echo "$event" >&"${hook_worker[1]}" ;;
            /opt/event-callback/api/*)
                api_func event ;;
        esac
    done
    return ${EXIT:-0}
}

# Queue reader:
# eval `declare -p` statement.
while read -r -u "${event_queue[0]}" buffer; do
    ((debug == 1)) && \
        echo "$buffer"
    if [[ $buffer =~ ^declare\ ..\ ([^=]+)= ]]; then
        case ${BASH_REMATCH[1]} in
            queue) eval "$buffer"; queue_func queue || exit 1 ;;
        esac
    fi
done
