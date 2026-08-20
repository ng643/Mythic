# Mythic Ocean Comprehensive Recovery — Implementation Prompt

Work directly in the current `ng643/Mythic` repository **and** the live Roblox place through Roblox Studio MCP. Implement, playtest, profile, visually inspect, and iterate. Do not stop at analysis, a proposed patch, or green unit tests.

Audited repository baseline: `064480becf992afa7662b31a5995f1fedc34bade` (`Spawn players on demo ship`). If HEAD has advanced, re-check every finding against the new code before editing and preserve any correction that is genuinely working.

The repository does not contain the full live `OceanDemoRaft`, Lighting setup, collision groups, or any source images/gameplay captures for the uploaded texture IDs. Therefore you **must** inspect the live DataModel and actual rendered asset pixels through Studio MCP. Do not infer that the ship or material is correct from manifest strings.

## Outcome and order of priority

Deliver an ocean that is stable enough to play first, fast enough to iterate on second, and then visually excellent. Work in this order:

1. Reproduce and record the current failures.
2. Stop swimming/seat/ship physics from fighting each other.
3. Remove the renderer's proven CPU spikes and establish a performance budget.
4. Replace the hard 768-stud moving-to-flat LOD boundary with a continuous far transition.
5. Replace/tune the water material using inspected, approved maps rather than asset-ID claims.
6. Build readable, persistent crest foam, spray, wakes, and underwater presentation.
7. Run the full visual, physics, network, and performance acceptance matrix.

Do not spend another pass merely changing RGB colors, wave amplitude, particle rates, or `StudsPerTile` while the architecture below remains broken.

## Preserve what is already correct

Do not regress these recent improvements unless runtime evidence proves they are faulty:

- The generated spectrum, significant-wave-height normalization, positive-Jacobian tests, and deterministic synchronized wave state.
- Full authoritative gameplay sampling for buoyancy and waterline agreement.
- Correct two-argument `EditableMesh:BatchSetValues(ids, values)` usage.
- Symmetric cell-center donut topology and fine/coarse residual morphing.
- Non-destructive adaptive quality changes; ordinary quality changes must not rebuild working EditableMeshes.
- Horizon failures must not destroy healthy near geometry.
- The four-band horizon coverage decomposition and initialization-only static fallback.
- World-space wake surface sampling and the corrected client startup order.

## Current audited diagnosis — verify this in a fresh run

### 1. The ugly “distance level” is built into the current renderer

On every current quality profile, the editable extent guard builds exactly four moving rings. Their measured topology is:

| Initial profile | Moving vertices | Triangles | Final moving radius |
|---|---:|---:|---:|
| Ultra | 14,785 | 27,776 | 768 studs |
| High | 8,593 | 15,840 | 768 studs |
| Medium | 4,065 | 7,232 | 768 studs |
| Low | 2,425 | 4,176 | 768 studs |

For High, ring L3 ends at a square radius of 768 studs. Its outer edge still contains the six shared long-wave components, so its height and slope are not flat. `_BuildHorizon()` begins 48 perfectly flat anchored Parts at the same 768-stud boundary and at mean sea level. `WaterMaterialController` also assigns `waterColor` to moving water and a different `horizonColor` to those Parts. This necessarily creates a square discontinuity in height, normal, motion, lighting, and tint. It is the reported horrendous distance band, not a camera illusion.

The profile fields `horizonResolution` and `horizonCadence` are currently unused, while `horizonRange` is clamped to 6,000 even for profiles configured for 8,000–12,000. The present tests prove only planar annulus coverage; they do not test the moving-to-flat boundary.

### 2. The material is asserted, not visually validated

The active `OceanWater` MaterialVariant currently references:

- ColorMap `100340564254333`
- NormalMap `130080234654600`
- RoughnessMap `96754332370971`
- MetalnessMap `75597455436930`
- `MaterialPattern = Organic`
- `StudsPerTile = 10`

There are no source PNGs, map swatches, or final gameplay captures in the repository. The manifest says the maps were inspected and experience-owned, but that is not evidence of visual quality. A strongly featured ColorMap repeated every 10 studs can overwhelm geometry, reveal tiling, and prevent `MeshPart.Color` from producing clean water. Organic projection across 48 separate horizon Parts may also reveal per-Part orientation/tiling discontinuities. Inspect the real pixels and the rendered result.

`WaterMaterialController` publishes a changing roughness number but never changes the immutable RoughnessMap or selects a different material. That value is diagnostic fiction, not active roughness. It also scans the entire `OceanRuntime` and rewrites many attributes and lighting values every RenderStepped frame during a weather blend.

The renderer creates and mutates EditableMesh UVs, but the active path is a MaterialVariant governed by `StudsPerTile`/material projection. Prove whether those custom UVs affect this path. If they do not, they are pure overhead and must be removed.

