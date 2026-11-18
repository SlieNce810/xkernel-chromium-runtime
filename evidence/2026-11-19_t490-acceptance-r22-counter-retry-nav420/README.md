# R22 counter ROI correction evidence

R22 passed strict readiness, JavaScript self-test, and keyboard echo. The as-run gate marked the mouse counter as passed, but visual and PPM review showed the counter remained 0. The old ROI included the cursor shape. Rechecking the same raw pair with the digit-only ROI produced zero changed pixels, so the counter result is FAIL and the fallback had not run.

The CSS link did not navigate. The full non-PPM session bundle and remote-verified PPM hash list are archived in the session folder and the parent evidence manifest. The original PPM files remain on T490.

See [report 325](../../report/325-T490-2GiB输入尝试r22数字ROI修正光标假阳性-20261119.md).
