# Mythic Ocean Comprehensive Recovery Report

Status: implementation complete for the reachable code and Edit-DataModel checks; Play-mode acceptance remains blocked by the current Studio StartPlay state.

## Repository and place

- Audited baseline: `064480becf992afa7662b31a5995f1fedc34bade`.
- Current repository commit: `bf694b6` (`Pivot ocean to coherent Gerstner macro surface`).
- Branch: `main`, synchronized with `origin/main`.
- Place: Mythic, place ID `89252995862215`.
- Studio: `0.735.0.7351131`, AMD Radeon 880M, Vulkan, 32 GB host memory, 2880-wide Studio viewport.
- The place was saved through Studio's normal Ctrl+S path. The `.rbxl` is not mapped into this repository.

## Phase 0 evidence

The fresh baseline emitted four client warnings per startup:

```text
OceanRenderer | BatchSetValues position failed | EditableMesh API function not available
```

Baseline runtime topology was High, four moving rings, 8,593 vertices, and 15,840 triangles. The runtime quality attribute later adapted to Low while retaining the High topology.

Measured baseline percentiles while stationary:

| Metric | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|
| Frame ms | 116.066 | 133.121 | 134.165 | 134.165 |
| Ocean ms | 82.751 | 88.426 | 88.426 | 88.426 |
| Ocean update ms | 3.267 | 5.203 | 5.203 | 5.203 |
| UV update ms | 0 | 0 | 0 | 0 |

During 24 four-stud camera snap crossings:

| Metric | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|
| UV update ms | 0 | 8.470 | 8.470 | 8.470 |
| Ocean ms | 70.034 | 91.844 | 91.844 | 91.844 |
| Frame ms | 149.118 | 151.234 | 151.234 | 151.234 |
| Ocean update ms | 2.623 | 3.988 | 3.988 | 3.988 |

The baseline Trade and Gale deck captures showed the reported dark, highly repeated water material and no visible raft support. The Gale capture showed a hard, dark distance surface rather than a continuous moving-to-static transition.

The inspected live raft before repair had a 24x2x10 stud HullRoot, EffectiveDraft 4, point TargetSubmersion 2.2, RootPriority 0, Default collision groups, a non-massless seat, and `OceanNetworkOwnership=Driver`. Its Play trace reached a rotated/inverted state and unseated the character. A client snapshot also showed a disabled `OceanSwimForce` retaining a nonzero force vector.

The active baseline ColorMap asset was inspected as a high-contrast photo-like blue/bubbly map and rejected. The generated foam disk and spray oval assets were also rejected. A new Studio-generated neutral water set is now promoted: ColorMap `114485532047931`, NormalMap `122673814251163`, RoughnessMap `84568670031055`, MetalnessMap `90459269207438`, Regular projection at 48 studs per tile. These generated thumbnails were still moderation-pending during the Edit inspection.

## Gerstner addendum pivot

- Production spectrum is now five components for ordinary presets and six for rough/storm presets: two swells, exact peak wind, two separated wind components, and an optional cross-sea component.
- Directions are normalized; Hs reconstruction error is zero in the macro regression; target aggregate steepness is approximately 0.218 Glass, 0.261 Calm, 0.352 Trade, 0.424 Gale, and 0.480 Mythic Storm.
- A 49x49 High near patch at 8-stud spacing covers 384 studs continuously. Medium is 41x41 at 10 studs; Low is 33x33 at 12 studs.
- The Studio-only `OceanReferenceHarness` exposes `Reference Geometry`, `Candidate Production`, and `Current Main` modes through `_G.OceanReferenceHarness`, plus normals/grid/LOD/crest/compression debug attributes and Glass/PBR material candidates.
- Current EditableMesh color APIs (`AddColor`, `SetFaceColors`, `SetColor`) are used for a three-stop trough/mid/crest ramp. Color commits are cadence-limited to 12 Hz.

### Stability and gameplay

- `ShipRegistry.luau`
  - Requires one unanchored assembly rooted at HullRoot.
  - Sets HullRoot RootPriority 127 and PrimaryPart.
  - Validates point count, parent assembly, footprint, finite positive weights, and weighted X/Z moments.
  - Forces server ownership once through the assembly root after `CanSetNetworkOwnership()`.
  - Removes per-physics-step ownership polling and Driver ownership behavior.
  - Registers `OceanShip` and `OceanSeatedOccupant` collision groups.
  - Temporarily removes seated character-vessel collision and restores prior groups on unseat.