### 3. The renderer is predictably expensive

High currently uses 2,401 vertices in L0 and 2,064 in each of L1–L3, updating at approximately 60/30/15/7.5 Hz. With the current full/shared component caps, this is approximately **5.1 million component evaluations per second** before event and transition overhead, and bank blending can roughly double the wave-bank work. The current rates also commit about 252,000 positions and 237,000 normals per second.

Worse, every ring snaps from the same four-stud base spacing. Each four-stud camera crossing runs an individual protected `SetUV` call for all 8,593 High vertices. A ship moving at 40 studs/second can therefore trigger roughly 86,000 individual UV mutations per second, in bursts. This is a likely source of severe traversal hitching.

Additional avoidable work includes:

- `_UpdateSeamStats()` running every 0.5 seconds in production instead of only in debug/validation mode.
- Foam scanning 49 inverse wave samples and spray scanning 25 inverse samples every 0.1 seconds as separate passes.
- Each tracked wake taking five full gameplay/inverse samples every RenderStepped frame.
- Swimming and underwater each taking another full inverse sample every RenderStepped frame.
- Shoreline sampling every point every rendered frame with no cadence/distance budget.
- Server buoyancy taking 4–24 full inverse samples plus a root sample for every ship every physics step.
- `FoamController:SetCap()` and `SprayController:SetCap()` destroying and recreating entire pools even when the cap is unchanged.
- Every device initially constructing High and then waiting 15 seconds before adaptive quality may reduce safe runtime budgets.

### 4. Swimming is two controllers fighting over one character

`SwimmingController` currently:

- applies physics from `RenderStepped`, not a pre-physics phase;
- classifies one root point against one moving threshold with no hysteresis or dwell time;
- calls `Humanoid:ChangeState(Swimming)` whenever the engine leaves that state;
- nearly cancels gravity and then applies isotropic drag against all assembly velocity, including intended horizontal movement;
- does not immediately disable its existing VectorForce when the feature is disabled, the character disappears, the Humanoid dies, or the player becomes seated;
- does not have an explicit propulsion controller or cross-platform ascend/dive input.

Roblox documents `HumanoidStateType.Swimming` as the state for swimming in **Terrain water**. This game uses custom non-colliding visual geometry, so repeatedly forcing that Terrain-oriented state is not a complete custom-water controller.

### 5. Sitting can directly inject a ship-sized swim force

A Seat creates a `SeatWeld` and connects the character to the ship assembly. The current swim code has no `Humanoid.SeatPart`/Seated guard. If a wave crosses the seated HumanoidRootPart threshold, `root.AssemblyMass` is now the mass of the connected ship/character mechanism. The LocalScript then intermittently applies approximately 92% of that **combined assembly's gravity** as an extra swim force while also changing Humanoid state. At the same time, the server buoyancy solver recalculates every spring from the changed assembly mass and center of mass. This can produce exactly the reported flip/freak-out cascade.

Other verified destabilizers in `BuoyancyService` and `ShipRegistry` are:

- damping remains active even when `depth == 0`, so a dry point above water can still apply a large force;
- spring lift is world-up while damping is along the possibly steep wave normal, injecting inconsistent lateral forces and offset torques;
- force magnitudes are scaled from the instantaneous total assembly mass, so seating/standing changes tuning abruptly;
- there is no bounded roll/pitch angular damping or explicit total force/torque budget;
- quadratic forward drag is `0.9` while lateral drag is only `0.08`, the opposite of a stable keeled hull's usual relationship;
- drag is delivered as a new impulse every step rather than a persistent, bounded force;
- driver occupancy can transfer ownership while the server continues calculating and writing buoyancy forces;
- ownership is attempted on every BasePart rather than once through the assembly root, even though Roblox ownership is assembly-based;
- the live raft's weld graph, `RootPriority`, point symmetry, collision groups, physical properties, and before/after seating mass/COM are absent from the repository and remain unverified.

## Phase 0 — reproduce, inspect, and establish evidence

Use Studio MCP with a clean server and at least one real client. Preserve the first warning/error; do not overwrite it with a generic recovery message.

1. Record the exact HEAD, place version, Studio version, graphics quality, resolution, device/emulation conditions, and whether adaptive quality is enabled.
2. Capture deck, mast, 80-stud aerial, and grazing-horizon images in Trade Sea and Gale before editing. Include a frame that clearly shows the 768-stud band and current material.
3. Use the MicroProfiler and named profile regions to capture at least 30 seconds each for:
   - stationary camera;
   - camera moving slowly across snap boundaries;
   - ship/camera moving at approximately 40 studs/second;
   - foam/spray/wakes on and off;
   - weather transition/bank blend;
   - empty ship and occupied Seat.
