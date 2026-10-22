# Test fixtures

- `overpass_portland_downtown.json`, `overpass_portland_i5.json`: real Overpass API responses
  (roads within 300–400 m of downtown Portland and of I-5 near the Rose Quarter), fetched 2026-10-21.
  Data © OpenStreetMap contributors, available under the Open Database License (ODbL):
  https://www.openstreetmap.org/copyright
- `nhtsa_v07605_frontal_35mph.json` (2012 Toyota Yaris, 35 mph NCAP frontal barrier) and
  `nhtsa_v07602_side_struck_while_stopped.json` (2012 Toyota Yaris, NCAP side impact by a moving
  barrier): cabin-floor accelerometers from the NHTSA Vehicle Crash Test Database (public domain,
  https://nrd.api.nhtsa.dot.gov), converted to g and averaged into 100 Hz samples by
  `Tools/StressLab/fetch_datasets.py`.
- `motionsense_wlk7_sub24_60-70s.csv`: 10 s of brisk walking (iPhone 6s Core Motion, 50 Hz) from the
  MotionSense dataset (MIT license; Malekzadeh et al., "Mobile Sensor Data Anonymization", IoTDI'19,
  https://github.com/mmalekzadeh/motion-sense). It once caused a false crash check-in.
