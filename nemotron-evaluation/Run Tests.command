#!/bin/bash
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/nemotron-pilot"
bash run-on-brev.sh run
result=$?
if [ "$result" -eq 0 ]; then bash run-on-brev.sh report; fi
printf '\nPress Return to close this window.'
read -r
exit "$result"