4. Report p50/p95/p99 client frame time, total ocean script time, vertex evaluation, vertex commit, normal commit, UV update, material update, foam/spray, wakes, swimming, and server buoyancy time. Do not report only FPS or one best frame.
5. Inspect `Workspace.OceanDemoRaft` live. Export a diagnostic table of every BasePart/constraint, anchored state, mass/massless state, collision group, root priority, assembly root, connected parts, seat type, and all buoyancy point local coordinates/weights. Record assembly mass, center of mass, root, owner, linear/angular velocity, and active forces immediately before seating, 0.1/0.5/1/3 seconds after seating, and after standing.
6. During that seat test, explicitly record whether `OceanSwimForce.Enabled` becomes true, its force, the Humanoid state, `SeatPart`, `AssemblyMass`, and `AssemblyRootPart`. This must confirm or disprove the causal chain above.
7. Inspect the four material maps as images through the Studio authoring context and make a swatch using the final MaterialVariant under noon, sunset, night, and storm lighting. Record asset moderation/permission/fetch status.
8. A/B test the current EditableMesh `SetUV` mutations. Prove with captures whether they affect the MaterialVariant. Measure their cost separately.

Add temporary diagnostics behind `RunService:IsStudio()` and `OceanDebugMetrics`; default them off and remove noisy per-frame logging before completion.

## Phase 1 — stop seat and ship instability

### 1A. Immediate swim/seat isolation

Implement one idempotent `Deactivate(reason)` path in `SwimmingController`. It must zero and disable the force, clear latched swim state, and restore any Humanoid/controller properties that swimming changed.

Call it before **every** early return when any of these is true:

- feature disabled;
- no live character/Humanoid/root;
- `Humanoid.Health <= 0`;
- `Humanoid.SeatPart ~= nil`, `Humanoid.Sit == true`, or state is Seated;
- a SeatWeld or other mechanism has connected the character root to an assembly whose root is outside the character;
- character is being removed or respawned.

Never apply custom swim force or call `ChangeState(Swimming)` while seated. Add an automated regression that seats a character while the water surface crosses the root and proves `OceanSwimForce.Enabled == false` and `Force == Vector3.zero` for the entire seated interval.

### 1B. Make the demo ship one clean rigid assembly

Through Studio MCP, repair the live `OceanDemoRaft`, not just repository modules:

- exactly one intended unanchored hull assembly;
- a deliberate `PrimaryPart`/`HullRoot` with high enough `RootPriority` to remain the mechanism root when a SeatWeld exists;
- every visual/seat/attachment part welded once without conflicting constraints;
- no anchored descendant, loose decorative part, duplicate weld, or collidable overlapping helper;
- sane densities and a center of mass below the metacenter; decorative parts should be massless where appropriate;
- 4–8 symmetric buoyancy points inside the hull footprint and below the intended waterline; do not use 24 points merely because the schema allows them;
- normalized weights whose fore/aft and port/starboard moments balance around the cached dry-hull center of mass;
- point positions, draft, and displacement matched to the actual model dimensions rather than generic defaults.

Create a validator that rejects/warns on asymmetric moments, points outside bounds, points parented to a different assembly, invalid root, unreasonable density, or a center of mass above the safe range. Validation must report actionable values.

### 1C. Use one coherent network authority

For this recovery pass, keep gameplay ships server-owned while server code computes buoyancy. On registration, call `CanSetNetworkOwnership()` and then `SetNetworkOwner(nil)` once on the assembly root. Do not iterate every BasePart and do not poll/transfer ownership every `PreSimulation` step. Subscribe to relevant assembly/seat lifecycle changes only for diagnostics.

The driver should send or expose bounded throttle/steer intent; the server applies propulsion and buoyancy. Do not combine client-owned ship simulation with server-updated forces. Keep any future `Driver` ownership mode explicitly experimental and off until it passes the same high-latency and multi-client tests.

### 1D. Replace the unstable force law

Keep force application in `PreSimulation`, but rewrite the solver around a cached ship displacement model:

