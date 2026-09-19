#!/usr/bin/env python3
"""Generate a coverage manifest from explicit cases. No model or network access."""
import collections
import json
import pathlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
 data=json.loads((ROOT/'cases.json').read_text())
 cases=data['cases'];tiers=('easy','medium','hard')
 lines=['# Coverage: 150 local voice-assistant scenarios','',
        '50 easy + 50 medium + 50 hard. Every scenario has its own request, state, answer key, difficulty rationale, and speech-review criteria. No model evaluation has been performed for this dataset.','',
        'The original E1–E3, M1–M3, and H1–H3 remain as known development cases. The additional 141 scenarios are explicitly authored in `datasets/build_cases.py`; they are not produced by randomizing names or repeating requests. The set is exposed development material, not a hidden benchmark.','',
        '## Primary task categories','', '| Category | Easy | Medium | Hard | Total |','|---|---:|---:|---:|---:|']
 for category in sorted({c['category'] for c in cases}):
  cs=[c for c in cases if c['category']==category]
  counts=[sum(c['difficulty']==t for c in cs) for t in tiers]
  lines.append('| %s | %s | %s | %s | %s |'%(category,*counts,len(cs)))
 lines+=['','## Positive tool proposals','',
         'Counts below include only cases expected to propose that tool. Permission blockers, unsupported variants, factual answers, and ambiguous requests are also tested separately.','',
         '| Tool | Easy | Medium | Hard |','|---|---:|---:|---:|']
 for tool in sorted({c['expected']['tool'] for c in cases if c['expected']['tool']}):
  counts=[sum(c['difficulty']==t and c['expected']['tool']==tool for c in cases) for t in tiers]
  lines.append('| %s | %s | %s | %s |'%(tool,*counts))
 lines+=['','## Difficulty rationale','']
 lines += ['- **%s:** %s'%(t.title(),data['difficulty_rubric'][t]) for t in tiers]
 lines+=['','## Scenario index','', '| ID | Difficulty | Scenario | Reason for difficulty |','|---|---|---|---|']
 for c in cases: lines.append('| %s | %s | %s | %s |'%(c['id'],c['difficulty'],c['title'],c['rationale']))
 lines+=['','## Scope limits','',
         'These tests evaluate text decisions from simulated final/interim transcripts and synthetic application state. They do not measure microphone/ASR quality, synthesis, speaker recognition, actual app execution, iPhone memory/thermal behavior, battery use, or end-to-end voice latency.','',
         'Timers, alarms, navigation, music control, email, financial operations, deletion, file writing, arbitrary URLs/code, and recurring-series writes remain outside the existing V1 tool contract. Cases in those areas check honest limitation handling or an explicitly requested supported fallback.','',
         'A correct structured response can still have incorrect speech. Human review is required for the final case score. The answer keys are synthetic and have not had independent human adjudication.','']
 (ROOT/'COVERAGE.md').write_text('\n'.join(lines))
 print(ROOT/'COVERAGE.md')
if __name__=='__main__':main()
