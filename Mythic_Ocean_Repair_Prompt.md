# Mythic ocean repair prompt for GPT-5.6 Luna Max

You are GPT-5.6 Luna Max operating Roblox Studio through the Roblox Studio MCP. Repair and substantially upgrade the existing ocean implementation in the currently open Mythic place. This is an implementation, playtesting, profiling, and visual-polish task — not another planning task.

The player-facing failure is clear: the ocean currently looks poor and exhibits strange visual effects; the waves are hard to read; convincing foam and whitecaps are absent; and the boat can visibly pass into or sit too far inside the rendered water. A technically running system that still looks bad is a failed result.

Use the existing system as a foundation where it is sound, but replace prototype-only visual layers when necessary. Preserve all unrelated game systems and art. Make changes through the Studio MCP, run playtests, inspect Output, take comparison captures, profile the result, and iterate until every P0 exit gate below passes. Do not merely return suggested code.

## Audited baseline

The source audit was performed against public commit [`8bed88c78485f3ee4cc9480983e64343c621393a`](https://github.com/ng643/Mythic/commit/8bed88c78485f3ee4cc9480983e64343c621393a). First compare the open Studio place with that commit; if Studio contains newer code, preserve the newer work and apply the same fixes to the actual source of truth.

The following are source-backed defects, not guesses. Verify them in the place, then fix them.

| Priority | Defect | Evidence and expected symptom |
| --- | --- | --- |
| P0 | The spectrum has a unit-conversion error. | [`SpectrumGenerator.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/ReplicatedStorage/Ocean/Shared/SpectrumGenerator.luau#L44-L105) multiplies a period in seconds by `MetersToStuds` before squaring it. `WaveGravity` is already in studs/s², so this applies the length conversion twice. For Trade Sea, the intended 8.5-second peak is about 402.9 studs, but the code calculates about 5,139.3 studs and then clamps every wind component to 720 studs. Calm, Trade, Gale, and Mythic Storm therefore each get ten identical 720-stud wind wavelengths. The 11-second Trade swell should be about 674.8 studs but becomes about 8,607 studs. This destroys useful spectral variety and makes the surface read as a slow, vague sheet instead of waves. |
| P0 | The visible surface and boat physics do not sample the same wave set. | The near renderer hard-codes `componentCap = 14` in [`OceanRenderer.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/StarterPlayer/StarterPlayerScripts/OceanClient/OceanRenderer.luau#L131-L149), while [`BuoyancyService.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/ServerScriptService/OceanServer/BuoyancyService.luau#L45-L78) samples only the first ten. The generator appends the two swell components after the first ten wind components. The boat therefore ignores both rendered swells, which can put the visible crest several studs above the surface supporting the hull. |
| P0 | The production clipmap is deliberately disabled. | [`OceanClientMain.client.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/StarterPlayer/StarterPlayerScripts/OceanClient/OceanClientMain.client.luau#L52-L84) sets `OceanExperimentalClipmaps` to `false`; [`OceanRenderer.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/StarterPlayer/StarterPlayerScripts/OceanClient/OceanRenderer.luau#L206-L233) consequently builds only one 192×192-stud High patch. The “far plane” is then positioned 16 studs below sea level. This creates a small animated tile over a visibly discontinuous flat plane instead of an ocean extending naturally to the horizon. |
| P0 | The water has no production water material. | [`OceanRenderer.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/StarterPlayer/StarterPlayerScripts/OceanClient/OceanRenderer.luau#L16-L28) uses plain `SmoothPlastic`, a flat color, `Reflectance`, and slight transparency. [`WaterMaterialController.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/StarterPlayer/StarterPlayerScripts/OceanClient/WaterMaterialController.luau#L13-L31) maps the preset’s `roughness` value to `Reflectance`; it does not use PBR roughness. The mesh creates no UVs and the repository wires no `SurfaceAppearance`, normal map, roughness map, or foam-compatible color data. Macro geometry alone cannot provide convincing small-scale highlights. |
| P0 | Foam, spray, and wakes are visible prototypes, and are likely the reported “weird effects.” | [`FoamController.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/StarterPlayer/StarterPlayerScripts/OceanClient/FoamController.luau#L18-L77) teleports up to 24 untextured Neon rectangular Parts around a coarse grid; they are not aligned to the sampled surface normal and all candidate selection changes in time buckets. [`SprayController.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/StarterPlayer/StarterPlayerScripts/OceanClient/SprayController.luau#L18-L81) teleports Neon balls rather than simulating spray. [`WakeController.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/StarterPlayer/StarterPlayerScripts/OceanClient/WakeController.luau#L13-L75) rigidly attaches two Neon bars to the hull without sampling the ocean. These objects pop, intersect waves, and look synthetic rather than foamy. |
| P0 | Buoyancy-point discovery is unsafe. | [`ShipRegistry.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/ServerScriptService/OceanServer/ShipRegistry.luau#L46-L75) treats almost every Attachment anywhere in the ship as a buoyancy point, rather than selecting an explicit buoyancy schema. Seat, constraint, wake, weapon, and cosmetic attachments can therefore receive water forces. |
| P1 | Player vessels are forced to server ownership. | [`ShipRegistry.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/ServerScriptService/OceanServer/ShipRegistry.luau#L67-L75) calls `SetNetworkOwner(nil)` for every ship part. On a player-controlled vessel, replicated pose latency can make the client-rendered present-time wave move ahead of the delayed server-owned hull and can also make steering feel poor. Roblox warns that forcing server ownership can make physics interactions jittery, while client ownership needs server validation. Choose and test an explicit policy. |
| P1 | A second weather transition can jump back to a stale wave bank. | [`OceanStateService.luau`](https://github.com/ng643/Mythic/blob/8bed88c78485f3ee4cc9480983e64343c621393a/src/ServerScriptService/OceanServer/OceanStateService.luau#L49-L70) writes a new `bankB`, but no code commits a completed `bankB` to `bankA`. The next transition begins from the original stale `bankA`. Material/weather values also change immediately instead of cross-fading with the wave bank. |
| P1 | Quality settings are not actually honored. | Ring wave count is hard-coded to 14, foam is hard-coded to 24, and spray to 16. The adaptive controller compares an ocean-script execution time called `lastFrameMs` against whole-frame thresholds, so it does not measure the frame time it claims to control. A quality rebuild can also create new water parts after the material controller has run, leaving them with default material values. |

## Non-negotiable architecture

Retain one deterministic shared `WaveField` as the only definition of the water surface. Rendering, active player-boat buoyancy, camera submersion, swimming, foam placement, and wake placement must evaluate the same state, absolute synchronized time, world XZ coordinates, active components, bank blend, and gameplay disturbances. A cosmetic outer LOD may omit short waves, but anything interacting with the player must agree with the LOD0 surface.

Use only supported Roblox features. Current official references include [`EditableMesh`](https://create.roblox.com/docs/reference/engine/classes/EditableMesh), [`AssetService`](https://create.roblox.com/docs/reference/engine/classes/AssetService), [PBR `SurfaceAppearance`](https://create.roblox.com/docs/art/modeling/surface-appearance), [`RunService.PreSimulation`](https://create.roblox.com/docs/reference/engine/classes/RunService/PreSimulation), [network ownership](https://create.roblox.com/docs/physics/network-ownership), [`ParticleEmitter`](https://create.roblox.com/docs/reference/engine/classes/ParticleEmitter), [`Beam`](https://create.roblox.com/docs/reference/engine/classes/Beam), [`Trail`](https://create.roblox.com/docs/reference/engine/classes/Trail), and the [MicroProfiler](https://create.roblox.com/docs/performance-optimization/microprofiler). If an API, asset permission, alpha mode, batch method, or EditableImage-to-material path is uncertain, test it in the capability lab before relying on it.

Do not use an unowned Creator Store ocean, an unverified custom shader feature, per-frame vertex replication, or a hidden flat Terrain-water surface that conflicts with the custom mesh.

## Required implementation sequence

### Phase 0 — Reproduce and isolate before editing

1. Inspect the current DataModel and source scripts. Preserve unrelated instances.
2. Start a client/server playtest in the current default sea. Record:
   - Output warnings/errors;
   - whether `OceanFallback` is active;
   - ring, vertex, and triangle counts;
   - current ocean quality and frame/update time attributes;
   - the ship’s network owner and exact buoyancy point list;
   - screenshots from boat-deck, low waterline, elevated, and horizon views.
3. Add a temporary debug toggle that can independently hide base water, far water, foam, spray, and wakes. Toggle one layer at a time to identify every artifact. Do not leave debug visuals enabled by default.
4. Capture the same position in Trade Sea and Gale. This is the before baseline.

### Phase 1 — Correct wave units and make sampling coherent

Fix this before tuning visuals or boat height.

1. Correct the deep-water dispersion conversion. Either of these equivalent forms is valid:

   ```text
   gStuds = 9.81 * studsPerMeter
   wavelengthStuds = gStuds * periodSeconds^2 / (2*pi)
   ```

   or:

   ```text
   wavelengthMeters = 9.81 * periodSeconds^2 / (2*pi)
   wavelengthStuds = wavelengthMeters * studsPerMeter
   ```

   Convert length exactly once. Never multiply `periodSeconds` by `MetersToStuds`. Then compute `k = 2*pi/wavelengthStuds` and `omega = sqrt(gStuds*k)`.
2. Replace the crude wavelength clamp with a documented, preset-aware safe range that supports the rendered extent. Avoid generating repeated components at a clamp boundary: merge, discard, or resample duplicates. A production bank needs several distinct long, medium, and short wavelengths with coherent wind direction, not random noise and not ten copies of one wavelength.
3. Log a concise spectrum summary in Studio debug mode: wavelength min/median/max, reconstructed period range, total variance, significant height, and aggregate steepness.
4. Make component selection semantic or energy-sorted instead of “first N.” Long swell must never disappear merely because it was appended last. For the active player ship and LOD0, prefer the full production bank; 12–14 inexpensive analytic components are acceptable if profiling passes. Distant NPCs may use a measured subset that preserves dominant swell and mean height.
5. Introduce one canonical gameplay sampler, for example `SampleForGameplayWorldXZ`, and use it for active-ship buoyancy, waterline debug, swimming, and camera submersion. It must use the same bank blend and gameplay disturbances as LOD0 rendering.
6. Repair bank lifecycle. On completion, atomically promote the destination bank and visual state to the new current state, then prepare a clean next transition. Cross-fade tint, real roughness/material selection, foam threshold, wind, atmosphere, and other weather presentation over the same transition rather than snapping them at its start.
7. Expand `OceanMathTests` and actually run it in Studio. Tests must cover:
   - Trade peak wavelength ≈402.9 studs for 8.5 seconds and Trade swell ≈674.8 studs for 11 seconds, within a small numeric tolerance;
   - at least six materially distinct wavelengths in ordinary presets and no accidental clamp pile-up;
   - reconstructed periods matching source periods;
   - deterministic finite position, height, normal, velocity, Jacobian, and foam;
   - inverse residual within the established tolerance;
   - two consecutive preset transitions with no snap to stale data;
   - render/gameplay surface agreement at at least 100 positions across several times and presets.

**Phase 1 exit gate:** at identical world XZ and synchronized time, the LOD0 height used to draw water and the height used for the active boat differ by no more than 0.05 stud; their normals differ by no more than 1 degree. All automated tests pass. Do not compensate with a boat Y offset.

### Phase 2 — Replace the small floating tile with a real ocean

1. Do not leave production clipmaps permanently behind an attribute set to false. Use the capability result to enable them by default on supported devices, with a clean automatic fallback if allocation or mutation fails.
2. Implement a full inner grid plus nested donut rings. High should begin around 49×49 vertices, 4-stud LOD0 spacing, and enough successively coarser rings to fill the ship camera’s view to the atmospheric horizon. Tune from measurements rather than preserving the arbitrary `maxExtent = 1900` cap.
3. Make ring boundaries watertight:
   - shared long-wave samples land on the same world coordinates;
   - short components fade over a measured morph band before they become under-sampled;
   - add stitch triangles and/or connected downward skirts;
   - remove coplanar one-cell overlap that produces z-fighting;
   - keep waves world-locked while camera-centred topology snaps.
4. Replace the far plane discontinuity. It must not sit 16 studs below the outer edge. Morph the outer wave amplitude toward the mean sea level and horizon tint, then meet a sufficiently large horizon surface at the same elevation without a visible ledge, gap, or double surface. The final boundary must be hidden naturally by atmosphere at all supported camera pitches and ship speeds.
5. Make deep water opaque or nearly opaque. Start at transparency 0–0.03 and only add a slightly more transparent near treatment if screenshots prove it creates no sorting, under-plane, hull, or ring artifacts. Do not stack visible transparent surfaces.
6. Use data-derived vertical bounds and connected skirt geometry, not only two unreferenced vertices. Keep outer rings single-sided unless an underwater test demonstrates that a specific near ring must be double-sided.
7. Honor each quality profile’s ring count, spacing, update cadence, wave budget, normal-ring count, and VFX caps. Filter by wavelength/energy, not array position.

**Phase 2 exit gate:** during calm and maximum supported storm, walking/sailing across snap boundaries at maximum expected speed plus 25% produces no crack, z-fighting, step, tile edge, phase swim, or horizon hole. Capture deck, waterline, elevated, and downward-looking proof.

### Phase 3 — Build a production water appearance

The current flat `SmoothPlastic + Reflectance` treatment is a prototype. Replace it.

1. Create or wire an experience-owned, seamless PBR water appearance under `ReplicatedStorage/Ocean/Assets/WaterAppearances`:
   - subtle tintable albedo/color map;
   - a tileable tangent-space normal map with broad and fine ripple detail baked into the texture;
   - a real roughness map or validated preset variants;
   - a black/zero metalness map because water is dielectric;
   - clean UVs on every editable ring with consistent world scale and no seams.
2. Use `SurfaceAppearance` rather than pretending that `BasePart.Reflectance` is roughness. Keep `Reflectance` at zero or a measured neutral value. Tint `SurfaceAppearance.Color`/the supported material path from the ocean state.
3. If no owned texture assets exist, create a deterministic tileable placeholder through a currently supported Studio/EditableImage workflow, validate it in a published-client test, and make replacement asset slots explicit. Do not pull an arbitrary Creator Store asset. Do not declare the appearance final if the placeholder still looks procedural or low quality.
4. If animated micro-ripples are added by updating UVs, do so at a low measured cadence and keep them wind-directed. Never regenerate a full image every frame. The macro Gerstner motion must remain dominant and readable.
5. Preserve the game’s existing lighting unless it is only a blank default. Ensure an appropriate sky/environment, nonzero environment specular contribution, restrained bloom/exposure, and Atmosphere that blends the horizon. Test noon, sunset, moonlight, and overcast; do not tune only one angle.
6. Art direction target: epic stylized realism suitable for an Odyssey-inspired dangerous sea — long coherent swells, sharper wind-driven crests, readable travel direction, deep blue-green body color, bright grazing highlights, and progressively desaturated/hazy distance. Avoid a plastic mirror, uniform blue floor, noisy jelly sheet, or tiled normal-map look.

**Phase 3 exit gate:** macro waves are plainly readable from the deck and at 100–300 studs even before foam is enabled; close water also has convincing small highlights. There is no UV seam, texture swimming, excessive mirror reflection, or lighting angle at which the ocean becomes a featureless blue plane.

### Phase 4 — Replace prototype foam, spray, and wakes

Delete or disable the existing untextured Neon rectangles, bars, and teleporting balls after their replacements pass. Do not simply increase their count.

1. Implement three coordinated crest layers, all driven by the shared analytic foam signal:
   - a near-surface crest tint/lightening path, using editable vertex color only if the capability test proves it works with the chosen `SurfaceAppearance`;
   - pooled, alpha-textured crest ribbons/cards with 3–5 visual variants;
   - sparse `ParticleEmitter` mist/spray on only the strongest storm crests.
2. Foam objects need persistent lives rather than being teleported each update. Spawn, advect with sampled surface/wind velocity, expand slightly, and fade over roughly 0.8–2.5 seconds. Use stable seeded candidate cells and temporal hysteresis so a time-bucket change does not pop the whole field.
3. Align each crest ribbon to the analytic surface normal and the crest tangent. Offset it enough to prevent z-fighting while keeping it attached to the moving crest. Use alpha breakup, curved/irregular silhouettes, size variation, and restrained brightness; ordinary sea foam is not self-luminous Neon.
4. Tune preset response deliberately:
   - Glass Harbour: essentially no whitecaps;
   - Calm Open Sea: rare small streaks;
   - Trade Sea: clearly visible intermittent crest foam;
   - Gale: frequent directional whitecaps and wind-blown spray;
   - Mythic Storm: broad breaking crests and dramatic but bounded spray.
5. Rebuild ship wakes as moving-surface effects:
   - sample wave height and normal under bow/stern emitters every update;
   - use owned alpha-textured Trails, Beams, pooled ribbons, and/or particles instead of rigid Neon bars;
   - leave a decaying history behind the ship rather than attaching a solid rectangle to the hull;
   - scale V-shape width, turbulence, bow spray, and lifetime from forward speed, hull beam, and turn rate;
   - keep wake emitters on the visible surface through wave crests and troughs.
6. Couple foam, spray, and wake caps to quality tiers. Pool all transient objects; no per-frame creation/destruction and no unbounded history.
7. If the current place already has islands, add a small authored shoreline-foam proof around one representative coast using attachments/splines or another bounded authored method. Do not do thousands of runtime terrain raycasts. If no coast exists yet, provide the interface and defer shoreline authoring explicitly.

**Phase 4 exit gate:** no `CrestCard`, `OceanSpray`, or `WakeTrail` appears as a plain geometric Neon block. Foam remains stable while the camera moves, adheres to crests, increases convincingly by sea state, and has no mass synchronized popping. Wakes remain on the water and visibly decay behind a moving/turning boat.

### Phase 5 — Stabilize the boat at the actual visible waterline

1. Migrate every ship to an explicit buoyancy-point schema. Use a tag, a strict name prefix plus attribute, or `OceanBuoyancyPoint = true`; do not collect unrelated Attachments. Validate that each point belongs to the hull assembly.
2. Use 8–16 points distributed around bow/stern, port/starboard, and the effective hull footprint. Give each point explicit weight, target submersion, effective draft, force cap, and optional role. Validate finite values, normalize weights to sum to one, and warn once on invalid setup.
3. Add an optional Studio-only buoyancy visualizer showing point positions, the exact sampled visible surface, depth, force vector, point role/weight, render-versus-physics height error, assembly centre of mass, and configured target waterline. This must be disabled in production.
4. Run active player-boat forces at `RunService.PreSimulation` with the canonical gameplay sample. Keep the hydrostatic spring non-tensile and bound damping/drag so a water point cannot become an unstable actuator that pulls the hull deep below the surface. Clamp hitch-sized time steps and point forces, but do not flatten the ocean to hide instability.
5. Tune around an explicit hull `Waterline` marker, not the model origin. The target is credible draft: some hull is supposed to be underwater, but the rendered surface must not pass arbitrarily through the upper hull or deck because physics sampled another wave.
6. Choose network ownership explicitly:
   - player-driven cooperative ship: prefer driver ownership for responsiveness, run the matching deterministic controller for that owner, and add server checks for position delta, speed, acceleration, angular speed, sea-state force envelope, collisions, and ownership changes;
   - NPC/distant ship: server ownership is appropriate;
   - if a gameplay-critical player ship must remain server-owned, test 100 ms and 250 ms simulated latency and compensate presentation coherently rather than letting present-time water overtake a delayed hull.
7. Keep damage, inventory, loot, and capsize outcomes server-authoritative regardless of physics ownership. Never trust a client-reported hit or treasure state.
8. Add recovery for NaN/out-of-envelope motion and test added cargo mass. Do not snap orientation every frame.

**Phase 5 exit gate:**

- In calm water, the test boat settles to its configured waterline without growing heave, pitch, or roll oscillation.
- At every buoyancy point, the compared visual/gameplay water heights stay within 0.05 stud.
- Trade and Gale waves lift and rotate the hull at the crest actually shown to the player.
- The deck does not submerge in normal Trade/Gale operation except during a deliberately authored breaking/rogue wave, capsize, or overload condition.
- A 100–250 ms hitch cannot launch or tunnel the ship, and the selected 250 ms network test remains playable.

### Phase 6 — Performance and adaptive quality

1. Use the capability lab to benchmark the current `EditableMesh.BatchSetValues` path against singular `SetPosition`/`SetNormal`, then use the measured winner. Do not leave `batchAvailable` hard-coded false without evidence.
2. Add balanced `debug.profilebegin()`/`debug.profileend()` labels for `Ocean/WaveEvaluate`, `Ocean/VertexCommit`, `Ocean/Normals`, `Ocean/Foam`, `Ocean/Wakes`, `Ocean/Underwater`, and `Ocean/Buoyancy`.
3. Measure actual render-frame time (`dt`) separately from ocean CPU cost. Feed actual frame time plus hysteresis into adaptive quality; do not compare a subtask duration to whole-frame thresholds.
4. Starting warm-state budgets:
   - complete ocean client CPU ≤1.5 ms typical High desktop and ≤2.5 ms constrained mobile;
   - vertex commit ≤1.0 ms typical;
   - foam/wake CPU ≤0.5 ms;
   - server ocean/boat work ≤2.0 ms per frame for the expected active ship count;
   - zero steady per-frame ocean-state remote traffic;
   - no sustained instance or memory growth after pools warm up.
5. Degrade in this order: spray/foam count, outer-ring cadence, outer range with stronger horizon blend, distant normal updates, distant wave components, near resolution, then fallback. Keep active-boat sampling correct even when visuals downgrade.
6. Run at least a ten-minute storm soak and check Instances, connections, VFX pools, events, client/server memory, and MicroProfiler spikes.

## Mandatory visual comparison matrix

Capture the same camera transforms before and after at:

| Sea state | Lighting | Views |
| --- | --- | --- |
| Calm Open Sea | Noon and sunset | deck, waterline, elevated, horizon |
| Trade Sea | Noon and moonlight | deck, broadside boat/waterline, moving wake |
| Gale | Overcast/day and moonlight | deck, waterline, horizon, turning boat |
| Mythic Storm | Overcast/day | approaching crest, crest impact, post-impact foam |

Also capture one frame with the debug wireframe/ring boundaries, one with buoyancy sample visualization, and one with all debug overlays disabled. Compare the actual images. If the result still reads as a small animated tile, plastic plane, random noise, obvious rectangles, or a boat being cut through by an unrelated surface, continue iterating.

## Forbidden symptom patches

- Do not lift the whole boat, lower sea level, reduce every wave amplitude, or hide water inside the hull to conceal sampler disagreement.
- Do not stack more transparent planes or more untextured Neon Parts.
- Do not switch the production ocean to flat Terrain water merely because the custom path needs repair; Terrain may remain a tested fallback.
- Do not add random high-frequency sine waves until the corrected physical spectrum and PBR normal detail have been evaluated.
- Do not make the surface visually noisy to prove that waves exist. Directional coherence and silhouette readability matter more than raw component count.
- Do not use an unowned marketplace dependency or assume asset permissions.
- Do not delete or replace unrelated scene content, lighting, controls, or boat systems without a direct conflict and an explanation.
- Do not declare completion from a clean Output window alone.

## Completion report

Only finish after every P0 gate passes. Provide:

1. the root causes confirmed in Studio;
2. every changed script and important created/changed Instance;
3. automated test results, including numeric spectrum and render-versus-physics agreement;
4. before/after screenshot matrix;
5. selected network-ownership policy and 250 ms test result;
6. MicroProfiler median and worst observed ocean costs for client and server;
7. ten-minute soak results and final instance/pool counts;
8. fallback behavior and how to force it for testing;
9. remaining limitations or asset-replacement work, stated plainly.

Save the corrected place and the mapped source. The final result must look intentionally art-directed and epic while keeping the exact visible surface authoritative for the boat.