1. Cache dry hull mass, dry center of mass, point geometry, target draft, and displacement mass at registration. Do not retune every spring from instantaneous assembly mass after a character sits.
2. If payload is modeled, calculate it separately and blend a bounded payload contribution into target displacement over roughly 1–2 seconds. A passenger may make the ship settle slightly; it must not cause a step change in gain.
3. For each point, calculate submersion and a smooth wetness fraction. When a point is dry, set its force to zero. Scale hydrostatic and damping forces continuously from zero as it enters water.
4. Use a consistent stable axis for lift and heave damping—normally world up using water vertical velocity. Do not apply the spring world-up and then apply full damping along a steep wave normal. If horizontal wave coupling is retained, make it a small, separately capped center-of-mass force.
5. Use point forces to generate natural restoring moments, but cap per-point force, aggregate force, and aggregate torque. Clamp invalid `dt`, acceleration, and force slew/jerk so one bad sample cannot create an impulse spike.
6. Add bounded roll/pitch angular damping and gentle restorative torque toward an orientation derived from world up or a low-pass average water plane. Preserve yaw freedom. Never set CFrame every frame and never hard-lock orientation.
7. Replace per-step drag impulses with a persistent center-of-mass `VectorForce` or other bounded continuous force. Longitudinal drag should be lower than lateral/keel drag; tune using the actual hull axes and speed envelope. Add moderate vertical damping.
8. Use `GetVelocityAtPosition()` or the correct linear-plus-angular point velocity and compare it to the sampled water velocity. Filter only the noisy high-frequency part; do not delay the entire solver.
9. A failed/invalid sample freezes that point's last safe or zero force and records the full context. It must not produce NaN, infinite force, or silently teleport the ship.

`ShipValidationService` may remain a last-resort envelope guard, but it must not be the mechanism that makes routine motion look stable. Log the force/torque cause before softening an outlier. Do not hide flips by repeatedly resetting CFrame.

### 1E. Prevent seated self-collision

A Seat creates a `SeatWeld`. Ensure a seated character cannot collide with the ship it is welded to, since limb/deck penetration can inject impulses. Prefer a temporary `OceanSeatedOccupant` collision group that does not collide with `OceanShip`; cache and restore each character part's previous group on unseat/respawn. A character standing or walking on deck must still collide normally with the deck. Validate accessories and parts added while seated.

## Phase 2 — replace swimming with a stable custom-water controller

Do not leave swimming as repeated Humanoid state changes plus blanket velocity drag.

1. Build an explicit state machine such as `Dry -> Entering -> Swimming -> Exiting`, with seat/death/respawn cancellation from Phase 1.
2. Detect immersion from multiple body locations (at minimum pelvis/chest and head), sampled against the same synchronized wave field as rendering. Use separate enter/exit depths and dwell times. Starting values to test are enter at 0.7–1.0 stud chest immersion for 0.12–0.2 seconds, and exit only after being 0.3–0.5 stud above the threshold for 0.12–0.2 seconds. Tune from evidence.
3. Run force/control updates in `PreSimulation`, not `RenderStepped`. Sample the expensive wave solution at a bounded 15–30 Hz and smoothly extrapolate/interpolate height and velocity between samples; do not chase every capillary/high-frequency fluctuation.
4. Apply a critically damped, acceleration-limited controller relative to water velocity. Separate:
   - gravity compensation/vertical surface tracking;
   - horizontal input propulsion;
   - mild horizontal water-relative damping;
   - ascend/dive input.

   Do not apply one isotropic `-relativeVelocity` term that erases the player's movement.
5. Drive desired horizontal velocity from `Humanoid.MoveDirection` or the active cross-platform control path. Support keyboard, gamepad, and touch. Provide deliberate ascend and dive actions; never rely on PC-only key polling.
6. Clamp acceleration, force, velocity, and force slew. The controller should follow broad swell but filter short-wave vertical jitter. It must not pin the root exactly to an oscillating height sample.
7. Decide intentionally how Humanoid state/animation is handled for custom water. Since Roblox's documented Swimming state is Terrain-water-oriented, test whether entering it once is stable in this setup. If not, own the custom locomotion state and animation cleanly. Never spam `ChangeState` every frame.
8. Keep character physics on the owning client for responsiveness, but server-validate impossible swim speeds/displacement and all gameplay interactions. The client must never be able to apply this force to a ship assembly.
9. Do not add a flat hidden Terrain-water ocean unless a controlled test proves it creates no second waterline, no conflicting buoyancy/state threshold, and remains aligned enough with moving waves. A hidden flat volume is not an automatic solution.

Required swim tests: stationary tread, full directional movement, ascend/dive, jump into water, climb out, repeated crest crossings, shore transition, Trade/Gale/Mythic, low and high frame rate, 150–250 ms simulated latency, respawn, boarding, sitting, standing, and two minutes of continuous movement. Record position/velocity/force traces and state-transition count; there must be no threshold chatter.

## Phase 3 — make the ocean affordable before adding visual detail

### 3A. Establish explicit budgets

Use the baseline profile to set and enforce budgets. Reasonable initial targets, to refine on the agreed test devices, are:

- High moving-water topology: at most about 3,000–4,500 vertices, not 8,593;
- no more than 4–6 EditableMeshes total for near plus transition water;
- no more than about 1.5–2.0 million render component iterations/second outside a bank blend;
- no more than 120,000 position values and 60,000 normal values committed per second on High;
- p95 total ocean client script time at or below 3.0–3.5 ms on the named desktop target and at/below the budget established for the named mobile target;
- stable 60 Hz frame budget where the rest of the place permits it, with p95 frame time below 16.67 ms on the stated desktop target;
- no steady-state Instance creation/destruction and no unbounded pools.

