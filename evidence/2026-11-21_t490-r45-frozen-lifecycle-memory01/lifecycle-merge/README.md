# Lifecycle merge attempts

`ledger.jsonl` / `summary.json` are the first merge attempt. At that point the raw PPM had not been copied into the evidence directory, so the merge correctly rejected its strict screenshot hash check; these files are retained as an audit trail and are not the final merge result.

`ledger-ppm.jsonl` / `summary-ppm.json` are the second attempt, using a temporary copy of the T490 initial strict PPM at `tmp/r45-ppm/stability/load-00-initial.ppm`. Its SHA-256 matched the recorded screenshot hash. This merge still correctly reports `valid=false`: no `renderer_ready` and no `first_valid_frame` exist for `nav-00`. The temporary raw PPM is outside the committed evidence bundle; the committed top-level PPM index points to the original on T490.
