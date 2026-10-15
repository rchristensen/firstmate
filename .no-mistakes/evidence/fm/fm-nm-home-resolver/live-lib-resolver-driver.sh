#!/usr/bin/env bash
# usage: drive.sh <repo-root> <lab>
R=$1 L=$2 FMH=$L/fmhome
run() { echo "\$ $*"; env -u NM_HOME -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE HOME=$L/acct FM_HOME=$FMH "$@" 2>&1; echo "[rc=$?]"; }
lib() { run bash -c '. "$1/bin/fm-nm-run-lib.sh"; shift; "$@"' _ "$R" "$@"; }
echo "=== S1 baseline: no config/nm-home-resolver -> ambient home (HOME=$L/acct) ==="
rm -f $FMH/config/nm-home-resolver
lib fm_nm_run $L/wt 15 runs --limit 5
lib fm_nm_run $L/wt 15 daemon status
lib fm_nm_state_db $L/wt
echo
echo "=== S2 opt-in: config/nm-home-resolver -> $L/resolver ==="
printf '%s\n' $L/resolver > $FMH/config/nm-home-resolver
: > $L/resolver-calls
lib fm_nm_run $L/wt 15 runs --limit 5
lib fm_nm_run $L/wt 15 daemon status
lib fm_nm_run $L/wt 15 axi status --run 01LABRUNDONE
lib fm_nm_state_db $L/wt
echo "resolver was called with:"; sort -u $L/resolver-calls
echo
echo "=== S3 explicit NM_HOME wins (NM_HOME=$L/explicit) ==="
mkdir -p $L/explicit; : > $L/resolver-calls
echo "\$ NM_HOME=$L/explicit fm_nm_run wt runs"; env -u FM_CONFIG_OVERRIDE HOME=$L/acct FM_HOME=$FMH NM_HOME=$L/explicit bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run "$2" 15 runs --limit 5; echo "[rc=$?]"; fm_nm_state_db "$2"' _ "$R" $L/wt 2>&1
echo "resolver calls: $(wc -l < $L/resolver-calls)"
echo
echo "=== S4 scope: out-of-scope 'daemon stop' keeps ambient home; wsA daemon must survive ==="
: > $L/resolver-calls
lib fm_nm_run $L/wt 15 daemon stop
echo "resolver calls: $(wc -l < $L/resolver-calls)"
echo "\$ NM_HOME=$L/wsA no-mistakes daemon status"; HOME=$L/acct NM_HOME=$L/wsA no-mistakes daemon status
echo
echo "=== S5 unusable resolver answers fall back to ambient ==="
for mode in fail nonexistent relative twolines; do
  case $mode in
    fail) body='exit 3' ;;
    nonexistent) body="echo $L/no-such-home" ;;
    relative) body='echo wsA' ;;
    twolines) body="printf '%s\n%s\n' $L/wsA $L/wsA" ;;
  esac
  printf '#!/usr/bin/env bash\n%s\n' "$body" > $L/bad-resolver; chmod +x $L/bad-resolver
  printf '%s\n' $L/bad-resolver > $FMH/config/nm-home-resolver
  echo "--- resolver mode: $mode"
  lib fm_nm_state_db $L/wt
  [ -e $L/no-such-home ] && echo "!! no-such-home was created" || echo "no-such-home not created"
done
printf 'relative-resolver\n' > $FMH/config/nm-home-resolver
echo "--- config names a relative path"; lib fm_nm_state_db $L/wt
printf '%s\n' $L/resolver > $FMH/config/nm-home-resolver