If a target cannot be met, report the measured limiting stage and make quality reduction visible in diagnostics. Do not silently call the system “performant.”

### 3B. Redesign ring profiles instead of scaling one square grid

Give each ring an explicit resolution, spacing, component band, normal cadence, and position cadence. Do not reuse one resolution for every level. A good starting experiment is a 33×33 L0 and progressively smaller/coarser donut levels, with only the closest one or two receiving frequent dynamic normals. Retain enough silhouette vertices for readable 20–120-stud waves; use the PBR normal for sub-geometry ripples.

L0 does not need 60 Hz on every device. Test 30, 40, and 45 Hz with synchronized time and smooth visual phase. Outer levels can update at 15/10/5 Hz. Lowering update cadence must not slow simulated wave time.

### 3C. Add a renderer-specific batch evaluator

`WaveMath.EvaluateLabel()` constructs a full sample table and many temporary Vector2/Vector3 values for every vertex. Build a render-grid hot path that:

- precomputes each component's time phase and constant coefficients once per update;
- writes position and, where needed, normal arrays directly;
- evaluates shared and residual wavelength bands in one pass rather than evaluating two whole prefixes;
- omits foam, velocity, inverse mapping, disturbances, and other fields when a render vertex does not need them;
- avoids per-vertex table allocation;
- optionally uses phase recurrence along regular grid rows if profiling proves it correct and faster;
- remains deterministic and numerically equivalent at shared boundaries.

Keep the rich authoritative sampler for gameplay. Do not reduce buoyancy correctness merely to make render vertices cheaper.

### 3D. Eliminate snap and UV spikes

Prove the active material path. If MaterialVariant projection ignores EditableMesh UV IDs, stop creating face UVs and remove all recenter `SetUV` loops. Let the tested world/projected material provide stable detail.

If explicit UVs are actually required, update them in one `BatchSetValues(uvIds, values)` operation per affected ring, never thousands of individual `pcall(SetUV)` calls. Profile it. Snap rings at mathematically compatible per-level intervals and update only rings that crossed their own threshold while preserving watertight boundaries. Do not make every outer ring rebase at every four-stud crossing.

### 3E. Centralize and budget visual sampling

Create a client visual sample scheduler/cache rather than allowing every controller to run its own full inverse solve:

- combine foam and spray candidate sampling;
- cache identical/near-identical XZ/time requests for the frame or sampling tick;
- update wake surface points at a measured 15–30 Hz and interpolate trail anchors;
- update shoreline at 5–10 Hz with camera distance culling;
- share an appropriate camera-surface sample between underwater presentation systems;
- use cheaper non-inverse/Lagrangian sampling only where visual error is measured and acceptable;
- distance-cull wakes and effects for ships that cannot influence the camera.

On the server, use the validated 4–8 ship points, a specialized height/vertical-velocity sample where sufficient, and a measured physics cadence. Do not allocate a full foam-rich sample table at every point if the solver only needs height, normal, and velocity.

### 3F. Make quality adaptation real and non-destructive

Select a safe initial topology before creating meshes. Do not force every client to endure High for 15 seconds. Use an explicit player setting, graphics level/device capability plus a short non-render-blocking calibration, or default to a Medium-safe topology and raise only safe cadences/effects.

Runtime adaptive changes may alter component bands, cadences, normal rings, transition detail, and VFX budgets; they must not destroy working topology. `SetCap` must no-op when unchanged and resize only the difference when changed. Debug seam checks and attribute spam must be disabled outside Studio diagnostics.

## Phase 4 — replace the hard far-LOD boundary

The final animated ring must not meet a flat, differently colored horizon while it still has six moving components.

