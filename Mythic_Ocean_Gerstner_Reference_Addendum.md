# Mythic Ocean — Gerstner Reference Addendum

Pass this prompt to the coding agent **after** the existing comprehensive ocean recovery prompt. This addendum changes the visual direction based on a forensic review of the attached place in the Roblox DevForum resource **“Gerstner Wave Module”**. It does not replace the earlier requirements for authoritative buoyancy, stable seating, swimming, profiling, fallbacks, or tests.

## Mission

The current Mythic ocean is over-engineered in the wrong places: it spends a large CPU budget on many wave components and multiple visible clipmap levels, yet its silhouette, material response, crest readability, distance transition, foam, and stability remain worse than the much simpler reference demo.

Rework the implementation so it captures the reference’s strongest qualities:

- large, coherent, clearly readable Gerstner crests;
- strong trough-to-crest color separation;
- moving sky/specular highlights that make the geometry legible;
- a continuous local surface without an obvious nearby LOD boundary;
- a camera-centered mesh that is reused instead of rebuilt;
- a small, art-directed physical wave set shared by rendering, buoyancy, swimming, and surface queries;
- a cheap, dependable, attractive no-texture baseline.

Do **not** copy the sample blindly. It is a 2024 beta-era demonstration, not a production multiplayer ocean. Reimplement the useful ideas with current Roblox APIs and preserve the physical architecture and safety requirements from the earlier recovery prompt.

## Ground truth from the reference place

I inspected the `WavesGerstner.rbxl` attachment, not just the showcase video.

### Surface topology and movement

The demo creates one regular EditableMesh grid:

- 50 × 50 vertices: 2,500 vertices total;
- 8-stud vertex spacing;
- approximately 392 × 392 studs of continuous surface;
- 4,802 triangles;
- the MeshPart is recentered to the camera/player on an 8-stud snap grid;
- waves are evaluated from the vertex’s **absolute world XZ position**, so recentering the finite mesh does not reset or slide the wave phase.

That single uninterrupted local patch is a major reason the demo reads better than Mythic’s nearby multi-ring clipmap. It has no LOD boundary cutting through the most visible 200-ish studs around the camera.

### Wave recipe

The showcase uses only two Gerstner components, approximately:

| Component | Direction in sample | Wavelength | Steepness parameter | Resulting amplitude |
|---|---:|---:|---:|---:|
| A | diagonal (`Vector2.one`) | 97.5 studs | 0.30 | about 4.66 studs |
| B | +Z | 93.75 studs | 0.20 | about 2.98 studs |

Its basic deep-water Gerstner relationships are:

\[
k = \frac{2\pi}{\lambda}, \qquad \omega = \sqrt{gk}, \qquad A = \frac{q}{k}
\]

and it applies horizontal displacement with cosine and vertical displacement with sine. The combination produces tall, broad, directional crests with roughly 0.5 aggregate steepness. The first direction is not normalized in the old source; that is a bug/accidental art choice, not something to reproduce. Normalize every direction and tune amplitudes/steepness intentionally.

The important lesson is **not** “two waves are always physically correct.” It is that a few coherent macro waves create a far stronger silhouette than fourteen similar-cost components whose visual contribution becomes noisy or indistinct.

### Why the material looks dramatic

The sample’s bright crest ribbons are not a foam simulation. They mainly come from four combined effects:

1. Gerstner horizontal displacement sharpens crests and widens troughs.
2. Every vertex is recolored from dark teal in troughs toward pale blue at crests according to displacement height.
3. The MeshPart uses Roblox `Glass`, with strong environment specular response.
4. Bright sky lighting and restrained bloom turn grazing-angle reflections into moving white highlights.

The sample also uses an old blue checker/grid texture. That grid makes curvature extremely easy to see in a technical demo, but it is not attractive production water. Treat a grid/checker as an optional geometry-debug view only. Do not use the attached texture asset in Mythic: it is an old third-party asset and is not marked public-domain.

### What is obsolete or misleading

Do not copy these parts:

- It constructs `EditableMesh` with an old beta API.
- It calls the old vertex-color method that users report is now deprecated.
- Its UV call passes a vertex identifier where the current API expects a UV attribute identifier, producing the reported “Expected UV, received Position” failure.
- It rewrites unchanged UVs and colors for every vertex every loop.
- It drives updates with an unrestricted `task.wait()` loop and uses `tick()`.
- Its showcase boat is locally cloned, anchored, and moved kinematically with `PivotTo` from five height samples. It is not physical buoyancy, does not validate Seat occupants or network ownership, and does not demonstrate multiplayer stability.
- The finite patch and atmosphere hide its edge only tolerably; it is not a complete horizon solution.
- There is no actual crest-foam field, wake system, swimming system, shore interaction, or robust LOD system.

