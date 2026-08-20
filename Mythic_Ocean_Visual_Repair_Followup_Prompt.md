# Mythic Ocean Visual Repair — Follow-up Implementation Prompt

You are the coding agent responsible for repairing the existing ocean implementation in `ng643/Mythic`. Work directly in Roblox Studio through the Roblox Studio MCP and update the repository implementation. Do not merely give advice or a plan: inspect the live place, implement the fixes, run the tests, visually inspect the results from multiple camera angles, and iterate until the acceptance gates below pass.

Audited baseline: commit `0597b7911eca0e9f7c3ea2c948ed6ac436679aba` (`Remove flat ocean far plane`). If the repository has advanced, first re-check every cited defect against the current code and retain any fix that is already correct.

The current ocean still fails the intended visual bar. This is not primarily a matter of tweaking colors. There is a client startup error that can prevent all foam/spray/wake controllers from starting, the clipmap rings are mathematically discontinuous, the ocean ends in a square roughly 768 studs from the camera, the PBR texture coordinates move with the camera, the wave spectrum is too smooth, and the visible foam/wake assets are placeholder sparkles. Repair these causes in the order specified below.

## Preserve the improvements that are already correct

Do not regress these repairs from the prior pass:

- Deep-water period-to-wavelength conversion now uses `lambda = g*T^2/(2*pi)` in stud units.
- Gameplay and buoyancy use the full authoritative wave bank through `SampleForGameplayWorldXZ`.
- Ships use explicit `OceanBuoyancyPoint` attachments and normalized weights.
- The adaptive-quality frame-time input uses frame delta time.
- EditableMesh clipmaps are enabled by default and the old fully overlapping flat far plane was removed.
- Ocean state remains deterministic and synchronized between server and clients.

## P0 — make the full client system start cleanly

Fix this before evaluating any visual system.

In `OceanClientMain.client.luau`, `GetAttributeChangedSignal("OceanQuality"):Connect(applyVfxBudget)` currently executes before the local `applyVfxBudget` function is declared. In Luau this reference is not the later local function, so `Connect` receives `nil` and the client script can terminate before the underwater, foam, spray, wake, swimming, buoyancy visualizer, and shoreline controllers are started.

Required changes:

1. Declare `foamController`, `sprayController`, and `applyVfxBudget` before connecting or invoking the callback. Then connect the signal only after all referenced objects exist.
2. Use an explicit startup sequence with contextual error reporting. Do not swallow startup errors in an empty `pcall`. If a subsystem fails, identify the subsystem and error in Output and set `Workspace.OceanRuntime.OceanClientStatus = "error"` plus an `OceanClientError` string.
3. Set `OceanClientStatus = "running"` only after every required controller has successfully started.
4. Add a small automated Studio smoke check that asserts the renderer, material, underwater, foam, spray, wake, swimming, and shoreline systems all reached their running state.
5. Debug flags must default to `false`, especially `OceanDebugBuoyancy`. Production feature enablement must not be controlled by attributes named `OceanDebug*`; use separate `OceanFoamEnabled`, `OceanSprayEnabled`, `OceanWakesEnabled`, etc. Debug flags should only reveal diagnostics. Ordinary Studio play must never display the red/green Neon buoyancy balls.
6. Start a clean Studio client/server session and require zero ocean-related red errors before proceeding.

## P0 — replace the broken clipmap seam logic

The current ring logic cannot be tuned into correctness. Rewrite the topology and transition math.

### Why it is broken

Every ring fades its complete displacement to zero over the outer 28%. At the L0/L1 shared boundary, for example, L0 has `morph = 0` and is at mean sea level while L1 has `morph = 1` and retains its full wave displacement. The same contradiction occurs at the L1/L2 and L2/L3 boundaries. The rings therefore cannot share positions or normals, producing cracks, vertical curtains, overlaps, square bands, and odd lighting.

`cellIncluded(level, i, j, innerHalf)` is also asymmetric because it tests integer cell indices with `max(abs(i), abs(j)) >= innerHalf`. One side includes a boundary cell the other side excludes. The inner skirts are then placed at nominal `+/-innerHalf` even though the actual hole boundary is not symmetric, creating additional overlap and walls.

