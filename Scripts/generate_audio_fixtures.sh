#!/usr/bin/env bash
# Generates the audio fixtures used by the Audio unit tests (Tests/Unit/Audio) into
# Tests/Audio/Fixtures, together with Tests/Audio/Fixtures/manifest.json.
#
#   Scripts/generate_audio_fixtures.sh
#
# Requirements: macOS `say` with English voices (list them with `say -v '?'`), and ffmpeg/ffprobe
# built with lavfi (anoisesrc, amix). No network access is needed.
#
# Output: 16 kHz mono 16-bit PCM WAV files (well under the 5 MB budget, enforced below):
#   cmd_*        canonical commands spoken by 4 different English voices (digital-silence padding)
#   silence      pure digital silence
#   noise_*      pink / brown noise beds
#   mix_*        speech + noise at SNR 20 / 10 / 5 dB (SNR = speech RMS over noise RMS)
#   pause_*      one utterance with a 400 ms internal pause (must not be split by the endpointer)
#   echo_*       barge-in scenarios: assistant voice A alone, and A + user voice B from 1.0 s;
#                "residual" variants attenuate A by 30 dB over room tone (what is left after AEC)
#
# Determinism: noise uses fixed seeds and ffmpeg runs with bitexact flags, so a re-run on the same
# macOS release reproduces the files byte for byte. `say` voices may change between macOS
# releases; the manifest records the measured speech windows, and the tests use tolerances.

set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Tests/Audio/Fixtures"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/audio-fixtures.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

RATE=16000
SPEECH_RMS_DB=-23      # every rendered utterance is normalised to this RMS level (dBFS)
ECHO_RMS_DB=-26        # echo scenarios: 3 dB lower so A + B never clips
RESIDUAL_ECHO_DB=30    # attenuation of the assistant voice in the "residual" (post-AEC) variants
ROOM_TONE_DB=-60       # pink room tone under the residual-echo variants
NOISE_BED_DB=-35       # level of the standalone noise beds
LEAD_S=0.5             # leading silence in clean fixtures
NOISY_LEAD_S=1.0       # leading noise in mixes (lets an adaptive noise floor settle)
TAIL_S=1.0             # trailing silence/noise (longer than the 700 ms end-of-speech window)
PAUSE_S=0.4            # internal pause of the pause_* fixtures
ECHO_LEAD_S=0.3        # assistant voice starts here in echo_* fixtures
USER_START_S=1.0       # user voice starts here in echo_*overlap fixtures
MAX_TOTAL_KB=5120

FF=(ffmpeg -nostdin -hide_banner -loglevel error -y)
PCM16=(-ar "$RATE" -ac 1 -c:a pcm_s16le -fflags +bitexact -flags:a +bitexact -map_metadata -1)
F32=(-ar "$RATE" -ac 1 -c:a pcm_f32le)

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but was not found in PATH"; }

need say
need ffmpeg
need ffprobe
need awk

# --- helpers -----------------------------------------------------------------------------------

has_voice() {
    say -v '?' | awk -v v="$1" 'substr($0, 1, length(v)) == v && substr($0, length(v) + 1, 1) == " " { found = 1 } END { exit !found }'
}

# Prints the first installed voice from the arguments.
pick_voice() {
    local voice
    for voice in "$@"; do
        if has_voice "$voice"; then
            echo "$voice"
            return 0
        fi
    done
    die "none of the voices [$*] is installed (check: say -v '?')"
}

calc() { awk "BEGIN { printf \"%.6f\", $1 }"; }
round3() { awk -v x="$1" 'BEGIN { printf "%.3f", x }'; }
millis() { awk -v x="$1" 'BEGIN { printf "%d", x * 1000 + 0.5 }'; }
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

duration() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

