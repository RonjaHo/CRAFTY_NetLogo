extensions [csv]

patches-own [
  ;; agents are simulated as patches to save computational costs
  elevation                              ;; elevation value for this patch (0–1)
  capital_list                           ;; [productive_capital, natural_capital]
  AFT                                    ;; agent functional type: "conservation" | "medium_intensity" | "high_intensity"
  intensity                              ;; 0 = conservation, 1 = medium_intensity, 2 = high_intensity
  sensitivity_list                       ;; [sens_material, sens_non_material]
  opt_prod_list                          ;; [opt_material, opt_non_material] (Cobb–Douglas prefactors; dummy for linear)
  production_list                        ;; [material_production, non_material_production]
  competitiveness                        ;; Σ_s residual_demand_s * production_s
  GI_threshold                           ;; giving-in threshold
  environmental_attitude                 ;; attitude to extensify land use (−1 … +1); + = extensify, − = intensify
  social_influence                       ;; social influence term (−1 … +1)
  attitude_influence                     ;; attitude influence term (−1 … +1)
  connections                            ;; social network connections (agentset of patches)
  neighbourhood                          ;; local neighbourhood (agentset of patches in given radius)
  ;; per-patch behavioural parameters
  p_max_giving_in_threshold
  p_norm_weight
  p_norm_sensitivity
  p_inertia

  ;; for time-varying attitude_mean loaded from CSV
  p_attitude_mean_series   ;; list [t0, t1, t2, ...] for this patch


  ;; clustering / landscape measures
  group-id
  group-perimeter
  group-area
  group-shape-index
]

globals [
  AFT_list                 ;; names in index order [conservation, medium, high]
  AFT_sensitivities_list   ;; per-AFT sensitivities
  AFT_opt_prod_list        ;; per-AFT optimal production levels
  AFT_color_list           ;; per-AFT colours (conservation, medium, high)

  global_production_list   ;; total production [material, non_material]
  demand_list              ;; [demand_material, demand_non_material]
  res_demand_list          ;; demand − supply

  mean_comp_high_intensity
  mean_comp_medium_intensity
  mean_comp_conservation

  num_patches
  material_services_production
  non_material_services_production

  ;; equilibrium tracking
  num_conservation_previous
  stable-count

  ;; landscape metrics
  group-id-list
  perimeter-list
  area-list
  shape-index-list
  mesh-cwa
  mesh
  total-complexity-area
]

;; ===========================
;; Setup
;; ===========================

to setup
  clear-all
  initialize-globals
  initialize-network
  initialize-land-map
  ;; compute initial totals from the initial land-use configuration
  set global_production_list [0 0]
  patches-produce
  reset-ticks
end

;; ---- setup helpers ----

to initialize-globals
  ;; Order is [conservation, medium_intensity, high_intensity]
  set AFT_list ["conservation" "medium_intensity" "high_intensity"]

  ifelse (production_function = "linear") [
    ;; Each entry is [sens_material, sens_non_material]
    ;; Conservation favours natural (0,1), Medium balanced (0.5,0.5), High favours productive (1,0)
    set AFT_sensitivities_list [ [0 1] [0.5 0.5] [1 0] ]
    set AFT_opt_prod_list [1 2 3]  ;; dummy (not used by linear)
  ] [
    ;; Cobb–Douglas exponents are sensitivities to productive capital; sens_natural = 1 − sens_productive
    ;; Conservation (more extensive) → lower productive sensitivity; High → higher productive sensitivity
    set AFT_sensitivities_list [ [0.5 0] [0.7 0] [1 0] ]
    set AFT_opt_prod_list [ [0.2 1] [0.8 0.5] [1 0] ]
  ]

  ;; Colours ordered [conservation, medium, high]; 57≈light green, 55≈medium, 53≈dark
  set AFT_color_list [57 55 53]

  ;; Demands from interface sliders
  set demand_list (list demand_material_services demand_non_material_services)

  ;; equilibrium counters are set once the map is initialised
  set stable-count 0
  set num_conservation_previous 0
end

to initialize-network
  ask patches [
    set neighbourhood patch-set (patches in-radius connection_radius) with [self != myself]
    set connections neighbourhood
  ]

  ;; Add teleconnections (long-range links)
  repeat random_links [
    let p1 one-of patches
    let p2 one-of patches
    if (p1 != p2) and (not member? p2 [connections] of p1) [
      ask p1 [ set connections (patch-set connections p2) ]
      ask p2 [ set connections (patch-set connections p1) ]
    ]
  ]
end