## Required architectural pivot

### 1. Build an A/B reference harness before changing production

Extend `tools/OceanCapabilityLab.client.luau` or add an equivalent Studio-only comparison mode. It must switch instantly among:

- **Reference Geometry:** one 50 × 50, 8-stud grid with two normalized waves close to the values above, Glass, height coloring, and an optional procedural/debug grid;
- **Candidate Production:** the proposed Mythic macro spectrum, final material, foam, and horizon transition;
- **Current Main:** the current implementation for before/after comparison.

All three views must use the same camera, Lighting, ocean time, wind direction, and quality target. Add toggles for normals, wireframe/grid, LOD boundaries, crest mask, compression/Jacobian mask, and material candidate. Capture noon, low-sun, storm, top-down, waterline, and boat-deck views before choosing settings.

Do not ship the exact reference mode. It is a measurable visual target and diagnostic control.

### 2. Replace “many geometry waves” with an art-directed macro spectrum

Refactor `SpectrumGenerator.luau`, `WaveField.luau`, `WaveMath.luau`, presets, renderer caps, and server consumers so the primary physical surface normally uses **four to six** carefully separated Gerstner components, not fourteen CPU-deformed components.

Use roles rather than many randomized near-duplicates:

- one dominant swell with the longest wavelength;
- one secondary swell at a modest direction/phase offset;
- two dominant wind-sea components around the peak wavelength;
- optionally one cross-sea component for rough/storm presets;
- optionally one shorter crest-shaping component, only when the mesh spacing can represent it;
- rogue/storm event displacement remains a separate, bounded addition.

Requirements:

- Keep one deterministic, server-time-based field shared by visuals, buoyancy, swimming, wakes, and gameplay queries.
- Preserve each preset’s significant-wave-height target after reducing component count; write tests for the reconstructed variance/Hs.
- Normalize all directions.
- Keep the horizontal Gerstner mapping safely non-folding. Track the minimum Jacobian and clamp or renormalize before it approaches zero.
- Start production tuning around aggregate steepness ranges of roughly 0.20–0.28 calm, 0.32–0.42 trade sea, 0.40–0.50 rough, and 0.48–0.58 storm. These are art targets, not permission to violate the Jacobian safety margin.
- Ensure at least two visibly dominant wavelengths are in the approximate 70–140 stud range for ordinary/open-sea presets, then scale sensibly with the configured period and sea state.
- Put sub-geometry ripples into a subtle, validated normal/roughness material. Do not make boats react to invisible high-frequency waves.
- Expose a small set of meaningful tuning values: dominant wavelength, Hs, directional spread, aggregate steepness/choppiness, crest sharpness, wind direction, and storm cross-sea amount.

The test for success is visual: from a ship deck, a player must be able to point at and follow individual crests moving through the scene. The water must not look like a softly wobbling sheet or high-frequency noise.

### 3. Use one continuous high-quality near patch

Replace the six visibly nested moving rings near the camera with a simpler topology:

- one continuous camera-centered high-detail patch covering at least roughly 350–450 studs across at High quality;
- at most one or two lower-cost transition regions outside it;
- static or very-low-cadence horizon geometry beyond the wave-visible range.

Suggested starting profiles, to be validated in the profiler:

| Quality | Near-grid starting point | Physical components | Near update target |
|---|---:|---:|---:|
| Ultra | 65 × 65 at 6 studs | up to 6 | 60 Hz if budget permits |
| High | 49 × 49 at 8 studs | up to 6 | 60 Hz |
| Medium | 41 × 41 at 10 studs | up to 5 | 30–40 Hz with interpolation if needed |
| Low | 33 × 33 at 12 studs | up to 4 | 24–30 Hz with interpolation |

These are starting points, not hard-coded truth. Prefer fewer vertices and coherent wavelengths over dense geometry that cannot be afforded.

Anchor rules:

- Reuse meshes. Never rebuild because the camera crossed a cell.
- Snap the patch origin to its vertex spacing.
- Evaluate the wave phase in absolute world coordinates.
- Apply the MeshPart translation and corresponding world-sample origin atomically in one update.
- Do not reset time, phase, or accumulated state when rebasing.
- Add a travel soak that crosses thousands of snap cells without a pop, phase jump, UV jump, or mesh corruption.

For the outer transition, the final row of the near mesh and first row of the far mesh must share the same world positions for shared long waves. Fade only residual short-wave displacement over a wide band, with a smooth curve, and blend normals/colors over the same band. Do not expose the current hard “level of distance” square/ring. Use atmosphere and water-compatible horizon color to conceal the last flat transition, but do not rely on fog to hide a discontinuity that is visible in clear weather.