- `BuoyancyService.luau`
  - Uses cached dry mass/COM and bounded passenger payload blending.
  - Applies zero force to dry points.
  - Uses world-up hydrostatic lift and vertical damping, bounded point/aggregate force, torque, and invalid-sample handling.
  - Replaces per-step impulses with persistent COM drag and roll/pitch Torque actuators.
  - Exposes server diagnostics.

- `ShipValidationService.luau`
  - Logs mass, force, torque, wet-point, invalid-sample, and seat context before softening an outlier.
  - Keeps CFrame recovery only for nonfinite state.

- `SwimmingController.luau`
  - Adds idempotent `Deactivate(reason)` that zeros and disables `OceanSwimForce`.
  - Guards disabled/dead/missing/seated/external-assembly/respawn paths.
  - Moves control to PreSimulation.
  - Adds Dry/Entering/Swimming/Exiting hysteresis using pelvis/chest/head samples.
  - Samples at 20 Hz and interpolates force control between samples.
  - Adds keyboard, gamepad, and touch ascend/dive actions.
  - Uses bounded vertical tracking and MoveDirection propulsion rather than isotropic velocity cancellation.

- `SwimmingValidationService.luau`
  - Server-validates water-relative player speed and vertical velocity at 10 Hz.

- `ShipSpawnService.server.luau`
  - Validates the spawn attachment assembly and orientation.
  - Retries placement after character/model readiness.
  - Places players at `ShipSpawnPoint` and clears inherited velocities.

### Renderer and horizon

- `RenderEvaluator.luau`
  - Adds prepared scalar Gerstner plans and a scalar hot path.
  - Preserves WaveMath component order and numerical behavior.
  - Omits foam, events, inverse mapping, and rich sample tables from render vertices.

- `OceanRenderer.luau`
  - Removes custom UV creation and all per-vertex SetUV recenter calls; the active MaterialVariant path uses projection/StudsPerTile.
  - Uses explicit profile ring resolutions/extents and a 31x31 High L0 with progressively smaller/coarser rings.
  - Uses a bounded eight-sector transition annulus outside the final moving ring.
  - Extends High macro-wave influence to an approximately 1,152-stud half-extent before static horizon coverage; dominant 400-675 stud waves remain traceable across multiple cycles.
  - Rebases the complete moving/transition set on a 32-stud anchor and forces a full commit on rebase; camera movement within an anchor does not move stale geometry.
  - Morphs six shared long components C1-continuously to mean sea level/up normal across the transition.
  - Uses synchronized shared-edge commits and boundary-only updates for lower-cadence rings.
  - Keeps static horizon tiles outside the transition with the same material/tint.
  - Suppresses production seam-stat work unless `OceanDebugSeams` is enabled.
  - Records singular-setter client capability based on the observed BatchSetValues client failure; no repeated warnings or probes.

- `OceanConfig.luau`
  - Makes profile extents, resolutions, transition widths, cadence, and horizon range truthful.
  - High/Medium/Low moving topology no longer silently terminates at the same 768-stud radius.

### Material and VFX

- `OceanWater.model.json` / `OceanWaterPBR.model.json`
  - Rejected the original photo-like ColorMap after pixel inspection.
  - Promoted Studio-generated neutral ColorMap/NormalMap/RoughnessMap/MetalnessMap IDs.
  - Uses Regular projection at 48 studs per tile.
  - A live Play A/B test proved that an empty SurfaceAppearance ColorMap overrides MeshPart.Color with white. The active path now uses the generated MaterialVariant maps directly with MeshPart.Color and 0.04 reflectance.

- `WaterMaterialController.luau`
  - Does not create a SurfaceAppearance over the generated MaterialVariant.
  - Applies one shared dark-blue tint to near, transition, and horizon surfaces.
  - Tracks only known water instances instead of scanning/reassigning every RenderStepped transition frame.
  - Quantizes weather atmosphere updates and scopes asset-failure diagnostics to known map IDs.
  - Preloads the exact manifest asynchronously.

- `FoamController.luau`, `SprayController.luau`, `WakeController.luau`
  - Replace scan-order reassignment with persistent spatial tracks and keys.
  - Clear Trail history before reuse and clear histories on teleports.
  - Use bounded cadence, distance culling, crest/compression/motion gates, and no unchanged-cap pool rebuilds.
  - Use inspected built-in alpha textures after rejecting the generated disk/oval assets.

- `UnderwaterController.luau`
  - Uses 20 Hz surface sampling and a 0.25-second ColorCorrection crossfade.

- `VisualSampleScheduler.luau`
  - Caches quantized same-time visual samples for foam, spray, wakes, shoreline, underwater, and swimming consumers.

## Static and Edit-DataModel verification