to initialize-land-map
  let elevation_data csv:from-file "../data/EleviationData.csv"
  resize-world 0 (length elevation_data - 1) 0 (length elevation_data - 1)
  set-patch-size 8

  ;; OPTIONAL CSVs for behaviour, only used if load_behaviour_from_csv = true
  let max_giving_in_threshold_data []
  let norm_weight_data []
  let norm_sensitivity_data []
  let inertia_data []

  ;; OPTIONAL CSV for dynamic attitude,  only used if
  let attitude_mean_series_data []  ;; per patch × time

  if load_behaviour_from_csv [
    set max_giving_in_threshold_data csv:from-file "../data/MaxGivingInThresholdData.csv"
    set norm_weight_data             csv:from-file "../data/NormWeightData.csv"
    set norm_sensitivity_data        csv:from-file "../data/NormSensitivityData.csv"
    set inertia_data                 csv:from-file "../data/InertiaData.csv"
  ]

  ;; time-varying attitude_mean:
  ;; CSV shape: one row per patch (flattened), one column per time step
  if attitude_distribution = "dynamic_from_csv" [
    set attitude_mean_series_data    csv:from-file "../data/AttitudeMeanTimeSeries.csv"
  ]

  let row 0
  let column 0
  while [row <= max-pycor] [
    set column 0
    while [column <= max-pxcor] [
      ask patch column row [
        set elevation item column item (max-pycor - row) elevation_data
        set capital_list (list (generate-material-capitals elevation)
          (generate-natural-capitals elevation))

        ;; --- per-patch behavioural parameters ---
        ifelse load_behaviour_from_csv [
          set p_norm_weight              item column item (max-pycor - row) norm_weight_data
          set p_norm_sensitivity         item column item (max-pycor - row) norm_sensitivity_data
          set p_inertia                  item column item (max-pycor - row) inertia_data
          set p_max_giving_in_threshold  item column item (max-pycor - row) max_giving_in_threshold_data
        ]
        [
          ;; NO CSV: copy slider values into per-patch parameters
          set p_max_giving_in_threshold max_giving_in_threshold
          set p_norm_weight             norm_weight
          set p_norm_sensitivity        norm_sensitivity
          set p_inertia                 inertia
        ]

        ;; --- environmental attitude initialisation ---
        ifelse attitude_distribution = "dynamic_from_csv" [
          ;; For dynamic_from_csv, each patch gets a time series of attitude means.
          ;; We flatten (row, column) into a single row index for the CSV.
          let flat-row ((max-pycor - row) * world-width + (column - min-pxcor))

          ;; row of CSV corresponding to this patch: [t0 t1 t2 ...]
          set p_attitude_mean_series item flat-row attitude_mean_series_data
          ; environmental_attitude will be set in go procedure
        ]
        [
          ;; Other cases:
          set environmental_attitude (ifelse-value
            attitude_distribution = "random_distribution"
            [ precision (random-normal attitude_mean attitude_std_dev) 1 ]
            attitude_distribution = "spatial_distribution"
            [ generate-intensity-attitude pxcor pycor ]
            [ attitude_mean ])
        ]


        ;; AFT initialisation
        let i 0
        ifelse equal_initial_distribution [
          set i random 3
        ] [
          let r random-float 1
          ifelse r < init_share_high [
            set i 2
            ] [ ifelse r < (init_share_high + init_share_medium) [
              set i 1
            ] [
              set i 0
            ]
          ]
        ]
        set AFT (item i AFT_list)
        set intensity i
        set sensitivity_list (item i AFT_sensitivities_list)
        set opt_prod_list (item i AFT_opt_prod_list)
        set pcolor (item i AFT_color_list)
        set GI_threshold 0.5
      ]
      set column column + 1
    ]
    set row row + 1
  ]
  set num_patches count patches
  set num_conservation_previous count patches with [AFT = "conservation"]
end

;; ===========================
;; Go
;; ===========================

to go
  ;; update attitude if dynamic attitude option chosen
  if attitude_distribution = "dynamic_from_csv" [
    update-attitude-mean-from-series ;; uses column 0 on first call
  ]

  set global_production_list [0 0]
  patches-produce
  patches-compete

  ;; stop when conservation share stabilizes
  let num_conservation_current count patches with [AFT = "conservation"]
  if abs (num_conservation_previous - num_conservation_current) < 1 [
    set stable-count stable-count + 1
  ]
  if abs (num_conservation_previous - num_conservation_current) >= 1 [
    set stable-count 0
  ]
  set num_conservation_previous num_conservation_current

  if ticks >= 400 [ stop ]

  tick
end

;; ---- go procedures ----

to patches-produce
  ask patches with [pcolor != black] [
    set production_list generate-production-list capital_list sensitivity_list opt_prod_list
    set global_production_list (map [[a b] -> a + b] global_production_list production_list)
  ]
  set material_services_production     item 0 global_production_list
  set non_material_services_production item 1 global_production_list
  set res_demand_list (map [[a b] -> a - b] demand_list global_production_list)
end