rms_db() {
    ffmpeg -nostdin -hide_banner -loglevel info -i "$1" \
        -af astats=measure_perchannel=none:measure_overall=RMS_level -f null - 2>&1 |
        awk -F': ' '/RMS level dB/ { value = $2 } END { if (value == "") exit 1; print value }'
}

# render VOICE TEXT LEVEL_DB OUT — TTS, edges trimmed at -50 dBFS, RMS-normalised, float WAV.
render() {
    local voice="$1" text="$2" level="$3" out="$4" measured
    say -v "$voice" -o "$WORK/say.aiff" "$text"
    "${FF[@]}" -i "$WORK/say.aiff" \
        -af "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse,aresample=$RATE" \
        "${F32[@]}" "$WORK/trim.wav"
    measured="$(rms_db "$WORK/trim.wav")"
    "${FF[@]}" -i "$WORK/trim.wav" -af "volume=$(calc "$level - ($measured)")dB" "${F32[@]}" "$out"
}

# silence SECONDS OUT (float WAV)
silence() { "${FF[@]}" -f lavfi -i "anullsrc=r=$RATE:cl=mono" -t "$1" "${F32[@]}" "$2"; }

# noise COLOR SEED SECONDS LEVEL_DB OUT — seeded noise normalised to LEVEL_DB RMS (float WAV).
noise() {
    local color="$1" seed="$2" seconds="$3" level="$4" out="$5" measured
    "${FF[@]}" -f lavfi -i "anoisesrc=d=$seconds:c=$color:r=$RATE:a=0.5:s=$seed" "${F32[@]}" "$WORK/noise_raw.wav"
    measured="$(rms_db "$WORK/noise_raw.wav")"
    "${FF[@]}" -i "$WORK/noise_raw.wav" -af "volume=$(calc "$level - ($measured)")dB" "${F32[@]}" "$out"
}

# pad IN LEAD_S TAIL_S OUT [CODEC...] — prepends/appends digital silence.
pad() {
    local in="$1" lead="$2" tail="$3" out="$4"
    shift 4
    "${FF[@]}" -i "$in" -af "adelay=delays=$(millis "$lead"):all=1,apad=pad_dur=$tail" "$@" "$out"
}

# concat OUT IN... (float WAV, same format)
concat() {
    local out="$1" list="$WORK/concat.txt" file
    shift
    : > "$list"
    for file in "$@"; do printf "file '%s'\n" "$file" >> "$list"; done
    "${FF[@]}" -f concat -safe 0 -i "$list" "${F32[@]}" "$out"
}

# mix OUT IN... — sums the inputs without normalisation into a 16-bit WAV as long as the first input.
mix() {
    local out="$1" inputs=() labels="" index=0 file
    shift
    for file in "$@"; do
        inputs+=(-i "$file")
        labels+="[$index:a]"
        index=$((index + 1))
    done
    "${FF[@]}" "${inputs[@]}" -filter_complex "${labels}amix=inputs=$index:duration=first:normalize=0" "${PCM16[@]}" "$out"
}

ENTRIES=()