1. Add one or a very small bounded number of coarse **transition** meshes outside the near clipmap. At its inner edge it must exactly match the final near ring's long-wave position and normal. Across a broad 400–800+ stud band, smoothly reduce the remaining long-wave displacement and slope to zero with a C1-continuous morph. At its outer edge, position must equal mean sea level and normal must equal world up.
2. Keep the transition extremely cheap: roughly 4–6 long components, low vertex density, 10–15 Hz or lower after profiling, and no foam/short-wave evaluation. Stay within the total EditableMesh/vertex budgets. If one mesh exceeds supported extent, use a few deterministic sectors—not dozens of independent dynamic tiles.
3. Begin the static horizon exactly at the transition's flat outer boundary. Give near, transition, and horizon the same active material and **same water tint**. Use `horizonColor` to drive atmosphere/sky blending, not a hard square Part color change.
4. Ensure position and normal agreement at both boundaries: maximum positional gap `<= 0.02` stud and normal disagreement `<= 1 degree` at multiple times/presets. Test actual committed vertices/edge interpolation, not two calls to the same sampling function.
5. Keep the complete static annulus to at least 6,000 studs or the range needed by the maximum supported camera height. Recenter it only at a coarse hidden threshold and never allocate while moving. Use atmosphere/haze to hide the terminal edge without crushing all scene contrast.
6. Make profile distance fields truthful. Either use configured range/cadence/resolution or remove dead settings. Avoid the present outcome in which all tiers end moving geometry at the same 768 studs despite different `ringCount` values.
7. Add an aerial test at 40, 80, 150, and maximum intended camera height. No square color band, frozen ring, height step, normal/specular step, hole, z-fighting, terminal edge, or recenter pop is acceptable.

Do not solve this with a fully overlapping plane below transparent moving water. Keep near water effectively opaque and maintain one visible surface.

## Phase 5 — rebuild the water look from a clean material baseline

Roblox does not expose arbitrary custom water shaders here, so use the supported PBR/material and lighting tools exceptionally well. Macro shape belongs in geometry; the map supplies only small-scale optical breakup.

### 5A. Inspect or reject the current maps

Open all four current asset IDs as authoring-time images and inspect seams, frequency content, channel convention, and permissions. If any map is inaccessible, unapproved, non-seamless, strongly patterned, or visually wrong, remove it from the active material. Do not keep it because the manifest calls it generated/owned.

Establish this baseline first:

- **ColorMap:** omit it or use near-white/neutral, very-low-contrast albedo. No photo water, blue blobs, baked highlights, baked foam, stars, or recognizable repeated features. Let geometry, part tint, lighting, and atmosphere create the large-scale color.
- **NormalMap:** a genuinely seamless tangent-space OpenGL ripple normal. It should be subtle, contain only small/medium ripple breakup, average near a flat normal, and contain no baked macro waves/foam. Geometry already supplies the swell and crest silhouette.
- **RoughnessMap:** restrained grayscale appropriate for glossy dielectric water, with small variation rather than high-contrast mottling. Test approximately 0.08–0.22 effective roughness across calm/storm variants.
- **MetalnessMap:** pure black; water is non-metal.

If multiple roughness states are important, pre-author and preload a small set such as Calm/Trade/Storm MaterialVariants using the same validated color/normal scale. Switch discretely at controlled weather thresholds. Do not publish a smoothly blended roughness value that the renderer never uses.

### 5B. Tune scale and projection visually

Test `StudsPerTile` values such as 12, 24, 48, and 96 from deck, mast, aerial, and moving cameras. Choose based on captures, not a generic rule. Compare `Regular` and `Organic`; retain Organic only if it introduces no tile/Part orientation seams or implausible directional breakup. The normal detail must stay spatially stable when the camera and clipmap recenter.

Near, transition, and horizon must use the same projection, scale, map set, and tint. There must be no material reapplication burst when crossing an LOD boundary.

### 5C. Stop per-frame material churn

Track only actual water surface instances as they are created/destroyed. Apply a fixed MaterialVariant once. During weather blends, update only genuinely dynamic tint/atmosphere values at a bounded cadence or when a quantized value changes; do not scan all `OceanRuntime` children and rewrite dozens of attributes every RenderStepped frame.

Preload the exact material and VFX assets before exposing the surface. Scope `AssetFetchFailed` diagnostics to the ocean's known asset manifest; an unrelated failed game asset must not be mislabeled as a water-material failure. Authoring-time Plugin Security inspection remains the source of map IDs, while runtime checks verify variant presence, preloading, and fetch status honestly.

### 5D. Tune lighting without hiding defects

Inspect the live Lighting/Sky/Atmosphere. Tune environment specular response, sun direction, atmosphere, color correction, and restrained bloom so water has readable highlights from deck level at noon, sunset, night, fog, and Gale. Preserve the rest of the game's art direction. Do not use excessive bloom, haze, darkness, or transparency to hide tiling/seams.

## Phase 6 — make foam, spray, and wakes visibly belong to the water

The current crest foam scan is a sparse regular 18-stud grid. Pool entries are reassigned by scan order, so a Trail can jump from one unrelated qualifying cell to another and draw a false streak. Spray uses a similar anonymous pool. Replace this with persistent spatial tracks.