### Required geometry implementation

1. Build a truly symmetric donut for every level above L0. Use either explicit index ranges or a cell-center test such as `max(abs(i + 0.5), abs(j + 0.5)) >= innerHalf`, and prove that the hole extents are identical on all four sides.
2. Make adjacent levels watertight. Boundary vertices that occupy the same world coordinate must have the same final world position to within `0.02` stud and compatible normals at the same synchronized time.
3. Do **not** fade every ring to mean sea level. At an LOD transition, morph the fine representation toward the next-coarser representation. In practice, preserve the long-wave displacement shared by both levels and fade only the fine-level residual/short-wave contribution that the coarser level does not represent. The original geometry-clipmap rule is that the transition region morphs into the next coarser level while maintaining a watertight boundary.
4. Use a consistent component filter per LOD. Define explicitly which long-wave components both sides share and which short-wave components are attenuated. Do not let `componentCap` select a semantically arbitrary prefix. Store or derive LOD bands from wavelength/energy, and ensure transition samples use exactly the same shared component set.
5. Stitch T-junctions correctly. A coarse edge spans two or more fine edges; either use transition triangles/index patterns or force fine boundary vertices onto the interpolated coarse edge. A vertical skirt may exist only as a final defensive measure below the visible surface, never as the primary way to hide an inconsistent seam. Remove inner skirts if the repaired topology makes them unnecessary.
6. Camera recentering must not tear or pop. Snap each level in a mathematically compatible way and morph/reindex during a shift if needed. Test slow sub-stud camera movement and fast boat/camera travel in all cardinal and diagonal directions.
7. Add a deterministic seam test that samples every shared edge at several times and presets, reports maximum position and normal disagreement per level pair, and fails above the tolerance. Add a topology test for holes, overlaps, missing cells, degenerate triangles, and T-junctions.
8. In a debug-only seam view, color each LOD distinctly and draw its true boundaries. This view must default off and must be captured once as completion evidence.

Primary references:

- Geometry clipmaps and transition morphing: <https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry>
- Original geometry-clipmap project: <https://hhoppe.com/proj/geomclipmap/>

## P0 — restore an ocean horizon without an overlapping full plane

The current EditableMesh size guard stops after four spatial levels on every quality tier. With the present profiles, the outer ring has a square radius of approximately 768 studs. Since the far plane was removed, the water can simply end there.

Implement a non-overlapping horizon solution:

1. Keep the near animated clipmap, but surround it with a segmented coarse horizon annulus made from multiple tiles/mesh sectors so no individual MeshPart exceeds engine bounds. It should extend at least 6,000 studs from the camera; prefer 8,000–12,000 if the place scale and performance permit.
2. The horizon annulus begins where the final animated level ends. It must not be a single full plane underneath the transparent near mesh.
3. Preserve long swell in the first horizon band if affordable, then smoothly reduce only the remaining displacement toward mean sea level across the final distant band. Use Atmosphere/haze to hide the terminal edge.
4. Recenter horizon tiles without a visible jump or texture slip. From deck height, mast height, a 60–100-stud aerial camera, and the maximum intended camera height, no square edge, void, duplicate surface, z-fighting, or underwater slab may be visible.
5. Make quality profiles control both detail and range intentionally. Do not leave `ringCount` values silently ineffective because all profiles hit the same hard-coded extent.

## P0 — make surface detail world-locked and use one verified PBR path

The current UVs are created from ring-local labels once and remain unchanged when the ring origin snaps. The apparent normal/albedo texture therefore follows the camera and teleports at each recenter.

Required changes:

1. Make all detail UVs world-locked. When a ring origin changes, update the UV values from `(worldXZ / tileScale)` or use a shader/material approach that is provably world-aligned. The pattern may drift slowly with wind as an intentional effect, but it must not follow the camera.
2. Use at least two visually non-repeating normal scales with different directions/speeds if the supported Roblox material route permits it. If Roblox cannot layer those maps directly, put the macro shape in geometry and use one excellent seamless normal map; do not create texture swimming through per-frame ad hoc offsets.
3. Choose one authoritative PBR pipeline: either `SurfaceAppearance` with the EditableMesh UVs or a verified `MaterialVariant`. Do not stack a `SurfaceAppearance` and `MaterialVariant` with redundant maps and assume both contribute predictably.
4. Verify the ColorMap, tangent-space NormalMap, RoughnessMap, and black/non-metal MetalnessMap in the **published experience client**, under day, sunset, night, and storm lighting. Check asset ownership/permissions. Listen for `ContentProvider.AssetFetchFailed` and inspect Output; never silently swallow map assignment failures.
5. Make state transitions affect the active rendering path. At present `roughness` is blended but never applied, `waterMaterialVariant()` is unused, and tint is assigned to `MeshPart.Color` even when the appearance may control surface color. Implement a small set of pre-authored roughness variants or another supported route and apply water tint to the property that actually produces a visible change.
6. Keep near water effectively opaque. Do not use near-surface transparency to hide geometry defects; transparency reveals inner skirts, lower faces, intersecting rings, and any surface below them.
7. Add an asset/material validation report listing the selected path, IDs, fetch status where supported, and the actual instance/property values used in the running published client.

Roblox references:

- SurfaceAppearance/PBR workflow: <https://create.roblox.com/docs/art/modeling/surface-appearance>
- SurfaceAppearance API: <https://create.roblox.com/docs/reference/engine/classes/SurfaceAppearance>
- Asset permissions: <https://create.roblox.com/docs/projects/assets/privacy>
- ContentProvider failure diagnostics: <https://create.roblox.com/docs/reference/engine/classes/ContentProvider>

## P1 — give the sea readable waves instead of smooth rolling hills

The corrected period conversion is worth preserving, but the current generated wavelengths are overwhelmingly long. Depending on preset, the shortest geometry waves are roughly 38–396 studs, while horizontal Gerstner displacement is scaled so conservatively that measured aggregate steepness is only about `0.011, 0.033, 0.054, 0.076, 0.088` from Glass through Mythic. The configured safety cap is `0.82`, so storm crests remain rounded and indistinct.

Rebuild the artistic spectrum while preserving physical coherence:

1. Use approximately 12–16 deterministic geometry components divided into explicit bands: long swell, dominant wind sea, and a lower-energy 20–120-stud short/mid geometry tail visible primarily in L0/L1. Normal maps handle capillary detail; they are not a substitute for readable mid-scale silhouettes.
2. Preserve the requested significant wave height. After changing band energies, renormalize vertical amplitudes so `Hs = 4*sqrt(sum(a_i^2/2))` remains within 5% of the preset target.
3. Distribute Gerstner horizontal amplitude/steepness by band and energy, not by multiplying everything by one tiny constant. Tune approximate aggregate steepness targets such as Glass `0.03–0.08`, Calm `0.08–0.16`, Trade `0.16–0.28`, Gale `0.28–0.42`, and Mythic `0.38–0.55`. These are starting artistic ranges, not permission to violate the no-fold condition.
4. Validate the horizontal mapping Jacobian over a dense deterministic space/time sample. It must remain safely positive and show no loops/self-intersections. Reduce or redistribute steepness when required; never set every component to the global maximum.
5. Preserve directional spread and add controlled cross-sea energy for storms so the surface does not look like a single synchronized sine sheet. Avoid obviously periodic grids and repeated peaks.
6. Produce diagnostic output per preset: component count, min/median/max wavelength, target versus measured Hs, aggregate steepness, minimum/percentile Jacobian, slope percentiles, and crest-height percentiles.
7. Visually tune from moving deck level. Trade Sea must show clear, readable crests without looking stormy. Gale and Mythic must show sharp silhouettes and directional complexity without folding or jitter.

Gerstner reference: <https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-1-effective-water-simulation-physical-models>. In that formulation, increasing the horizontal steepness parameter sharpens crests; exceeding its safe bound creates loops.

## P1 — replace placeholder sparkles with actual ocean foam, spray, and wakes

The current `FoamController`, `SprayController`, `WakeController`, and `ShorelineController` all use `rbxasset://textures/particles/sparkles_main.dds`. That is a placeholder and cannot meet the visual target. The base mesh also has no crest color/foam channel at all.

### Fix the foam signal first