to patches-compete
  ask patches with [pcolor != black] [
    set competitiveness sum (map [[a b] -> a * b] res_demand_list production_list)
    if (not negative_competitiveness) and (competitiveness < 0) [ set competitiveness 0 ]
  ]

  let min_comp min [competitiveness] of patches
  let max_comp max [competitiveness] of patches
  let range_comp (max_comp - min_comp)
  if range_comp = 0 [ set range_comp 1 ]  ;; avoid divide-by-zero in normalisation

  set mean_comp_high_intensity   (ifelse-value any? patches with [AFT = "high_intensity"]   [mean [competitiveness] of patches with [AFT = "high_intensity"]]   [0])
  set mean_comp_medium_intensity (ifelse-value any? patches with [AFT = "medium_intensity"] [mean [competitiveness] of patches with [AFT = "medium_intensity"]] [0])
  set mean_comp_conservation     (ifelse-value any? patches with [AFT = "conservation"]     [mean [competitiveness] of patches with [AFT = "conservation"]]     [0])

  let num_selec_patches round (pct_compete * 0.01 * num_patches)
  let selec_patches n-of num_selec_patches patches with [pcolor != black]

  ask selec_patches [
    let i intensity
    let j random 3
    while [j = i] [ set j random 3 ]

    let sensitivity_competitor_list (item j AFT_sensitivities_list)
    let opt_prod_competitor_list     (item j AFT_opt_prod_list)
    let production_competitor_list generate-production-list capital_list sensitivity_competitor_list opt_prod_competitor_list

    let competitiveness_competitor sum (map [[a b] -> a * b] res_demand_list production_competitor_list)

    ;; Normalise to [0,1]
    set competitiveness            (competitiveness            - min_comp) / range_comp
    set competitiveness_competitor (competitiveness_competitor - min_comp) / range_comp

    ;; Social influence term (−1..1). With intensity 0=conservation, 2=high.
    let N count connections
    ifelse j > i [
      ;; moving to higher intensity → look for peers with intensity ≥ j
      set social_influence 2 * ( (count connections with [intensity >= j]) / max list 1 N - p_norm_sensitivity)
    ] [
      ;; moving to lower intensity (towards conservation) → look for peers with intensity ≤ j
      set social_influence 2 * ( (count connections with [intensity <= j]) / max list 1 N - p_norm_sensitivity)
    ]
    set social_influence max list -1 (min list 1 social_influence)

    set attitude_influence environmental_attitude * (i - j) / abs (j - i)
    set attitude_influence max list -1 (min list 1 attitude_influence)

    set GI_threshold 1 / (1 + exp ( logistic_steepness * ((1 - p_norm_weight) * attitude_influence + p_norm_weight * social_influence - p_inertia * abs (j - i))))

    if (competitiveness_competitor > competitiveness + p_max_giving_in_threshold * GI_threshold) [
      set AFT (item j AFT_list)
      set intensity j
      set sensitivity_list (item j AFT_sensitivities_list)
      set opt_prod_list (item j AFT_opt_prod_list)
      set pcolor (item j AFT_color_list)
    ]
  ]
end

to update-attitude-mean-from-series
  ;; ticks = 0 at the very beginning, 1 after first go, etc.
  let t ticks
  ask patches [
    ;; p_attitude_mean_series was filled in initialize-land-map for this patch
    if t < length p_attitude_mean_series [
      set environmental_attitude item t p_attitude_mean_series
    ]
    ;; if t is beyond the provided series length, we simply keep the last value
  ]
end


;; ===========================
;; Landscape metrics
;; ===========================

to calculate-measures
  assign-group-id
  calculate-shape-index
  calculate-mesh-cwa
end

to-report generate-mesh-cwa
  assign-group-id
  calculate-shape-index
  set total-complexity-area sum (map [[s a] -> a / s] shape-index-list area-list)
  report (1 / total-complexity-area * sum (map [[s a] -> (a / s) ^ 2] shape-index-list area-list))
end

to assign-group-id
  clear-group-ids
  let next-group-id 1
  ask patches [
    if group-id = 0 [
      flood-fill self pcolor next-group-id
      set next-group-id next-group-id + 1
    ]
  ]
end

to calculate-shape-index
  set group-id-list []
  set perimeter-list []
  set area-list []
  set shape-index-list []
  let unique-groups remove-duplicates [group-id] of patches with [group-id != 0]
  foreach unique-groups [ gid ->
    let perimeter 0
    let area 0
    ask patches with [group-id = gid] [
      set perimeter perimeter + count neighbors4 with [group-id != gid or group-id = 0]
      set area area + 1
    ]
    set group-id-list lput gid group-id-list
    set perimeter-list lput perimeter perimeter-list
    set area-list lput area area-list
    let min-perimeter 4 * sqrt area
    let shape-index perimeter / min-perimeter
    set shape-index-list lput shape-index shape-index-list
    ask patches with [group-id = gid] [
      set group-perimeter perimeter
      set group-area area
      set group-shape-index shape-index
    ]
  ]