1. Build candidates at a bounded cadence from crest height, positive/upward crest motion, slope, compression, and foam persistence. Use blue-noise/jittered candidate placement or analytically trace crest directions so the result does not reveal a square grid.
2. Assign each active foam patch a persistent key/track with position matching, lifetime, age, and last-seen time. Reuse a Trail/card only after clearing its history. Never teleport an enabled Trail between unrelated crests.
3. Create connected, low-profile whitecap ribbons/cards aligned to the local surface tangent and offset only slightly along the sampled normal. Advect and fade them over roughly 1–3 seconds. Keep them grounded as waves move.
4. Reserve particles for small breaking spray/spindrift. Gate them by preset, wind, crest sharpness, upward velocity, and camera distance. No hovering blobs, sparkles, regular dots, or blanket-white ocean.
5. Validate the actual foam and spray texture pixels, alpha, ownership, and published-client loading. A correct asset ID is not proof that it looks like foam.
6. Keep wake tracks persistent per ship. Sample bow/stern/port/starboard at 15–30 Hz, interpolate anchors, clear history on teleport/respawn, and vary V width, lifetime, and turbulence with hull size, speed, acceleration, and turn rate. A stationary ship must not generate a wake.
7. Share foam/spray samples and obey quality budgets. Candidate generation may be lower density on Medium/Low, but Trade must still show occasional readable whitecaps.

Visual targets:

- Glass: almost no foam, only subtle highlights.
- Trade Sea: clearly readable moving crests with intermittent connected whitecaps and a grounded ship wake.
- Gale: frequent whitecaps and wind-driven fine spray, without making the whole ocean white.
- Mythic Storm: dramatic layered foam and spray while retaining dark troughs and readable wave shape.

## Phase 7 — underwater presentation

Preserve the camera-water hysteresis already present, but move expensive sampling to the shared scheduler. Build a coherent underwater state with a brief crossfade rather than one abrupt ColorCorrection toggle. Add restrained fog/color shift, muffled audio/equalization if the project has audio support, and a surface-exit transition. Do not create a second visible water sheet.

Camera underwater state and character swimming state may have different thresholds, but both must derive from the same synchronized surface and must not chatter. Test rapid crest passages with a stationary camera/player.

## Automated and live acceptance gates

### Geometry/material tests

- Actual built ring/transition counts, vertex/triangle counts, extents, and update cadences match the selected profile.
- Fine/coarse and moving/transition/static boundaries pass `<= 0.02` stud position and `<= 1 degree` normal tolerance at multiple times for all presets.
- No T-junction crack, degenerate triangle, overlap, inner-hole coverage, or outer annulus gap.
- Camera recentering preserves boundaries and material projection.
- Texture/material path, variant, scale, and tint remain identical across near/transition/horizon and through adaptive quality.
- A material swatch proves actual maps, not just manifest metadata.

### Ship tests

- Empty raft: two-minute soak in Glass, Trade, Gale, and Mythic.
- Seat entry/exit: at least 20 cycles at different wave phases; no force spike, unseat, inversion, or ownership churn.
- One seated player, one standing passenger, then two seated players if supported.
- Boarding directly from swimming and leaving the seat into water.
- Slow cruise, full speed, hard port/starboard turns, reverse, acceleration/deceleration, and rogue-wave/event crossing.
- Studio network emulation at 150–250 ms latency plus packet loss and two clients.
- Record max roll/pitch, angular velocity, height/draft error, force/torque, owner changes, and recoveries. Routine Trade motion should remain upright and self-recover; no inversion is allowed in the acceptance run.
- `OceanSwimForce` stays disabled and zero whenever seated.

### Swimming tests

- Enter/exit transitions do not exceed one state change per genuine crossing.
- No visible root jitter while treading or moving through a passing crest.
- Directional movement remains responsive at low/high frame rate and latency.
- Ascend/dive, shore exit, respawn, boarding, and seating cleanly release forces.
- The character controller never becomes part of a ship assembly while its swim force is active.

### Performance tests

Run at least High and Medium on named hardware/emulation for stationary, fast travel, weather blend, one ship, multiple ships, foam-heavy Gale, swimming, and seated driving. Provide p50/p95/p99 for:

- total frame time;
- total ocean client time;
- render evaluation and commit;
- UV/material work;
- foam/spray/wake/underwater/swim;
- server heartbeat and buoyancy time per ship;
- dynamic vertex/normal/UV commits per second;
- wave component evaluations/s and sample counts by consumer;
- live Instance/EditableMesh/particle/trail counts and memory trend over five minutes.

There must be no periodic snap spike, no material-transition scan spike, no pool rebuild spike, no growing object count, no fallback after successful initialization, and no ocean-related red Output error.

### Required visual capture matrix