### 4. Rebuild the color and normal attribute path with current APIs

At mesh construction time:

- Create vertex-position IDs normally.
- Create and retain the required normal IDs, then assign them to face corners with `SetFaceNormals`.
- Create and retain color IDs, then assign them with `SetFaceColors`.
- Create and assign UV IDs once with `AddUV` and `SetFaceUVs` only if the selected material path actually consumes mesh UVs.
- Use unique/reused attribute IDs deliberately so shared vertices shade smoothly; do not accidentally give every triangle an unrelated flat color or normal.

At runtime:

- Batch position values with `BatchSetValues` when supported.
- Batch analytic normal values rather than deriving normals through neighbor sampling.
- Batch color values with the corresponding Color3 attribute IDs.
- Never call the obsolete vertex-color API.
- Never pass a position/vertex ID to `SetUV`.
- Do not rewrite UVs every frame. If UVs must remain world-locked, either snap rebases to the exact texture period or update only on an actual origin rebase using the correct UV IDs. Prefer a MaterialVariant with stud-space tiling when it gives the required result.

Implement an art-directed three-stop water ramp, with preset overrides:

- deep trough: dark, saturated teal/navy;
- mid water: readable ocean blue/teal;
- crest: lighter cyan/blue-green.

Drive it from normalized displacement height plus a smaller slope/compression contribution. Keep ordinary geometric crest color blue/cyan; reserve near-white for genuine foam and very strong reflected light. Start with colors near `RGB(8,44,58)`, `RGB(17,84,101)`, and `RGB(82,154,168)`, then tune by capture rather than treating those values as final.

Color need not update at 60 Hz. Test 10–20 Hz color commits while positions/normals remain smooth. Quantize or skip a color commit when the buffer has not changed perceptibly.

### 5. Run a real material shootout; establish a beautiful asset-free fallback

The current unvalidated/fallback texture path is unacceptable. Make these candidates selectable in the comparison harness:

1. `Glass` with no MaterialVariant and no external texture — the mandatory reliable baseline;
2. a MaterialVariant whose `BaseMaterial` is `Glass`, with neutral/no albedo, a subtle licensed normal map, black metalness, and tuned roughness;
3. the current SmoothPlastic/PBR direction after its maps and bindings are actually validated.

Choose from captured results and profiling, not assumptions. The winning path must satisfy all of these:

- no checkerboard, placeholder, missing-asset, or fallback texture in normal play;
- no visible 10-stud repetitive tiling from ship-deck height;
- specular highlights follow the analytic normals and make crests readable;
- trough color remains deep without becoming opaque black;
- the waterline is readable at noon, sunset, and storm lighting;
- no uncontrolled transparency-sorting artifacts;
- the material remains attractive before any optional texture finishes loading.

If a custom texture is unavailable or fails to load, stay on the Glass + vertex-color baseline and report the degraded status through existing runtime attributes. Never swap to a random public Roblox asset. Do not reuse texture ID `200944002` from the sample.

For the intended ocean lighting target, test `EnvironmentSpecularScale = 1`, a sky with useful bright reflection structure, atmosphere that supports the horizon, soft shadows, and restrained bloom. Integrate this with the game’s art direction; do not silently overwrite unrelated global Lighting settings every frame. If Mythic owns Lighting, configure it once. Otherwise expose recommended settings and apply only ocean-local material values.

### 6. Add real foam instead of mistaking highlights for foam

Keep the reference’s reflective crest ribbons, but implement white foam as a separate signal. Use the existing analytic data and current pooled VFX architecture:

- seed foam from low Jacobian/high horizontal compression, sufficient slope, crest height, and upward/forward motion;
- hysteresis and persistence so foam grows and decays rather than flashing every frame;
- advect or re-sample persistent foam in world space so it does not stick to the camera-centered mesh;
- use sparse pooled crest patches/sheets or particles close to the camera, not one object per vertex;
- blend ship wakes into the same visual language;
- impose strict per-quality caps and distance culling;
- ensure foam remains sparse in calm water and forms intermittent streaks/crest caps in storms.

Use the height-color ramp to reveal non-breaking crests. Do not color every crest white, which would look like snow and erase the distinction between light reflection and breaking water.

### 7. Do not adopt the demo’s boat logic

The attached place’s anchored `PivotTo` boat is only a visual prop. Preserve and finish the earlier prompt’s server-authoritative, force/torque-based buoyancy solution:

- stable multi-point hydrostatic forces and damping;
- forces applied at physically meaningful points;
- capped angular response and anti-windup;
- explicit network-ownership policy;
- Seat occupant mass/center-of-mass changes handled without double-applying character mass;
- no per-frame hull teleportation;
- the same macro WaveField queried by the renderer;
- swimming has one controller/owner and must not fight Humanoid physics.

