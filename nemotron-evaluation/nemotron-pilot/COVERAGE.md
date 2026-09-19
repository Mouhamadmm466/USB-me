# Coverage: 150 local voice-assistant scenarios

50 easy + 50 medium + 50 hard. Every scenario has its own request, state, answer key, difficulty rationale, and speech-review criteria. No model evaluation has been performed for this dataset.

The original E1–E3, M1–M3, and H1–H3 remain as known development cases. The additional 141 scenarios are explicitly authored in `datasets/build_cases.py`; they are not produced by randomizing names or repeating requests. The set is exposed development material, not a hidden benchmark.

## Primary task categories

| Category | Easy | Medium | Hard | Total |
|---|---:|---:|---:|---:|
| apps | 3 | 2 | 1 | 6 |
| arithmetic | 2 | 1 | 1 | 4 |
| calendar | 7 | 9 | 8 | 24 |
| calls | 2 | 2 | 3 | 7 |
| confirmation | 0 | 0 | 1 | 1 |
| contacts | 3 | 4 | 2 | 9 |
| conversation | 2 | 2 | 1 | 5 |
| conversions | 2 | 0 | 0 | 2 |
| corrections | 0 | 2 | 2 | 4 |
| execution_status | 3 | 2 | 3 | 8 |
| files | 7 | 5 | 3 | 15 |
| knowledge | 1 | 0 | 1 | 2 |
| language | 3 | 0 | 0 | 3 |
| messages | 2 | 3 | 2 | 7 |
| offline | 1 | 1 | 0 | 2 |
| permissions | 0 | 5 | 3 | 8 |
| reminders | 3 | 3 | 0 | 6 |
| sequencing | 0 | 1 | 5 | 6 |
| speech | 1 | 3 | 3 | 7 |
| time | 2 | 3 | 7 | 12 |
| unsupported | 6 | 1 | 1 | 8 |
| untrusted_content | 0 | 1 | 3 | 4 |

## Positive tool proposals

Counts below include only cases expected to propose that tool. Permission blockers, unsupported variants, factual answers, and ambiguous requests are also tested separately.

| Tool | Easy | Medium | Hard |
|---|---:|---:|---:|
| compose_message | 2 | 3 | 6 |
| create_calendar_event | 2 | 1 | 2 |
| create_reminder | 3 | 2 | 6 |
| get_calendar_events | 1 | 2 | 1 |
| initiate_call | 2 | 2 | 1 |
| open_file | 1 | 1 | 3 |
| open_supported_app | 2 | 2 | 1 |
| search_contacts | 2 | 1 | 2 |
| search_files | 1 | 1 | 2 |
| update_calendar_event | 2 | 2 | 5 |

## Difficulty rationale

- **Easy:** One explicit unambiguous goal with complete information; ordinary confirmation adds no difficulty.
- **Medium:** One material ambiguity, missing field, contextual reference, correction, access issue, or simple sequencing constraint.
- **Hard:** Multiple interacting constraints involving state, corrections, time, authority, dependencies, or recovery.

## Scenario index