Current state generation computes `foamThreshold = baseThreshold - foamAmount*0.18`, but WaveMath triggers compression foam when `jacobian < foamThreshold`. Increasing `foamAmount` therefore lowers the threshold and can make compression foam harder to trigger. With the current very low steepness, the Jacobian is usually near 1, so storm whitecaps rarely appear.

1. Redefine the threshold/gain/multiplier so foam coverage increases monotonically from Glass to Mythic.
2. Sample a fixed spatial/time grid and report mean, 50th, 90th, 95th, and 99th percentile foam per preset. Tests must verify monotonic coverage and prevent broad foam in troughs.
3. Use crest height, positive upward/forward crest motion, slope, and horizontal compression together. Add hysteresis/persistence so foam survives briefly after a crest instead of flickering every sample.

### Implement layered foam

1. Add a cheap surface-level whitecap layer on the near mesh or on tightly fitted surface cards/ribbons. It must produce connected streaks along crests, not isolated dots on an 18-stud square grid. If EditableMesh vertex colors are used, create color IDs, assign face colors correctly, and drive a foam-capable material; merely calculating `sample.foam` is not visible rendering.
2. Add persistent crest ribbons/cards that follow the local crest tangent derived from surface derivatives, align to the sampled normal, advect with surface/wind velocity, widen slightly, break up, and fade over about 1–3 seconds. Pool them and budget by quality/distance.
3. Reserve particles for fine spindrift and breaking spray. Gate heavy spray by storm intensity, wind speed, crest sharpness, and upward velocity. Use `WindAffectsDrag`/GlobalWind behavior where appropriate and verify direction.
4. Use proper owned seamless alpha foam/spray textures. No sparkle, star, smoke-puff, or generic placeholder texture is acceptable. If the needed asset cannot be created/uploaded/permissioned through the available workflow, stop and report the exact asset blocker instead of hiding it with sparkles.
5. Foam must be visible in Trade Sea, clearly stronger in Gale, and dramatic but not blanket-white in Mythic. It must not hover, intersect far above the water, appear in regular square rows, or disappear on the next 0.1-second scan.

### Repair wakes

1. Pass `waveField` into `WakeController`. Each frame/update, transform configurable bow/stern/port/starboard wake sample points to world XZ and sample the same synchronized `WaveField` used by rendering and buoyancy.
2. Position wake nodes at the sampled surface plus a small normal offset. Orient them in the local surface tangent plane. Do not copy `root.CFrame`, do not hard-code a constant root-local Y, and do not use `Trail.FaceCamera = true` for a strip meant to lie on the water.
3. Generate a V-shaped bow wake and turbulent stern trail whose width, intensity, persistence, and emission depend on speed, hull size/draft, acceleration, and turning. Keep it deterministic enough not to jitter with network ownership changes.
4. Visually test a stationary ship, slow turn, cruising speed, sharp turn, acceleration, deceleration, wave crest crossing, and Gale. Wake foam must remain attached to the sampled surface and never cut through or float above waves.

## P1 — correct the EditableMesh batch update path

The official current `EditableMesh:BatchSetValues` signature is `BatchSetValues(ids, values)`. The renderer currently passes three arguments by inserting `Enum.MeshAttribute.Position` or `Enum.MeshAttribute.Normal`, so the protected call falls back to per-vertex updates. Correct both calls to use only the ID array and values array. If the call fails, report the error once with context, switch the affected path to fallback, and update `stats.batchAvailable` truthfully.

Reference: <https://create.roblox.com/docs/reference/engine/classes/EditableMesh/BatchSetValues>

## Boat/waterline regression gate

The visual rewrite must not desynchronize the boat from the visible surface.

1. Rendering, buoyancy, swimming, foam, and wakes must all use the same state, epoch, transition blend, disturbance list, and world-XZ inversion semantics.
2. At every buoyancy attachment, compare the gameplay sample height with a high-precision render sample at the same XZ/time. Log maximum and RMS disagreement; require maximum vertical disagreement under `0.15` stud in the near field during steady state and transitions.
3. Test every weather preset, a mid-transition preset change, a rogue packet, stationary and moving boats, high latency simulation, and ownership transfer. The hull may submerge naturally into a trough or under severe wave loading, but the sampled waterline must not pass through it because the renderer and physics disagree.
4. Verify the ownership policy recognizes the actual driver seat class used by the ship, including `VehicleSeat` if present. Do not move authoritative state or force application to the client merely to conceal a visual mismatch.

