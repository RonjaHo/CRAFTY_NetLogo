# CRAFTY_NetLogo

**CRAFTY_NetLogo** is a **NetLogo implementation of the agent-based land-use modelling framework CRAFTY**, originally developed in Java  
https://github.com/CRAFTY-ABM/CRAFTY_v2/tree/master

This version uses a **stylised 2D grid landscape** and introduces a **new behavioural extension** that incorporates:

- **Environmental attitudes**  
- **Behavioural inertia**  
- **Descriptive social norms**  
- Optional **heterogeneous behavioural parameters from CSV files**  
- Optional **dynamic, time-varying environmental attitudes**

The model simulates how land managers (agents) adjust their land-use intensity in response to **ecosystem service demand**, **local and teleconnected social networks**, **capital levels**, and **behavioural factors**.  
It illustrates how spatial land-use patterns emerge from intertwined economic, environmental, and socio-psychological processes.

---

## Repository Structure

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

## Model Description (Short)

This model follows CRAFTY’s core structure.

### Agent Functional Types (AFTs)

Each patch represents a land manager belonging to one of three AFTs:

- High-Intensity  
- Mid-Intensity  
- Conservation  

AFTs differ in:

- sensitivity to productive vs. natural capital  
- production of material vs. non-material ecosystem services  
- colour (dark green = High-Intensity, bright green = Conservation)  

### Decision-Making

At each tick, a subset of patches engages in competition.  
Agents may switch AFT based on:

- Economic competitiveness (residual demand × production capacity)  
- Environmental attitude  
- Descriptive social norms, based on local + teleconnected peers  
- Behavioural inertia  
- A giving-in threshold, calculated with a logistic function  

### Behavioural Extensions (new contribution)

#### ✓ Per-patch behavioural heterogeneity (via optional CSV files)

Each land manager can have unique values for:

- environmental attitude  
- norm weight  
- norm sensitivity  
- inertia  
- giving-in threshold  

#### ✓ Dynamic environmental attitudes (per-patch × time step CSV)

Environmental attitudes can evolve over time, enabling:

- behavioural trends  
- shocks  
- scenario pathways  

---

## CSV File Formats

### Per-cell behavioural parameters

All behavioural CSVs must be:

- 101 rows × 101 columns  
- same orientation as `ElevationData.csv`  
- values in **[0, 1]**

### Dynamic attitude time series

The dynamic CSV must be:

- **10,201 rows** (one per patch, flattened row-major order: top-left → right → next row, etc.)  
- **T columns**, one per time step (e.g., 300)  
- values in **[-1, 1]**

---

## Running the Model

1. **Configure behavioural and environmental options**  
   (Choose attitude distribution, CSV loading options, behavioural parameters, production function, etc.)

2. **Press SETUP**  
   Initialises capitals, behavioural parameters, AFTs, and networks.

3. **Press GO**  
   Starts the simulation.

Plots display:

- global supply vs. demand of ecosystem services  
- land-use intensity shares  
- landscape connectivity metrics  

---

## Documentation

Additional documentation is available in the **Model Info** tab inside the `.nlogo` model, including:

- behavioural equations  
- AFT specification  
- capital → production mapping  
- neighbourhood and teleconnection logic  
- clustering & connectivity metrics  
- CSV-handling mechanism  

---

## Related Framework

This model builds on the **CRAFTY** land-use modelling framework:  
https://github.com/CRAFTY-ABM/CRAFTY_v2/tree/master
