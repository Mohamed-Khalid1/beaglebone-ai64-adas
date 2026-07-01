# Sample input

`sample.jpg` is one CARLA frame from the calibration set, committed so the runtime can
be demonstrated with **zero external data** — feed it to the YOLO runtime to get a
detection overlay without needing the live MQTT/CARLA feed.

```bash
# from deploy/ , after ./fetch_artifacts.sh
python3 runtime/yolo_runtime.py --image samples/sample.jpg   # see runtime/ for exact flags
```

For the full live pipeline (MQTT frames from CARLA → C7x → ADAS alerts) see
[`../README.md`](../README.md) and [`../run_native.sh`](../run_native.sh).