json_string() {
    if [ -z "$1" ]; then printf 'null'; return; fi
    printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

json_number() { if [ -z "$1" ]; then printf 'null'; else printf '%s' "$1"; fi; }

# add_entry FILE KIND TEXT VOICE SNR NOISE WINDOWS [USER_TEXT USER_VOICE USER_START ASSISTANT_WINDOWS USER_WINDOWS]
add_entry() {
    local file="$1" kind="$2" text="$3" voice="$4" snr="$5" noise_kind="$6" windows="$7"
    local user_text="${8:-}" user_voice="${9:-}" user_start="${10:-}" assistant_windows="${11:-}" user_windows="${12:-}"
    local seconds
    seconds="$(round3 "$(duration "$OUT/$file")")"
    ENTRIES+=("    {\"file\": $(json_string "$file"), \"kind\": $(json_string "$kind"), \"text\": $(json_string "$text"), \"voice\": $(json_string "$voice"), \"snr\": $(json_number "$snr"), \"noise\": $(json_string "$noise_kind"), \"durationSeconds\": $seconds, \"speechWindows\": $windows, \"userText\": $(json_string "$user_text"), \"userVoice\": $(json_string "$user_voice"), \"userStartSeconds\": $(json_number "$user_start"), \"assistantWindows\": ${assistant_windows:-null}, \"userWindows\": ${user_windows:-null}}")
    printf '  %-44s %6.2fs  %s\n' "$file" "$seconds" "$kind"
}

window() { printf '[%s, %s]' "$(round3 "$1")" "$(round3 "$(calc "$1 + $2")")"; }

# --- voices ------------------------------------------------------------------------------------

VOICE_A="$(pick_voice Samantha Kathy Fred)"   # en_US; also the "assistant" voice in echo fixtures
VOICE_B="$(pick_voice Daniel Rishi Albert)"   # en_GB; also the "user" voice in echo fixtures
VOICE_C="$(pick_voice Karen Tessa Ralph)"     # en_AU
VOICE_D="$(pick_voice Moira Fred Kathy)"      # en_IE
echo "voices: A=$VOICE_A B=$VOICE_B C=$VOICE_C D=$VOICE_D"

mkdir -p "$OUT"
rm -f "$OUT"/*.wav "$OUT/manifest.json" "$OUT/.gitkeep"

# --- canonical commands ------------------------------------------------------------------------

TEXT_ALEX="text alex that i will be twenty minutes late"
TEXT_YES="yes"
TEXT_NO="no"
TEXT_CANCEL="cancel"
TEXT_CALL_MOM="call mom"
TEXT_CALENDAR="what's on my calendar tomorrow"
TEXT_REMIND="remind me to buy milk at six pm"

echo "commands:"
clean_command() {  # clean_command ID TEXT VOICE
    local id="$1" text="$2" voice="$3" file dur
    file="cmd_${id}_$(lower "$voice").wav"
    render "$voice" "$text" "$SPEECH_RMS_DB" "$WORK/speech.wav"
    dur="$(duration "$WORK/speech.wav")"
    pad "$WORK/speech.wav" "$LEAD_S" "$TAIL_S" "$OUT/$file" "${PCM16[@]}"
    add_entry "$file" "command" "$text" "$voice" "" "" "[$(window "$LEAD_S" "$dur")]"
}

clean_command text_alex "$TEXT_ALEX" "$VOICE_A"
clean_command text_alex "$TEXT_ALEX" "$VOICE_D"
clean_command yes "$TEXT_YES" "$VOICE_B"
clean_command yes "$TEXT_YES" "$VOICE_D"
clean_command no "$TEXT_NO" "$VOICE_C"
clean_command no "$TEXT_NO" "$VOICE_A"
clean_command cancel "$TEXT_CANCEL" "$VOICE_D"
clean_command call_mom "$TEXT_CALL_MOM" "$VOICE_A"
clean_command call_mom "$TEXT_CALL_MOM" "$VOICE_B"
clean_command calendar "$TEXT_CALENDAR" "$VOICE_B"
clean_command remind "$TEXT_REMIND" "$VOICE_C"

# --- silence and noise beds --------------------------------------------------------------------

echo "silence and noise:"
silence 3.0 "$WORK/silence.wav"
"${FF[@]}" -i "$WORK/silence.wav" "${PCM16[@]}" "$OUT/silence.wav"
add_entry "silence.wav" "silence" "" "" "" "" "[]"

noise pink 11 4.0 "$NOISE_BED_DB" "$WORK/bed.wav"
"${FF[@]}" -i "$WORK/bed.wav" "${PCM16[@]}" "$OUT/noise_pink.wav"
add_entry "noise_pink.wav" "noise" "" "" "" "pink" "[]"

noise brown 12 4.0 "$NOISE_BED_DB" "$WORK/bed.wav"
"${FF[@]}" -i "$WORK/bed.wav" "${PCM16[@]}" "$OUT/noise_brown.wav"
add_entry "noise_brown.wav" "noise" "" "" "" "brown" "[]"

# --- speech + noise mixes ----------------------------------------------------------------------

echo "mixes:"
noisy_command() {  # noisy_command ID TEXT VOICE COLOR SEED
    local id="$1" text="$2" voice="$3" color="$4" seed="$5" dur total snr file
    render "$voice" "$text" "$SPEECH_RMS_DB" "$WORK/speech.wav"
    dur="$(duration "$WORK/speech.wav")"
    pad "$WORK/speech.wav" "$NOISY_LEAD_S" "$TAIL_S" "$WORK/padded.wav" "${F32[@]}"
    total="$(duration "$WORK/padded.wav")"
    for snr in 20 10 5; do
        file="mix_${id}_${color}_snr${snr}.wav"
        noise "$color" "$seed" "$total" "$(calc "$SPEECH_RMS_DB - $snr")" "$WORK/noise.wav"
        mix "$OUT/$file" "$WORK/padded.wav" "$WORK/noise.wav"
        add_entry "$file" "mix" "$text" "$voice" "$snr" "$color" "[$(window "$NOISY_LEAD_S" "$dur")]"
    done
}

noisy_command call_mom "$TEXT_CALL_MOM" "$VOICE_A" pink 21
noisy_command remind "$TEXT_REMIND" "$VOICE_C" pink 22
noisy_command calendar "$TEXT_CALENDAR" "$VOICE_B" brown 23

# --- utterances with a 400 ms internal pause ---------------------------------------------------

echo "pauses:"
paused_command() {  # paused_command ID FIRST SECOND VOICE
    local id="$1" first="$2" second="$3" voice="$4" d1 d2 file second_start
    render "$voice" "$first" "$SPEECH_RMS_DB" "$WORK/part1.wav"
    render "$voice" "$second" "$SPEECH_RMS_DB" "$WORK/part2.wav"
    silence "$PAUSE_S" "$WORK/gap.wav"
    concat "$WORK/joined.wav" "$WORK/part1.wav" "$WORK/gap.wav" "$WORK/part2.wav"
    d1="$(duration "$WORK/part1.wav")"
    d2="$(duration "$WORK/part2.wav")"
    file="pause_${id}_$(lower "$voice").wav"
    pad "$WORK/joined.wav" "$LEAD_S" "$TAIL_S" "$OUT/$file" "${PCM16[@]}"
    second_start="$(calc "$LEAD_S + $d1 + $PAUSE_S")"
    add_entry "$file" "pause" "$first $second" "$voice" "" "" "[$(window "$LEAD_S" "$d1"), $(window "$second_start" "$d2")]"
}

paused_command text_alex "text alex" "that i will be twenty minutes late" "$VOICE_A"
paused_command remind "remind me to buy milk" "at six pm" "$VOICE_B"

# --- echo / barge-in scenarios -----------------------------------------------------------------

echo "echo:"
ASSISTANT_TEXT="You have three events tomorrow. The first one is a dentist appointment at nine."
USER_TEXT="stop, call mom instead"

render "$VOICE_A" "$ASSISTANT_TEXT" "$ECHO_RMS_DB" "$WORK/assistant.wav"
render "$VOICE_B" "$USER_TEXT" "$ECHO_RMS_DB" "$WORK/user.wav"
DA="$(duration "$WORK/assistant.wav")"
DU="$(duration "$WORK/user.wav")"
pad "$WORK/assistant.wav" "$ECHO_LEAD_S" "$TAIL_S" "$WORK/assistant_padded.wav" "${F32[@]}"
pad "$WORK/user.wav" "$USER_START_S" 0 "$WORK/user_padded.wav" "${F32[@]}"
ECHO_TOTAL="$(duration "$WORK/assistant_padded.wav")"
A_WINDOW="$(window "$ECHO_LEAD_S" "$DA")"
U_WINDOW="$(window "$USER_START_S" "$DU")"
UNION_END="$(awk -v a="$(calc "$ECHO_LEAD_S + $DA")" -v u="$(calc "$USER_START_S + $DU")" 'BEGIN { print (a > u ? a : u) }')"
UNION="[[$(round3 "$ECHO_LEAD_S"), $(round3 "$UNION_END")]]"

"${FF[@]}" -i "$WORK/assistant_padded.wav" "${PCM16[@]}" "$OUT/echo_assistant_only.wav"
add_entry "echo_assistant_only.wav" "echo_assistant_only" "$ASSISTANT_TEXT" "$VOICE_A" "" "" "[$A_WINDOW]" \
    "" "" "" "[$A_WINDOW]" "[]"

mix "$OUT/echo_overlap.wav" "$WORK/assistant_padded.wav" "$WORK/user_padded.wav"
add_entry "echo_overlap.wav" "echo_overlap" "$ASSISTANT_TEXT" "$VOICE_A" "" "" "$UNION" \
    "$USER_TEXT" "$VOICE_B" "$USER_START_S" "[$A_WINDOW]" "[$U_WINDOW]"

"${FF[@]}" -i "$WORK/assistant_padded.wav" -af "volume=-${RESIDUAL_ECHO_DB}dB" "${F32[@]}" "$WORK/residual.wav"
noise pink 31 "$ECHO_TOTAL" "$ROOM_TONE_DB" "$WORK/room.wav"

mix "$OUT/echo_residual_assistant_only.wav" "$WORK/residual.wav" "$WORK/room.wav"
add_entry "echo_residual_assistant_only.wav" "echo_residual_assistant_only" "$ASSISTANT_TEXT" "$VOICE_A" "" "pink" "[$A_WINDOW]" \
    "" "" "" "[$A_WINDOW]" "[]"

mix "$OUT/echo_residual_overlap.wav" "$WORK/residual.wav" "$WORK/room.wav" "$WORK/user_padded.wav"
add_entry "echo_residual_overlap.wav" "echo_residual_overlap" "$ASSISTANT_TEXT" "$VOICE_A" "" "pink" "$UNION" \
    "$USER_TEXT" "$VOICE_B" "$USER_START_S" "[$A_WINDOW]" "[$U_WINDOW]"

# --- manifest ----------------------------------------------------------------------------------

{
    echo "{"
    echo "  \"version\": 1,"
    echo "  \"generator\": \"Scripts/generate_audio_fixtures.sh\","
    echo "  \"sampleRate\": $RATE,"
    echo "  \"channels\": 1,"
    echo "  \"bitsPerSample\": 16,"
    echo "  \"speechLevelDBFS\": $SPEECH_RMS_DB,"
    echo "  \"note\": \"speechWindows are [start, end] seconds of speech measured from the rendered audio (edges trimmed at -50 dBFS).\","
    echo "  \"fixtures\": ["
    last=$((${#ENTRIES[@]} - 1))
    for i in "${!ENTRIES[@]}"; do
        if [ "$i" -lt "$last" ]; then echo "${ENTRIES[$i]},"; else echo "${ENTRIES[$i]}"; fi
    done
    echo "  ]"
    echo "}"
} > "$OUT/manifest.json"

TOTAL_KB="$(du -ck "$OUT"/*.wav "$OUT/manifest.json" | tail -n 1 | awk '{ print $1 }')"
echo "wrote ${#ENTRIES[@]} fixtures + manifest.json to $OUT (${TOTAL_KB} KB)"
if [ "$TOTAL_KB" -gt "$MAX_TOTAL_KB" ]; then
    die "fixtures total ${TOTAL_KB} KB, over the ${MAX_TOTAL_KB} KB budget"
fi
