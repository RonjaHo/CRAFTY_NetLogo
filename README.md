# 📘 CRAFTY_NetLogo

**CRAFTY_NetLogo** is a **NetLogo implementation of the agent-based land-use modelling framework CRAFTY**, originally developed in Java  
👉 https://github.com/CRAFTY-ABM/CRAFTY_v2/tree/master

This version uses a **stylised 2D grid landscape** and introduces a **new behavioural extension** that incorporates:

- **Environmental attitudes**  
- **Behavioural inertia**  
- **Descriptive social norms**  
- Optional **heterogeneous behavioural parameters from CSV files**  
- Optional **dynamic, time-varying environmental attitudes**

The model simulates how land managers (agents) adjust their land-use intensity in response to **ecosystem service demand**, **local and teleconnected social networks**, **capital levels**, and **behavioural factors**.  
It illustrates how spatial land-use patterns emerge from intertwined economic, environmental, and socio-psychological processes.

---

## 📁 Repository Structure

```text
CRAFTY_NetLogo/
│
├── model/
│   └── CRAFTY.nlogo                 # NetLogo model file
│
├── data/
│   ├── ElevationData.csv            # Required: landscape elevation (101×101)
│   ├── MaxGivingInThresholdData.csv # Optional per-cell behavioural parameters
│   ├── NormWeightData.csv
│   ├── NormSensitivityData.csv
│   ├── InertiaData.csv
│   ├── AttitudeMeanTimeSeries.zip   # Optional dynamic attitude time series (ZIP)
│   └── (unzip to obtain AttitudeMeanTimeSeries.csv)
│
└── README.md