Reducing the physical spectrum to coherent macro components should make buoyancy cheaper and less twitchy, but it does not remove the need for the existing seating, ownership, and swim tests.

## Performance implementation requirements

- Profile before and after with MicroProfiler labels for wave evaluation, positions, normals, colors, UV rebases, foam, and EditableMesh commits.
- Preallocate and reuse ID arrays and Vector3/Color3 value buffers. No per-vertex tables, closures, tasks, or temporary objects in the hot loop.
- Update visual geometry once per rendered frame at most; physics stays on the fixed/server simulation cadence defined in the main recovery prompt.
- Consider sine/cosine recurrence across the regular grid for each fixed component so one row/column does not perform two fresh transcendental calls per vertex. Add numerical-drift tests and periodically reseed if used.
- Far regions update at a lower cadence and use only the longest components.
- Only investigate Parallel Luau after the simpler spectrum/topology/batching work is measured. If used, Actors compute pure numeric buffers; commit EditableMesh mutations only in a context/API path proven safe. Do not add worker complexity without profiler evidence.
- If `BatchSetValues` is unavailable/fails, use a tested per-attribute fallback without disabling both position and normal batches because one attribute type failed. Track capability independently.

Target High quality to keep total ocean client work comfortably below the frame budget, with a practical initial target of under 4 ms average and under 6 ms p95 on the agreed reference client. Report the actual device, frame rate, vertex count, component count, and per-stage timings; do not claim success from Studio FPS alone.

## Required validation

Do not declare completion until all of the following are demonstrated:

### Visual evidence

- Side-by-side captures of Current, Reference Geometry, and Candidate Production from identical cameras.
- Noon, sunset, storm, top-down/wireframe, waterline, and moving ship-deck captures.
- The candidate has coherent traceable crests, visibly deeper troughs, specular motion, restrained real foam, and no placeholder/checker texture.
- LOD/transition debug can be enabled, but no boundary is discernible with debug disabled while standing still or sailing across it.

### Stability evidence

- Ten-minute stationary and high-speed travel soaks with no exploding/twitching mesh, NaN/inf values, frozen ring, memory climb, phase reset, UV jump, or visible rebase pop.
- Day/storm preset transitions do not rebuild every frame or create discontinuities.
- EditableMesh errors and deprecated-API warnings are zero.

### Gameplay evidence

- Empty physical ship, one seated player, multiple seated players, standing passengers, sharp turn, wave crossing, and ownership-transfer tests.
- Ship never flips merely because a player sits, and the hull does not visibly submerge due to a render/physics surface mismatch.
- Swimming in several directions and through crests has no jitter, input lock, or controller fight.
- Visual-to-physical surface sample error remains within the tolerance from the main recovery prompt.

### Performance evidence

- Before/after MicroProfiler capture and a table of average/p95 time for each ocean stage.
- Exact live counts for moving vertices, triangles, wave-component evaluations per second, normal/color commits, foam objects, horizon objects, and memory.
- High/Medium/Low quality comparison on the same scene.
- No unbounded `task.spawn`, coroutine, connection, object, or buffer growth.

## Deliverables

1. Implemented Studio/Rojo changes, not pseudocode.
2. Updated unit tests for Hs, aggregate steepness, Jacobian safety, deterministic sampling, analytic normals, rebasing, and color-mask bounds.
3. Updated integration/soak tests for surface rendering, swimming, seating, ship stability, and LOD crossing.
4. The A/B reference harness and debug toggles, default-off in production.
5. Before/after screenshots or video and MicroProfiler evidence.
6. A concise change log naming removed/replaced systems and any intentionally deferred work.
7. A final report listing current material bindings and every asset ID used; unlicensed, unknown, or failed assets must be zero.

## Source references

- Roblox community reference and attached place: <https://devforum.roblox.com/t/gerstner-wave-module/3011006>
- More recent community implementation inspired by the same sample, useful for comparison but not a drop-in dependency: <https://devforum.roblox.com/t/simulated-ocean-with-editablemesh/3562339>
- Current EditableMesh API: <https://create.roblox.com/docs/reference/engine/classes/EditableMesh>
- `EditableMesh:BatchSetValues`: <https://create.roblox.com/docs/reference/engine/classes/EditableMesh/BatchSetValues>
- Material enum (`Glass`): <https://create.roblox.com/docs/reference/engine/enums/Material>

The priority order is: **coherent silhouette and correct material response first; invisible transition second; stable shared physics third; real sparse foam fourth; then extra detail only when the measured budget permits it.**