All changed live sources loadstring-compiled successfully, including:

```text
WaveMath, RenderEvaluator, OceanServerMain, BuoyancyService,
ShipRegistry, ShipValidationService, SwimmingValidationService,
ShipSpawnService, OceanRenderer, OceanClientMain,
VisualSampleScheduler, FoamController, SprayController,
WakeController, SwimmingController, UnderwaterController,
WaterMaterialController, ShorelineController
```

`OceanMathTests.Run()` passed all checks after the crest-height foam gate was added:

- `passed=true`
- Trade peak error: 0 studs at expected 402.923 studs
- Trade swell error: 0 studs at expected 674.791 studs
- Distinct wavelengths: 5 ordinary / 6 storm
- Max inverse residual: 0.00336 studs
- Max normal magnitude error: 5.96e-8
- Trough foam maximum: 0.0028
- Positive minimum Jacobian: 0.621
- Macro aggregate steepness maximum: 0.480

Render evaluator equivalence against WaveMath passed with maximum position error below 0.0001 stud and maximum normal disagreement 0.028 degrees.

Final Edit-built High topology:

| Component | Vertices | Triangles |
|---|---:|---:|
| Moving near patch | 2,403 | 4,608 |
| Transition sectors | 720 | 1,120 |
| Total dynamic geometry | 3,123 | 5,728 |
| Static horizon Parts | 45 | n/a |

Edit committed-boundary and recenter checks passed:

- The single near patch has no internal LOD seam.
- Moving/transition shared sample position and normal checks remain zero in the equivalent Edit harness.
- Transition outer boundary height and normal are flat at the mean sea level boundary.
- Camera movement within the anchor produces zero mesh shift; crossing the anchor forces a full synchronized commit.
- Vertex color API smoke test passes with `colorAvailable=true` and no `SetFaceColors`/`SetColor` error.
- Renderer fallback: false.

Smoke probes passed for ship registry registration, VFX controller construction, shared sample cache hits, and idempotent swim-force deactivation (`Enabled=false`, `Force=0,0,0`, state `Dry`).

## Live raft after repair

- HullRoot position `(0,0,0)`, orientation `(0,0,0)`, RootPriority 127.
- DriverSeat massless and welded; both parts in `OceanShip` collision group.
- Eight balanced points, each weight 0.125, local Y -0.9, weighted centroid approximately `(0,-0.9,0)`.
- EffectiveDraft 1.0, point TargetSubmersion 0.8, BuoyancyGain 1.22, point MaxForce 8000.
- `OceanNetworkOwnership=Server`.
- SpawnLocation removed; ShipSpawnPoint is a nonphysical attachment at HullRoot local `(0,2.5,0)`.

## Actual-water and ship correction

- Clean-start renderer now uses asset-free Glass before material initialization; the local helper no longer references `self`.
- Production near and transition faces now retain and validate `SetFaceNormals` and `SetFaceColors` IDs. Runtime color mutation uses the current two-argument `SetColor(colorId, color)` API.
- PBR is opt-in and only activates after every configured asset reports final `Enum.AssetFetchStatus.Success`. Glass telemetry reports `OceanMaterialPath=Glass` and `glass-baseline`.
- The reference harness uses the correct horizontal Gerstner amplitude, exposes honest `Reference Geometry` and `Candidate Production` modes, and isolates its Glass mesh from production material restyling.
- Buoyancy now uses the corrected `bodyUp:Cross(desiredUp)` sign, inertia-aware `AngularAccelerationToTorque`, shorter payload convergence, and independent vertical-lift/torque limits.
- ShipRegistry handles every seat, per-occupant collision state, SeatWeld/assembly-root lifecycle ownership events, and independent restoration.
- The live DriverSeat weld was restored and enabled after inspection found it disabled.

## Remaining blocker

Repeated attempts to start Play through Studio MCP and the normal F5 path return:

```text
Start play hasn't finished yet
```

Studio remains in Edit mode with only the Edit DataModel. No force-close, process kill, or Studio restart was performed. Therefore these required runtime gates remain unverified:

- seated 20-cycle force/ownership/roll test;
- empty and occupied raft soaks;
- swimming movement/boarding/latency matrix;
- aerial/recenter visual captures;
- lighting swatches;
- rendered VFX/material inspection after the changes;
- High/Medium Play profiler percentiles and five-minute soaks;
- full completion screenshot matrix.

The Output buffer contains historical errors from earlier Edit probes, including the pre-sector transition-size failure and intermediate source syntax probes. Those source errors were corrected and current Edit loadstring/build checks pass; a clean Play Output cannot be claimed while StartPlay is stuck.