| Preset/scenario | Views | Required result |
|---|---|---|
| Glass | deck grazing, mast, aerial | clean glossy detail, almost no foam, no tiling or distance band |
| Trade Sea cruising | deck, stern, side | readable crests, intermittent connected foam, grounded V wake |
| Gale | deck and mast, 30+ seconds | sharp multi-directional waves, whitecaps/spray, stable ship |
| Mythic Storm | deck and 80-stud aerial | epic silhouette and layered foam without folding, grid, or blanket white |
| Distance transition | 40/80/150/max-height aerial, cardinal and diagonal | no square tint/motion/normal/height level or horizon edge |
| Recenter traversal | slow walk and fast ship in 8 directions | no geometry pop, UV slip, hitch, trail teleport, or crack |
| Water entry/exit | third-person and camera crossing | stable swimming and one clean visual waterline |
| Seat test | exterior and physics-debug view | no flip, force spike, ownership churn, or self-collision |
| Published client | day/sunset/night/storm | assets load and match Studio; performance remains within budget |

Inspect every capture yourself. If a capture reveals the user's reported symptom, iterate before declaring completion.

## Forbidden shortcuts

- Do not flatten or shrink waves to conceal physics/LOD defects.
- Do not add a transparent overlapping ocean plane.
- Do not hide the 768-stud discontinuity with a darker tint or excessive fog.
- Do not retain the current texture maps without inspecting the actual pixels and rendered swatch.
- Do not claim changing roughness unless the active material actually changes.
- Do not call thousands of individual UV mutations without proving they are required.
- Do not keep production seam diagnostics running every 0.5 seconds.
- Do not spam `Humanoid:ChangeState` or let swim force remain active while seated/disabled/dead.
- Do not tune buoyancy from instantaneous combined ship/occupant assembly mass.
- Do not apply damping at dry buoyancy points.
- Do not transfer ship ownership while the server is the force authority.
- Do not iterate `SetNetworkOwner` over every ship part.
- Do not use CFrame resets as normal stability control.
- Do not rebuild full VFX pools on an unchanged quality cap.
- Do not teleport enabled foam Trails between unrelated sample cells.
- Do not claim completion from unit tests, Explorer inspection, manifest strings, or a single flattering screenshot.

## Required completion deliverables

Return all of the following:

1. Implemented Studio place and repository changes, exact final commit, and a concise file-by-file summary.
2. Before-fix causal evidence for distance band, lag spikes, swimming jitter, and seated flip, including the seat/swim-force trace.
3. Live ship assembly validation before and after repair: roots, mass/COM, point geometry, collisions, ownership, and force budgets.
4. Before/after profiler p50/p95/p99 tables and measured sample/commit counts for High and Medium.
5. Final topology/transition design with actual counts and boundary test results.
6. Final material map IDs, source/ownership/moderation status, authoring-time pixel inspection, selected projection/scale, preload/fetch results, and lighting swatches.
7. Automated results for geometry, transition, waterline, swim state, seated-force isolation, buoyancy stability, ownership, and performance budgets.
8. Timestamped captures for the full visual matrix, plus notes on what you changed after each failed visual iteration.
9. Five-minute High and Medium soaks showing stable object/memory counts, no fallback, no ocean Output error, no ship inversion, and no controller chatter.
10. An explicit final checklist confirming that the material no longer looks like a fallback, the distance level is gone, foam/wakes are clearly visible and grounded, swimming is responsive without jitter, sitting cannot activate swim force or flip the ship, and the agreed performance gates pass.

## Primary Roblox references

- VectorForce and center-of-mass behavior: <https://create.roblox.com/docs/reference/engine/classes/VectorForce>
- Physics assemblies, mass, center of mass, and assembly root: <https://create.roblox.com/docs/physics/assemblies>
- Network ownership and assembly ownership: <https://create.roblox.com/docs/physics/network-ownership>
- `RunService.PreSimulation`: <https://create.roblox.com/docs/reference/engine/classes/RunService/PreSimulation>
- Humanoid state definitions (Swimming is Terrain-water-oriented): <https://create.roblox.com/docs/reference/engine/enums/HumanoidStateType>
- Seat behavior and `SeatWeld`: <https://create.roblox.com/docs/reference/engine/classes/Seat>
- Collision groups and filtering: <https://create.roblox.com/docs/workspace/collisions>
- MaterialVariant maps, pattern, and `StudsPerTile`: <https://create.roblox.com/docs/reference/engine/classes/MaterialVariant>
- EditableMesh batch mutation: <https://create.roblox.com/docs/reference/engine/classes/EditableMesh/BatchSetValues>
- EditableMesh device-memory failure behavior: <https://create.roblox.com/docs/reference/engine/classes/AssetService/CreateEditableMesh>
- MicroProfiler/performance identification: <https://create.roblox.com/docs/performance-optimization/identify>

Implement in the stated order. The exit gate is not “better than before”; it is a visually continuous, materially convincing ocean with readable foam, stable custom swimming, a seat-safe ship, and measured performance that stays within budget during real gameplay.