## Required visual iteration workflow

Technical tests alone are insufficient because the reported failure is visual.

After each major stage, run the place through Roblox Studio MCP, enter Play mode, move the camera/boat, capture images, inspect those images yourself, and iterate. Do not claim success from the Explorer tree or Output alone.

Capture this matrix at minimum on High quality:

| Preset | Camera/view | Required observation |
|---|---|---|
| Glass | Deck, low grazing angle | Stable world-locked highlights; almost no foam; no grid/seams |
| Trade Sea | Deck, moving boat | Clearly readable mid-scale crests; intermittent connected foam; grounded wake |
| Gale | Deck and mast | Sharper multi-directional waves, frequent whitecaps and wind-driven spray |
| Mythic | Deck and 80-stud aerial | Epic scale without loops, square LOD bands, horizon edge, or blanket foam |
| Any | Underwater crossing | One clean waterline; no duplicate sheet, skirt wall, or flicker |
| Any | Debug LOD view | Symmetric rings, exact boundaries, no holes/overlaps/T-junction tears |

Also test Low and Medium on a constrained/device-emulation profile. Record a short traversal long enough to cross several recenter thresholds and weather transitions.

## Performance gates

- Preserve adaptive quality and pooled VFX.
- Profile separately: wave evaluation, vertex commit, normal/UV update, foam/ribbon update, spray, wake, and total ocean CPU time.
- No per-frame Instance creation/destruction in steady state.
- No unbounded particle/ribbon pools or per-frame full tagged-ship rescans.
- On the agreed target device, High should hold its target frame rate during Trade Sea and remain playable in Mythic; report p50/p95 frame time and p50/p95 ocean time instead of a single best frame.
- Degrade in this order: distant normals/UV update cadence, distant short-wave components, spray count, ribbon density, outer detail cadence, then ring resolution. Never degrade shared authoritative sampling used for buoyancy.

## Forbidden symptom patches

Do not:

- flatten the near surface or reduce all wave amplitudes to hide seams;
- add a fully overlapping plane under transparent animated rings;
- leave a hard square ocean edge at roughly 768 studs;
- use inner vertical walls as the visible seam solution;
- keep debug visualization enabled by default;
- swallow material/asset/runtime errors in empty `pcall`s;
- use `sparkles_main.dds` or another generic placeholder for ocean foam/wakes;
- attach wakes directly to the hull without sampling the wave surface;
- declare completion without viewing captured gameplay images.

## Completion deliverables and exit gates

Do not stop until all of these are supplied:

1. The implemented source/place changes and a concise file-by-file change summary.
2. Clean Output from fresh server + client startup, with `OceanClientStatus = "running"` and every subsystem confirmed started.
3. Automated test results for spectrum/Hs, no-fold Jacobian, monotonic foam coverage, symmetric topology, seam position/normal agreement, transition continuity, and render-versus-gameplay waterline agreement.
4. Before/after captures for the full visual matrix, including an LOD debug capture and normal non-debug gameplay captures. State what you observed and what you changed after each failed visual pass.
5. Profiler p50/p95 results for High and at least one lower tier, with actual device/emulation conditions.
6. A list of all water/foam/spray texture asset IDs and confirmation that they load in the published experience with the correct permissions.
7. A final explicit checklist confirming:
   - no client startup error;
   - no visible seams, cracks, skirts, square bands, or recenter pops;
   - no hard horizon edge from allowed gameplay cameras;
   - UV/detail does not follow the camera;
   - Trade/Gale/Mythic have visibly distinct, readable wave silhouettes;
   - connected crest foam and grounded wakes are visibly present;
   - no placeholder sparkles remain;
   - boat/render waterline agreement passes tolerance;
   - performance gates pass.

Prioritize in this exact order: startup gate, watertight clipmap/horizon, world-locked verified material, spectrum shape, foam signal, layered foam/wakes, waterline regression, performance polish. Do not spend time tweaking color or particle counts while the startup and geometry gates are failing.