end

to calculate-mesh-cwa
  set total-complexity-area sum (map [[s a] -> a / s] shape-index-list area-list)
  set mesh-cwa (1 / total-complexity-area * sum (map [[s a] -> (a / s) ^ 2] shape-index-list area-list))
  set mesh ( 1 / (sum area-list) * sum (map [[a] -> a ^ 2] area-list))
end

to flood-fill [ start-patch #color #group-id ]
  let open-list (list start-patch)
  while [ not empty? open-list ] [
    let current-patch first open-list
    set open-list but-first open-list
    ask current-patch [
      if pcolor = #color and group-id = 0 [
        set group-id #group-id
        ;; append neighbours to the queue
        set open-list sentence open-list neighbors
      ]
    ]
  ]
end

to clear-group-ids
  ask patches [ set group-id 0 ]
end

;; ===========================
;; Reporters
;; ===========================

to-report generate-material-capitals [#elevation]
  report -4 * (#elevation - 1 / 2) ^ 2 + 1
end

to-report generate-natural-capitals [#elevation]
  let a 2
  ifelse #elevation > 1 / 2 [ set a 2 ] [ set a -2 ]
  report a * (#elevation - 1 / 2)
end

to-report generate-production-list [#capital_list #sensitivity_list #optimal_production_list]
  let my_production_list []
  ifelse (production_function = "linear") [
    set my_production_list (map [[c s] -> c * s] #capital_list #sensitivity_list)
  ] [
    let my_productive_capital item 0 #capital_list
    let my_natural_capital    item 1 #capital_list
    set my_production_list (map [[s o] -> o * my_productive_capital ^ s * my_natural_capital ^ (1 - s)]
                               #sensitivity_list #optimal_production_list)
  ]
  report my_production_list
end

to-report generate-intensity-attitude [x y]
  ;; values in [−1, 1]
  report ((x * x + y * y) / 10000) - 1
end
@#$#@#$#@
GRAPHICS-WINDOW
229
13
1045
830
-1
-1
8.0
1
10
1
1
1
0
0
0
1
0
100
0
100
0
0
1
ticks
30.0

CHOOSER
9
247
147
292
production_function
production_function
"linear" "Cobb-Douglas"
0

BUTTON
4
10
67
43
NIL
setup
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
74
10
137
43
NIL
go
T
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

SLIDER
9
168
215
201
demand_material_services
demand_material_services
0
5000
4000.0
500
1
NIL
HORIZONTAL

SLIDER
9
208
215
241
demand_non_material_services
demand_non_material_services
0
5000
4000.0
500
1
NIL
HORIZONTAL

SLIDER
6
53
126
86
pct_compete
pct_compete
0
100
5.0
5
1
NIL
HORIZONTAL

CHOOSER
31
439
188
484
attitude_distribution
attitude_distribution
"random_distribution" "spatial_distribution" "uniform_distribution" "dynamic_from_csv"
3

TEXTBOX
13
309
183
349
Behavioural parameters
15
0.0
1

TEXTBOX
11
147
161
166
Economic parameters
15
0.0
1

TEXTBOX
31
496
213
515
for spatial attitude distribution:
12
0.0
1

TEXTBOX
32
542
212
572
for random attitude distribution:\nNormal distribution
12
0.0
1

SLIDER
31
573
203
606
attitude_mean
attitude_mean
-1
1
1.0
0.1
1
NIL
HORIZONTAL

SWITCH
7
95
201
128
negative_competitiveness
negative_competitiveness
0
1
-1000

TEXTBOX
20
419
195
439
1. Environmental Attitudes
13
0.0
1

SLIDER
32
611
204
644
attitude_std_dev
attitude_std_dev
0
1
0.1
0.1
1
NIL
HORIZONTAL

PLOT
1058
15
1678
332
Global Production & Demand
NIL
NIL
0.0
10.0
0.0
10.0
true
true
"" ""
PENS
"Material ES Supply" 1.0 0 -3889007 true "" "plot material_services_production"
"Non-Material ES Supply" 1.0 0 -6565750 true "" "plot non_material_services_production"
"Material ES Demand" 1.0 0 -8431303 true "" "plot demand_material_services"
"Non-Material ES Demand" 1.0 0 -12087248 true "" "plot demand_non_material_services"

PLOT
1060
342
1679
655
Intensity Shares
NIL
NIL
0.0
10.0
0.0
1.0
true
true
"" ""
PENS
"High-Intenisty" 1.0 0 -13210332 true "" "plot count patches with [AFT = \"high_intensity\"] / count patches"
"Mid-Intensity" 1.0 0 -10899396 true "" "plot count patches with [AFT = \"medium_intensity\"] / count patches"
"Conservation" 1.0 0 -6565750 true "" "plot count patches with [AFT = \"conservation\"] / count patches"

SLIDER
37
826
129
859
inertia
inertia
0
1
0.0
0.1
1
NIL
HORIZONTAL

TEXTBOX
22
804
172
822
3. Behavioural Inertia
13
0.0
1

SLIDER
35
719
171
752
norm_weight
norm_weight
0
1
1.0
0.1
1
NIL
HORIZONTAL

TEXTBOX
32
515
182
533
attitude between -1 and 1
12
0.0
1

SLIDER
13
334
168
367
logistic_steepness
logistic_steepness
0
10
9.0
1
1
NIL
HORIZONTAL

SLIDER
13
374
187
407
max_giving_in_threshold
max_giving_in_threshold
0
1
1.0
0.1
1
NIL
HORIZONTAL

SLIDER
445
875
611
908
init_share_high
init_share_high
0
1
0.2
0.1
1
NIL
HORIZONTAL

SLIDER
446
918
610
951
init_share_medium
init_share_medium
0
1
0.2
0.1
1
NIL
HORIZONTAL

SWITCH
623
876
816
909
equal_initial_distribution
equal_initial_distribution
0
1
-1000

BUTTON
1063
670
1201
703
NIL
calculate-measures
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

MONITOR
1066
715
1148
760
NIL
mesh-cwa
2
1
11

MONITOR
1065
773
1148
818
NIL
mesh
2
1
11

SLIDER
231
917
380
950
random_links
random_links
0
100000
0.0
10000
1
NIL
HORIZONTAL

SLIDER
35
760
179
793
norm_sensitivity
norm_sensitivity
0
1
0.5
0.1
1
NIL
HORIZONTAL

SLIDER
231
875
380
908
connection_radius
connection_radius
0
10
2.0
1
1
NIL
HORIZONTAL

TEXTBOX
33
652
204
700
for uniform distribution:\nattitude = attitude_mean
12
0.0
1

TEXTBOX
20
695
202
713
2. Descriptive Social Norms
13
0.0
1

TEXTBOX
444
850
594
869
Setup Parameters
15
0.0
1

TEXTBOX
230
849
434
870
Network Characteristics
15
0.0
1

SWITCH
624
920
819
953
load_behaviour_from_csv
load_behaviour_from_csv
0
1
-1000

@#$#@#$#@
## WHAT IS IT?

This model is a simplified version of the CRAFTY (Competition for Resources between Agent Functional TYpes) land-use model, extended with a socio-psychological decision framework. It explores how land managers’ decisions about land-use intensity are shaped not only by economic competitiveness and environmental resources but also by environmental attitudes, social norms, and behavioural inertia. The model shows how these interacting drivers generate emergent land-use patterns and ecosystem service provision across a stylised landscape.
- The model additionally allows loading patch-level behavioural parameters from CSV files, giving each patch its own parameter values rather than applying global slider values uniformly.
- It also supports time-varying, per-patch environmental attitudes loaded from a CSV file, enabling externally specified attitude trajectories over time.

## HOW IT WORKS

- The world is a grid where each patch represents a unit of land, managed by one agent.
- Each patch has productive capital (favouring material services) and natural capital (favouring non-material services).
- Agents belong to one of three Agent Functional Types (AFTs):
-- High-Intensity (focus on material services, high productive capital sensitivity)
-- Mid-Intensity (balanced use of material and non-material services)
-- Conservation (focus on non-material services, high natural capital sensitivity)
- At each time step, a subset of patches is selected for competition. Agents consider whether to switch land-use intensity based on:
-- Economic competitiveness (ability to meet residual demand for ecosystem services)
-- Environmental attitude (pro-environmental → extensification; productivist → intensification)
-- Social influence (share of peers of same or higher/lower intensity within a network)
-- Behavioural inertia (reluctance to make large shifts in intensity)
- Transitions occur if the competing agent’s utility exceeds the incumbent’s by more than a dynamic giving-in threshold, calculated from these socio-psychological drivers.
- If behavioural parameters are loaded from CSV, each patch receives its own values for:
max_giving_in_threshold, norm_weight, norm_sensitivity, inertia.
- If dynamic attitudes are enabled (attitude_distribution = "dynamic_from_csv"), each patch loads a time series of environmental attitude values from a CSV file, updating every tick.

## HOW TO USE IT

- Press SETUP to initialise the landscape and GO to run the simulation.
- Sliders:
-- demand_material_services, demand_non_material_services: global demand levels for material and non-material ecosystem services.
-- connection_radius: size of the Moore neighbourhood used to form local social links.
-- random_links: number of additional teleconnections (long-distance random ties).
-- pct_compete: percentage of patches considered for competition each tick.
-- logistic_steepness, norm_weight, inertia, max_giving_in_threshold, norm_sensitivity: parameters controlling socio-psychological influence.
-- These global slider values are overridden for a given parameter if the load_behaviour_from_csv switch is ON and a CSV file is provided for that parameter.
-- init_share_high, init_share_medium: initial shares of High- and Mid-Intensity managers (Conservation is the remainder).
- Switches:
-- equal_initial_distribution: if ON, assigns AFTs evenly at random; if OFF, uses initial shares.
-- negative_competitiveness: if ON, competitiveness values can be negative; if OFF, they are set to zero when negative.
-- production_function: choose between linear or Cobb–Douglas production.
-- load_behaviour_from_csv: if ON, loads per-patch behavioural parameters (max_giving_in_threshold, norm_weight, norm_sensitivity, inertia) from CSV files.
- Environmental Attitudes:
-- attitude_distribution: select between random_distribution (normal distribution), spatial_distribution (based on patch coordinates), or uniform_distribution (all set to mean).
-- attitude_mean, attitude_std_dev: mean and standard deviation for the normal distribution when random_distribution is chosen.
-- When attitudes are loaded dynamically (dynamic_from_csv), attitude_mean and attitude_std_dev act only as fallback default values.
- Plots:
-- Global Production & Demand shows the supply of material and non-material ecosystem services compared to global demand.
-- Intensity Shares shows the share of land under High-Intensity, Mid-Intensity, and Conservation management.
- Buttons and Monitors:
-- calculate-measures computes landscape clustering metrics.
-- mesh-cwa and mesh display the calculated connectivity metrics.

## THINGS TO NOTICE

- How quickly the system stabilises into clusters of High-Intensity, Mid-Intensity, or Conservation land use.
- The influence of environmental attitudes on whether land managers adopt more intensive or more extensive practices.
- The effect of social influence: clustering of similar practices in local neighbourhoods.
- The asymmetry between material and non-material service production: material tends to track demand more closely.
- How spatial heterogeneity in behavioural parameters (via CSV) affects the location and spread of different intensities.
- How time-varying attitudes (via dynamic CSV) trigger behavioural transitions over time.

## THINGS TO TRY

- Increase random_links to see how teleconnections affect clustering and fragmentation.
- Compare dynamics under linear vs Cobb–Douglas production.
- Change norm_weight: when social influence dominates, do Mid-Intensity clusters emerge?
- Vary demand_material_services vs. demand_non_material_services to simulate policy shifts or societal preferences.
- Explore how higher inertia affects the speed and stability of land-use transitions.
- Turn ON load_behaviour_from_csv and create contrasting patterns (e.g., high inertia zones versus low inertia zones).
- Use dynamic_from_csv to impose time-based behavioural shocks or gradual attitude transitions and observe how they propagate.

## EXTENDING THE MODEL

- Introduce additional land-use categories (e.g., afforestation, abandonment).
- Implement dynamic attitudes that evolve through learning or feedback.
- Explore heterogeneous distributions of behavioural parameters.
- Couple the model with empirical land cover data for specific regions.
- Add policy instruments (e.g., subsidies, conservation schemes) and test their effects.
- Couple the model with real behavioural datasets via CSV files.
- Use dynamic CSV attitudes to simulate policy interventions, media influence, or environmental campaigns.

## NETLOGO FEATURES

- Uses patches as agents to reduce computational cost.
- Implements a flood-fill clustering algorithm to calculate landscape connectivity and shape metrics.
- Employs network structures combining Moore neighbourhoods with random teleconnections (similar to small-world networks).
- Decision thresholds are calculated using a logistic function, reflecting non-linear behavioural dynamics.
- CSV-based per-patch behavioural parameters.
- CSV-based dynamic attitudes (per-patch × per-time-step).

## RELATED MODELS

CRAFTY (Competition for Resources between Agent Functional Types). https://github.com/CRAFTY-ABM

## CREDITS AND REFERENCES

This model was developed by Ronja Hotz. It extends the CRAFTY (Competition for Resources between Agent Functional Types) land-use model with a socio-psychological decision framework. 
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

sheep
false
15
Circle -1 true true 203 65 88
Circle -1 true true 70 65 162
Circle -1 true true 150 105 120
Polygon -7500403 true false 218 120 240 165 255 165 278 120
Circle -7500403 true false 214 72 67
Rectangle -1 true true 164 223 179 298
Polygon -1 true true 45 285 30 285 30 240 15 195 45 210
Circle -1 true true 3 83 150
Rectangle -1 true true 65 221 80 296
Polygon -1 true true 195 285 210 285 210 240 240 210 195 210
Polygon -7500403 true false 276 85 285 105 302 99 294 83
Polygon -7500403 true false 219 85 210 105 193 99 201 83

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

wolf
false
0
Polygon -16777216 true false 253 133 245 131 245 133
Polygon -7500403 true true 2 194 13 197 30 191 38 193 38 205 20 226 20 257 27 265 38 266 40 260 31 253 31 230 60 206 68 198 75 209 66 228 65 243 82 261 84 268 100 267 103 261 77 239 79 231 100 207 98 196 119 201 143 202 160 195 166 210 172 213 173 238 167 251 160 248 154 265 169 264 178 247 186 240 198 260 200 271 217 271 219 262 207 258 195 230 192 198 210 184 227 164 242 144 259 145 284 151 277 141 293 140 299 134 297 127 273 119 270 105
Polygon -7500403 true true -1 195 14 180 36 166 40 153 53 140 82 131 134 133 159 126 188 115 227 108 236 102 238 98 268 86 269 92 281 87 269 103 269 113

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
<experiments>
  <experiment name="n_AFT_without_behav" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 10</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="false"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="test" repetitions="2" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <timeLimit steps="400"/>
    <exitCondition>ticks = 400</exitCondition>
    <metric>count patches with [aft = "HIF"]</metric>
    <runMetricsCondition>ticks = 399</runMetricsCondition>
    <enumeratedValueSet variable="ws">
      <value value="0"/>
      <value value="1"/>
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.6"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="100000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="false"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="connectivity_ws" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 10</exitCondition>
    <metric>generate-mesh-cwa</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="2"/>
    </enumeratedValueSet>
    <steppedValueSet variable="ws" first="0" step="1" last="10"/>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="connectivity_ws (low_demand)" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 10 or ticks = 400</exitCondition>
    <metric>generate-mesh-cwa</metric>
    <runMetricsCondition>stable-count &gt;= 10 or ticks = 400</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="2"/>
    </enumeratedValueSet>
    <steppedValueSet variable="ws" first="0" step="1" last="10"/>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="connectivity_w (low_demand)" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 10 or ticks = 400</exitCondition>
    <metric>generate-mesh-cwa</metric>
    <runMetricsCondition>stable-count &gt;= 10 or ticks = 400</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <steppedValueSet variable="w" first="0" step="0.1" last="1"/>
    <enumeratedValueSet variable="k">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_att_high" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 10</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.2"/>
    </enumeratedValueSet>
    <steppedValueSet variable="mean_attitude" first="3.1" step="0.1" last="4"/>
    <enumeratedValueSet variable="demand_recreation">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_att_det" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 10</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.2"/>
    </enumeratedValueSet>
    <steppedValueSet variable="mean_attitude" first="-2" step="0.1" last="2"/>
    <enumeratedValueSet variable="demand_recreation">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="MIF_ws (low_demand) (copy)" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>ticks = 400</exitCondition>
    <metric>count patches with [pcolor = 55]</metric>
    <runMetricsCondition>ticks = 400</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="2"/>
    </enumeratedValueSet>
    <steppedValueSet variable="ws" first="0" step="1" last="10"/>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_att_high_threshold_model" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 10</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.1"/>
    </enumeratedValueSet>
    <steppedValueSet variable="mean_attitude" first="-1" step="0.1" last="1"/>
    <enumeratedValueSet variable="demand_recreation">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_w_high_threshold_model" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 10</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <steppedValueSet variable="w" first="0" step="0.1" last="1"/>
    <enumeratedValueSet variable="k">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_critical_mass_high_threshold_model" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 10</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;random_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <steppedValueSet variable="critical_mass" first="0" step="0.1" last="1"/>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_dynamic_att_hysteresis" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>change-attitude-back-started and (all? patches [attitude_intensity &lt; -1]) and (stable-count &gt; 50 or (ticks - change-back-start-tick) &gt; 1000)</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="-1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_dynamic_att_ref" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>ticks &gt; 900</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_dynamic_att_medium_demand" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>dynamic-attitude-started and (all? patches [attitude_intensity &gt; 1] or all? patches [attitude_intensity &lt; -1]) and (stable-count &gt; 50 or (ticks - dynamic-start-tick) &gt; 400)</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="4000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="-1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="4000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_dynamic_att_ref_medium_demand" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>ticks &gt; 900</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="4000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="4000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_dynamic_att_high_demand" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>dynamic-attitude-started and (all? patches [attitude_intensity &gt; 1] or all? patches [attitude_intensity &lt; -1]) and (stable-count &gt; 50 or (ticks - dynamic-start-tick) &gt; 400)</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="-1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_dynamic_att_ref_high_demand" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>ticks &gt; 900</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="5000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_dynamic_att_wo_p" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>dynamic-attitude-started and (all? patches [attitude_intensity &gt; 1] or all? patches [attitude_intensity &lt; -1]) and (stable-count &gt; 50 or (ticks - dynamic-start-tick) &gt; 400)</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="-1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_dynamic_att_ref_wo_p" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>ticks &gt; 900</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_dynamic_att_ref_hysteresis" repetitions="10" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>ticks &gt; 2001</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 10</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_recreation">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_att_low_threshold_model_changed_p_k_w" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 20 or ticks &gt; 500</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 20 or ticks &gt; 500</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.1"/>
    </enumeratedValueSet>
    <steppedValueSet variable="mean_attitude" first="-1" step="0.1" last="1"/>
    <enumeratedValueSet variable="demand_recreation">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="n_AFT_3_dim_run" repetitions="10" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 20 or ticks &gt; 500</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <runMetricsCondition>stable-count &gt;= 20 or ticks &gt; 500</runMetricsCondition>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="demand_crop">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0.1"/>
    </enumeratedValueSet>
    <steppedValueSet variable="mean_attitude" first="-1" step="0.1" last="1"/>
    <enumeratedValueSet variable="demand_recreation">
      <value value="3000"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <steppedValueSet variable="p" first="0" step="0.1" last="1"/>
    <steppedValueSet variable="w" first="0" step="0.1" last="1"/>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="dynamic_attitude">
      <value value="false"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="Typ_1" repetitions="1" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 20 or ticks &gt; 500</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <metric>(count patches with [aft = "LIF"]) / 10201</metric>
    <metric>crop_production</metric>
    <metric>recreation_production</metric>
    <enumeratedValueSet variable="ws">
      <value value="0.6"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="neighborhood_size">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.25"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="dynamic_attitude">
      <value value="false"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <steppedValueSet variable="demand_crop" first="3000" step="1000" last="5000"/>
    <steppedValueSet variable="demand_recreation" first="3000" step="1000" last="5000"/>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="Typ_2" repetitions="1" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 20 or ticks &gt; 500</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <metric>(count patches with [aft = "LIF"]) / 10201</metric>
    <metric>crop_production</metric>
    <metric>recreation_production</metric>
    <enumeratedValueSet variable="ws">
      <value value="1"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="neighborhood_size">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="dynamic_attitude">
      <value value="false"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <steppedValueSet variable="demand_crop" first="3000" step="1000" last="5000"/>
    <steppedValueSet variable="demand_recreation" first="3000" step="1000" last="5000"/>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="Typ_3" repetitions="1" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 20 or ticks &gt; 500</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <metric>(count patches with [aft = "LIF"]) / 10201</metric>
    <metric>crop_production</metric>
    <metric>recreation_production</metric>
    <enumeratedValueSet variable="ws">
      <value value="0.8"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="neighborhood_size">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="dynamic_attitude">
      <value value="false"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <steppedValueSet variable="demand_crop" first="3000" step="1000" last="5000"/>
    <steppedValueSet variable="demand_recreation" first="3000" step="1000" last="5000"/>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="Typ_4" repetitions="1" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 20 or ticks &gt; 500</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <metric>(count patches with [aft = "LIF"]) / 10201</metric>
    <metric>crop_production</metric>
    <metric>recreation_production</metric>
    <enumeratedValueSet variable="ws">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="neighborhood_size">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="dynamic_attitude">
      <value value="false"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <steppedValueSet variable="demand_crop" first="3000" step="1000" last="5000"/>
    <steppedValueSet variable="demand_recreation" first="3000" step="1000" last="5000"/>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
  </experiment>
  <experiment name="Typ_5" repetitions="1" runMetricsEveryStep="true">
    <setup>setup</setup>
    <go>go</go>
    <exitCondition>stable-count &gt;= 20 or ticks &gt; 500</exitCondition>
    <metric>(count patches with [aft = "HIF"]) / 10201</metric>
    <metric>(count patches with [aft = "MIF"]) / 10201</metric>
    <metric>(count patches with [aft = "LIF"]) / 10201</metric>
    <metric>crop_production</metric>
    <metric>recreation_production</metric>
    <enumeratedValueSet variable="ws">
      <value value="0.6"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="neighborhood_size">
      <value value="2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="negative_competitiveness">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="w">
      <value value="0.75"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="attitude_distribution">
      <value value="&quot;uniform_distribution&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="n_teleconnections">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="std_dev_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="mean_attitude">
      <value value="0"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_MIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="production_function">
      <value value="&quot;linear&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="critical_mass">
      <value value="0.5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="pct_compete">
      <value value="5"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="social_processes">
      <value value="true"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="p_HIF">
      <value value="0.2"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="dynamic_attitude">
      <value value="false"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="k">
      <value value="10"/>
    </enumeratedValueSet>
    <steppedValueSet variable="demand_crop" first="3000" step="1000" last="5000"/>
    <steppedValueSet variable="demand_recreation" first="3000" step="1000" last="5000"/>
    <enumeratedValueSet variable="equal_initial_distribution">
      <value value="true"/>
    </enumeratedValueSet>
  </experiment>
</experiments>
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