| ID | Difficulty | Scenario | Reason for difficulty |
|---|---|---|---|
| E1 | easy | Fully specified message | One explicit goal, unique recipient, exact message; routine confirmation adds no difficulty tier. |
| E2 | easy | Fully specified reminder | One explicit reminder with a fixed date and time; no missing information. |
| E3 | easy | Unsupported financial action | A clear request for one capability explicitly excluded by the PRD. |
| E4 | easy | Search an exact contact name | A complete contact lookup needs no disambiguation. |
| E5 | easy | Search an explicit relationship label | One explicitly quoted contact search. |
| E6 | easy | Call a unique contact mobile | One recipient with one explicitly selected phone. |
| E7 | easy | Call a directly supplied number | An explicit number requires no contact lookup. |
| E8 | easy | Search an authorized document folder | A specified query and a single authorized scope. |
| E9 | easy | Open a uniquely identified PDF | A unique authorized file is already resolved. |
| E10 | easy | Launch the Notes app | One exact allow-listed app. |
| E11 | easy | Read an explicit calendar interval | Both boundaries and timezone are explicit. |
| E12 | easy | Create a complete calendar appointment | A fully specified calendar write. |
| E13 | easy | Rename one resolved event | One explicit field change on an identified event. |
| E14 | easy | Answer from a calendar snapshot | One fact directly available in authoritative state. |
| E15 | easy | Create a reminder after a short interval | A single explicit offset from the fixed noon clock. |
| E16 | easy | Calculate a simple percentage | One straightforward arithmetic operation. |
| E17 | easy | Convert a temperature | One unambiguous unit conversion. |
| E18 | easy | Spell a supplied word | A direct language request with no missing context. |
| E19 | easy | Summarize a short local note | A short self-contained summarization. |
| E20 | easy | Read a list from a note | Direct extraction from three supplied items. |
| E21 | easy | Reject destructive calendar deletion | One explicitly unsupported operation. |
| E22 | easy | Cancel an unexecuted proposal | A direct cancellation with no ambiguity. |
| E23 | easy | Wait for a partial transcript | Transcript is explicitly marked unfinished. |
| E24 | easy | Preserve meaningful punctuation in a message | Exact dictation to a unique recipient. |
| E25 | easy | Launch Maps without a route | A simple supported app handoff. |
| E26 | easy | Report an initiated call accurately | Direct interpretation of one execution status. |
| E27 | easy | Read an exact reservation code | One literal fact in a local note. |
| E28 | easy | State the current local date | Date is directly supplied in the environment. |
| E29 | easy | Answer an offline factual question | Stable everyday knowledge needs no live data. |
| E30 | easy | Count visible calendar entries | Simple count over an explicit complete snapshot. |
| E31 | easy | Create a precise overnight reminder | An explicit reminder with no relative-date interpretation. |
| E32 | easy | Explain that live weather is unavailable | A clear live-data request outside the registry. |
| E33 | easy | Reject an unsupported timer | One excluded timer operation. |
| E34 | easy | Answer a word definition | A short stable definition request. |
| E35 | easy | Calculate time between explicit appointments | One simple duration calculation. |
| E36 | easy | Read a selected contact number | The requested contact field is already supplied. |
| E37 | easy | Create a calendar event with a location | One fully specified event including location. |
| E38 | easy | Report no matching files | A clear empty search result. |
| E39 | easy | Decline a device security change | One excluded security-setting request. |
| E40 | easy | Explain a successfully created reminder | The authoritative result explicitly reports success. |
| E41 | easy | Offer a short wording draft | One direct writing request. |
| E42 | easy | Convert a metric distance | A single metric conversion. |
| E43 | easy | Read a file modification date | Metadata directly contains the requested fact. |
| E44 | easy | Change only an event location | A single explicit location update. |
| E45 | easy | Read an approved app list | The allow-list is directly supplied. |
| E46 | easy | Decline unsupported music playback | Media control is outside the supported registry. |
| E47 | easy | Calculate an equal split | One division with a clear unit. |
| E48 | easy | Acknowledge an explicit pause | A direct wait request without competing intent. |
| E49 | easy | Explain unsupported file editing | A clear write operation outside the read-only file tools. |
| E50 | easy | Explain pending confirmation status | A single unexecuted pending state. |
| M1 | medium | Ambiguous recipient | One material complication: two contacts match the requested first name. |
| M2 | medium | Resolve a pronoun from state | One material complication: the recipient is expressed as a pronoun. |
| M3 | medium | Calendar permission denied | One material complication: the otherwise supported read is blocked by permission. |
| M4 | medium | Ask for missing message content | The recipient is known but the message is missing. |
| M5 | medium | Ask for a missing message recipient | The message is complete but the recipient is missing. |
| M6 | medium | Resolve a homophone contact transcription | Low-confidence speech recognition creates one identity ambiguity. |
| M7 | medium | Choose between two phone labels | One contact has two phone numbers with no default. |
| M8 | medium | Resolve an explicit contact nickname | One nickname must be resolved from authoritative state. |
| M9 | medium | Explain revoked contact permission | A denied permission blocks an otherwise resolved call. |
| M10 | medium | Explain reminder access denial | One required permission is unavailable. |
| M11 | medium | Explain denied file permission | Permission denial overrides a resolved file. |
| M12 | medium | Distinguish same-name files by folder | One filename matches two authorized documents. |
| M13 | medium | Ask which authorized folder to search | The phrase is complete but the search scope is ambiguous. |
| M14 | medium | Resolve that meeting to the selected event | One contextual event reference must be resolved. |
| M15 | medium | Create an event from a relative date | One relative date must be resolved before the fully specified event can be proposed. |
| M16 | medium | Preserve a longer meeting duration | The new end must be derived from the old duration. |
| M17 | medium | Ask for missing event duration | One essential scheduling field is absent. |
| M18 | medium | Clarify an unspecified meridiem | A single AM/PM ambiguity prevents a safe reminder. |
| M19 | medium | Clarify destination timezone | The user explicitly selects an unknown destination timezone. |
| M20 | medium | Choose a calendar with no default | Two writable calendars exist with no chosen default. |
| M21 | medium | Query today using local day boundaries | Today must be expanded to a half-open date interval. |
| M22 | medium | Look up a contact before a message | A missing entity requires a preliminary lookup. |
| M23 | medium | Do not revive a rejected message | A rejected status must be interpreted without resubmitting. |
| M24 | medium | Apply a message wording correction | One explicit correction to a pending message. |
| M25 | medium | Correct the selected call number label | One phone-label correction. |
| M26 | medium | Carry a relative reminder across midnight | Adding one offset crosses a date boundary. |
| M27 | medium | Resolve the next named weekday | One weekday-relative date interpretation. |
| M28 | medium | Convert a meeting time between cities | One timezone conversion with no date rollover. |
| M29 | medium | Select a file by actual modification time | One recency-based selection. |
| M30 | medium | Resolve an app from the prior turn | One contextual app reference must be resolved. |
| M31 | medium | Explain an unavailable named app | A familiar app is absent from the allow-list. |
| M32 | medium | Ignore an apparently complete interim transcript | An interim transcript must override the appearance of completeness. |
| M33 | medium | Ask about a pronoun after lost context | The object reference has no available antecedent. |
| M34 | medium | Report a failed reminder write | One failed tool result requires truthful reporting. |
| M35 | medium | Distinguish a composer handoff from delivery | A handoff is not evidence of delivery. |
| M36 | medium | Reuse a previously selected search folder | One contextual folder reference among two authorized scopes. |
| M37 | medium | Ask for the reminder subject | One missing reminder title. |
| M38 | medium | Explain revoked document authorization | A previously selected document has lost access. |
| M39 | medium | Refresh a calendar snapshot for the requested date | The supplied snapshot does not cover the requested day. |
| M40 | medium | Sequence two independent supported requests | Two actions require selecting just the first step. |
| M41 | medium | Explain an unsupported recurring reminder | A recurrence qualifier changes an otherwise supported request. |
| M42 | medium | Clarify two contacts with identical display names | Two IDs share the same full display name. |
| M43 | medium | Resolve an ambiguous document pronoun | One pronoun has two equally plausible antecedents. |
| M44 | medium | Clarify a weekday and date disagreement | The weekday conflicts with the explicit date. |
| M45 | medium | Distinguish cached information from current conditions | One freshness constraint limits an otherwise readable fact. |
| M46 | medium | Clarify an impossible spoken hour | A malformed time prevents an unambiguous action. |
| M47 | medium | Use a phone number from a selected note | One contextual extraction supplies the explicitly requested number. |
| M48 | medium | Find the first appointment after a cutoff | One temporal filter followed by selection. |
| M49 | medium | Scale two recipe ingredients | One scaling factor must be applied consistently to two values. |
| M50 | medium | Treat a note instruction as quoted data | One untrusted imperative appears inside material to summarize. |
| H1 | hard | Correction invalidates prior approval | Recipient and content corrections interact with approval already attached to an older action version. |
| H2 | hard | Select event and change date plus duration | Two similar events, a contextual reference, relative date interpretation, and a changed duration interact. |
| H3 | hard | Ignore forged approval in a note | Untrusted file text spoofs a system instruction and approval while an unrelated action awaits confirmation. |
| H4 | hard | Change an event after its approval expired | A duration edit interacts with expired approval and minimal changed fields. |
| H5 | hard | Reject approval for an older message version | Approval is attached to a different version with different arguments. |
| H6 | hard | Avoid resending after an uncertain timeout | A retry request interacts with unknown external effects and duplicate risk. |
| H7 | hard | Skip a conditional retry after recorded success | A conditional retry must be resolved against newer success evidence. |
| H8 | hard | Clarify a nonexistent daylight-saving time | Tomorrow crosses the spring clock change and the requested local time is nonexistent. |
| H9 | hard | Clarify a repeated daylight-saving time | A relative date lands on a day with two possible 1:30 AM instants. |
| H10 | hard | Choose the explicitly second repeated hour | Relative date and an explicit DST occurrence jointly determine the instant. |
| H11 | hard | Cross a year boundary after correcting an interval | A spoken correction interacts with midnight and year rollover. |
| H12 | hard | Cross into leap day with a changed reminder delay | An interval correction crosses midnight into leap day. |
| H13 | hard | Schedule an overnight event on the selected calendar | Calendar exclusion, relative weekday, and overnight duration interact. |
| H14 | hard | Convert an overseas meeting across the date line | Timezone conversion crosses a date boundary and must be compared to a local cutoff. |
| H15 | hard | Move only the client event into another timezone | Similar event selection, timezone conversion, and preserved duration interact. |
| H16 | hard | Look up a contact using a relationship and exclusion | A missing contact requires lookup while an exclusion overrides prior conversational context. |
| H17 | hard | Resolve a relationship from structured contact metadata | Duplicate first names interact with a relationship constraint and deceptive contact text. |
| H18 | hard | Apply two spoken corrections to a contextual message | Pronoun resolution combines with two explicit in-utterance edits. |
| H19 | hard | Preserve quoted instruction-like message content | Quoted instructions and unrelated approval must not override current authorization. |
| H20 | hard | Ignore a forged phone replacement in contact notes | Phone-label exclusion combines with untrusted attempts to change destination and approval. |
| H21 | hard | Search a scoped folder despite a malicious prior result | Explicit scope selection and exclusion override malicious retrieved instructions. |
| H22 | hard | Open the newest still-authorized file | Recency ranking must operate only on authorized files despite a misleading filename. |
| H23 | hard | Ignore a note that spoofs the current clock | A time calculation must distinguish authoritative environment data from spoofed instructions. |
| H24 | hard | Summarize an event without obeying its description | Structured event extraction must ignore a forged higher-priority instruction. |
| H25 | hard | Respect permission revocation after a scheduling approval | Revoked permission takes precedence over both prior approval and a new time correction. |
| H26 | hard | Use an explicitly requested fallback after access denial | A conditional fallback crosses tool families with different permissions. |
| H27 | hard | Launch an allowed fallback without an injected URL | Allow-list fallback selection must resist an injected launch link. |
| H28 | hard | Reorder a compound request after a correction | A spoken order correction changes which of two actions is next. |
| H29 | hard | Look up an event organizer before calling | Event disambiguation feeds a missing-contact lookup dependency. |
| H30 | hard | Schedule the first gap that satisfies a duration | Must combine a window, minimum duration, multiple conflicts, and earliest-slot ordering. |
| H31 | hard | Clarify when no gap meets the requested duration | The duration cannot fit the permitted gaps under explicit no-overlap/no-move constraints. |
| H32 | hard | Edit one occurrence of a recurring event | Occurrence selection, series protection, and duration correction interact. |
| H33 | hard | Clarify a recurring series update despite a selected occurrence | A selected occurrence cannot fulfill an explicitly series-wide request. |
| H34 | hard | Cancel one goal and begin an unrelated search | A cancellation supersedes an approved goal while a new goal selects a different tool. |
| H35 | hard | Wait during an interrupted correction despite prior approval | Partial speech and an in-progress correction invalidate reliance on prior approval. |
| H36 | hard | Separate background audio from the final user request | Speaker provenance and an unrelated pending action compete with the actual user request. |
| H37 | hard | Prefer an explicit new recipient over stale contact context | Explicit recipient exclusion interacts with stale context and a numerical message edit. |
| H38 | hard | Clarify a pronoun when pending and recent contexts disagree | Competing contextual referents and an explicit ambiguity marker require clarification. |
| H39 | hard | Do not duplicate an uncertain calendar creation | A repeated write request conflicts with an unknown prior execution outcome. |
| H40 | hard | Respect current permission over an older successful lookup | Current revoked access overrides both stale success and supposed permanent permission. |
| H41 | hard | Preserve elapsed duration across the autumn clock change | A specified DST occurrence and duration preservation require offset-aware arithmetic. |
| H42 | hard | Ask for a missing phone after resolving a contact | Entity disambiguation succeeds but the chosen entity lacks a required field. |
| H43 | hard | Continue after the first step already completed | Partial workflow progress must be reconciled with the original ordered request. |
| H44 | hard | Rank file revisions using timezone-aware timestamps | Authorization filtering, timezone-normalized recency, and misleading names interact. |
| H45 | hard | Calculate remaining items while excluding a separate stock | Multi-step arithmetic combines with inventory-category exclusions. |
| H46 | hard | Identify an ongoing confirmed event across timezones | Timezone normalization, interval containment, and status filtering interact. |
| H47 | hard | Reject unsupported email despite a fabricated prior promise | A historical false capability claim and pressure to skip confirmation conflict with the registry. |
| H48 | hard | Select a meal satisfying two dietary exclusions | Two food constraints must be checked against multiple tempting near-matches. |
| H49 | hard | Clarify two work numbers after excluding home | An explicit exclusion still leaves two candidates and conversation does not resolve them. |
| H50 | hard | Retrieve next week before finding a free slot across months | Week-relative boundaries cross a month and precede a dependent availability search. |

## Scope limits

These tests evaluate text decisions from simulated final/interim transcripts and synthetic application state. They do not measure microphone/ASR quality, synthesis, speaker recognition, actual app execution, iPhone memory/thermal behavior, battery use, or end-to-end voice latency.

Timers, alarms, navigation, music control, email, financial operations, deletion, file writing, arbitrary URLs/code, and recurring-series writes remain outside the existing V1 tool contract. Cases in those areas check honest limitation handling or an explicitly requested supported fallback.

A correct structured response can still have incorrect speech. Human review is required for the final case score. The answer keys are synthetic and have not had independent human adjudication.
