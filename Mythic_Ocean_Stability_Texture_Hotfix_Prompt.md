# Mythic Ocean Stability and Texture Hotfix — Implementation Prompt

Work directly in the current `ng643/Mythic` Roblox place and repository using Roblox Studio MCP. Implement and verify the repair; do not stop at analysis or a written plan.

Audited baseline: `ea40f34d7ed223388a081c75c760141fc045f634` (`Fix client startup GC crash`). If HEAD has advanced, revalidate each finding before changing it.

The latest version is visibly improving, so preserve the corrected spectrum, foam signal, wake sampling, client startup order, symmetric donut test, and gameplay/buoyancy sampler. This pass is deliberately narrower: fix the incorrect active water texture and the severe failure that occurs a few seconds after play begins. Do not retune wave amplitudes or add more effects until the renderer can run unchanged for at least five minutes.

## Current causal findings

Treat these as defects to reproduce and either confirm or disprove with runtime evidence:

1. The texture described as a “fallback” is actually the active material. `MaterialService/OceanWater.model.json`, the replicated manifest, and `WaterMaterialController.FALLBACK_ASSET_IDS` all reference the same generated IDs:
   - ColorMap `128922037556159`
   - NormalMap `101286961773967`
   - RoughnessMap `111100454366205`
   - MetalnessMap `126230944196062`

   The renderer explicitly assigns `MaterialVariant = "OceanWater"`. There is no alternative high-quality material path currently replacing these maps.

2. On High, the near renderer builds four EditableMesh rings, ending at a 768-stud radius. `_BuildHorizon` then creates ten negative/positive intervals on each axis and takes their Cartesian product, producing **100 additional EditableMeshes**. Ultra produces 196 horizon EditableMeshes. Roblox documents that `CreateEditableMesh` returns `nil` when the device-specific editable-memory budget is exhausted.

3. The horizon interval algorithm is geometrically wrong. Both X and Z intervals exclude `[-finalExtent, finalExtent]`, so their Cartesian product creates only the four corner regions. The north, south, east, and west bands between the near ocean and those corners are missing. The inner-square exclusion condition is effectively always true for the generated interval pairs.

4. `OceanQualityController` starts with no cooldown. If its EMA exceeds 23 ms for two seconds, it immediately calls `renderer:SetQuality("Medium")`. `SetQuality` calls `_Build`, which destroys every current ring/horizon EditableMesh and allocates the whole set again. This two-second threshold matches the reported delay.

5. Destroying many EditableMeshes does not guarantee their device memory is synchronously available for immediate reallocation. The repository already added and then removed `collectgarbage("collect")` after it caused a client startup crash. Do not reintroduce forced garbage collection.

6. If any ring or horizon mutation fails, `_Update` calls `_UseFallback`, which destroys all remaining animated geometry and creates an `8192 x 8192` static Part. Thus one peripheral horizon failure can erase a healthy near ocean.

7. Every 0.5 seconds on High, all 100 horizon meshes are sampled and mutated in one frame. This creates a periodic CPU/mesh-commit spike. Rings whose full and shared component caps are identical are also sampled twice per vertex for identical results.

8. `WaterMaterialController.ChildAdded` re-applies the material by scanning every runtime child for each newly added mesh. During a 100-tile quality rebuild this becomes repeated, roughly quadratic work and makes the rebuild hitch worse.

9. `WaterMaterialController` attempts to read `MaterialVariant.ColorMap`, `NormalMap`, `RoughnessMap`, and `MetalnessMap` from a LocalScript. Those properties are Plugin Security in the current Roblox API, so the runtime `readVariantAsset` validation cannot prove that the maps are bound. It catches the security failure and reports an empty binding.

10. `_UpdateSeamStats` is not a real test: `shared` and `fineSample` are made with the same position, time, and component cap, so it compares a sample with itself and always reports zero even if rendered ring vertices disagree.

Primary references:

- EditableMesh device memory behavior: <https://create.roblox.com/docs/reference/engine/classes/AssetService/CreateEditableMesh>
- MaterialVariant API and property security: <https://create.roblox.com/docs/reference/engine/classes/MaterialVariant>
- Roblox custom material/PBR workflow: <https://create.roblox.com/docs/tutorials/curriculums/environmental-art/assemble-an-asset-library>
- Asset loading, moderation, and permissions: <https://create.roblox.com/docs/projects/assets>

## Phase 1 — reproduce and prove the failure before editing

Use a clean Studio server/client session. Do not rely on memory of the prior playtest.

1. Test once with `OceanQualityOverride = "High"` and adaptive quality disabled, then once with adaptive quality enabled and no override.
2. At `t = 0, 1, 2, 3, 5, 15, 30, 120` seconds record:
   - `OceanQuality`
   - `OceanFallback`
   - `OceanRendererBuildError`
   - `OceanHorizonMeshFallback`
   - `OceanRingCount`
   - `OceanHorizonTileCount`
   - `OceanVertexCount` / `OceanTriangleCount`
   - `OceanOceanMs`, `OceanUpdateMs`, and frame time
   - count of live EditableMeshes, near MeshParts, static horizon Parts, and fallback Parts
   - client memory before and after any quality change, using supported Studio statistics/MicroProfiler evidence.
3. Preserve the exact first Output warning/error and stack trace. Do not overwrite the useful original error with the generic string `runtime mesh mutation failure`.
4. Capture the ocean at the same timestamps. The evidence must show whether the visible failure coincides with a quality change, horizon update, mesh mutation error, material failure, or memory-allocation failure.
5. Publish the confirmed causal timeline in the completion notes. The code evidence strongly predicts the two-second adaptive rebuild/memory path, but verify it rather than presenting an inference as a measured fact.

## Phase 2 — eliminate destructive runtime rebuilding

The ocean’s topology must remain stable during ordinary play.

1. Remove `Fallback` from the automatic quality ladder. Static fallback is an unsupported-device or fatal-initialization mode, not a legitimate adaptive quality tier.
2. Give adaptive quality a 15-second warm-up and a meaningful initial cooldown. Ignore renderer construction, initial asset streaming, and the first several frame spikes when establishing the EMA baseline.
3. Do not call `_Build()` from a RenderStepped quality decision. Prefer one stable near topology selected at initialization. Runtime quality changes should adjust only safe parameters such as:
   - update cadence;
   - component bands/caps;
   - how many rings receive dynamic normals;
   - foam/spray/wake budgets;
   - horizon detail visibility;
   - diagnostic sampling cadence.
4. If a different vertex resolution absolutely requires rebuilding, queue it outside RenderStepped, rate-limit it, and make it a transactional operation. Do not destroy the working renderer until the replacement has completely built and passed validation. More importantly, design the initial topology to fit low-end memory so ordinary adaptive changes do not need this path.
5. Never call `collectgarbage`. Never assume destroyed EditableMeshes release device budget immediately.
6. Prevent repeated `_Set` calls for the current quality. Publish `OceanQualityChangeReason`, old/new quality, timestamp, and whether topology changed.
7. Add a regression assertion: with a stationary camera and unchanged weather, the identities/counts of near EditableMeshes must remain constant for five minutes, even while adaptive quality changes rendering budgets.

## Phase 3 — replace the horizon with a low-memory, complete annulus

The distant horizon does not need one independently animated EditableMesh per tile.

1. Keep EditableMeshes only for the near rings. Replace the 100/196 editable horizon mesh allocation with a small bounded set of static/coarse objects. Prefer segmented anchored Parts with the water material, or a few reusable static MeshPart templates that do not each own an EditableMesh.
2. Cover the complete square annulus without a center overlap. A simple correct decomposition is:
   - north band: full outer width, from `+innerExtent` to `+outerRange`;
   - south band: full outer width, from `-outerRange` to `-innerExtent`;
   - east band: from `+innerExtent` to `+outerRange`, with Z limited to the inner middle span already not covered by north/south;
   - west band: mirrored east band.

   Subdivide these bands only as required by actual BasePart/MeshPart size limits. Add a coverage test that samples the entire annulus and proves every point is covered exactly once, while every point in the inner square is covered zero times.
3. A flat distant horizon is acceptable when it begins beyond the animated near ocean and haze conceals the transition. It is safer and cheaper than mutating 100 low-resolution EditableMeshes every half second.
4. Do not update all distant objects in one frame. A static horizon should only recenter when the camera crosses a coarse threshold, and that recenter must be visually hidden. It must never allocate geometry during movement.
5. Horizon failure must be isolated. If the horizon cannot be created, retain the healthy near animated ocean and increase haze; do not call `_UseFallback` for a horizon-only failure.
6. Add explicit budgets and fail initialization if exceeded: maximum near EditableMesh count, maximum horizon object count, maximum initial vertex count, and maximum creation time. Suggested target: 4–6 near EditableMeshes and no horizon EditableMeshes.

## Phase 4 — make mesh mutation fail-soft

1. Before every BatchSetValues or per-ID fallback commit, validate every position and normal:
   - all components finite;
   - normal magnitude within a safe range before normalization;
   - displacement within a preset-derived conservative bound;
   - array length exactly matches the ID array;
   - IDs still belong to the live mesh generation.
2. Give every build a monotonically increasing generation token. Deferred updates must check the token before touching a mesh so an old callback cannot mutate a destroyed/replaced EditableMesh.
3. If one frame is invalid, skip that commit and retain the last valid geometry. Record level, vertex index, values, state version, component cap, time, and full error. Do not destroy the ocean.
4. If one near ring repeatedly fails, freeze that ring and degrade its update cadence/component count. Only enter static fallback if initial near-ring construction is impossible and no animated renderer has ever reached a valid frame.
5. Separate near and horizon health. Replace the single global cascade where any `tile.failed` destroys everything.
6. Balance every `debug.profilebegin` even when an error occurs; do not leave the profiler stack open after a protected mutation failure.
7. Optimize duplicate sampling. When `componentCap == sharedComponentCap`, sample once. For transitions, preferably evaluate shared long-wave displacement once and evaluate only the residual component range rather than two complete banks.

## Phase 5 — replace the weird active material

Do not call the current map set “verified” merely because a MaterialVariant instance exists.

1. Remove the four generated IDs above from `FALLBACK_ASSET_IDS` and from the active `OceanWater` variant unless the actual map images pass visual inspection. There must be one explicit authoritative manifest, not hard-coded duplicates in three locations.
2. First establish a clean baseline material:
   - either no ColorMap, or a neutral white/very-low-contrast albedo so `MeshPart.Color` controls water color;
   - a genuinely seamless tangent-space OpenGL normal map designed for ocean ripples;
   - a restrained grayscale roughness map;
   - a pure black metalness map because water is non-metal.
3. If the current ColorMap is responsible for the strange repeated pattern, remove it immediately rather than masking it with a darker tint. Large color blotches, foam baked into albedo, obvious square tiling, stars/sparkles, and photo-like water texture are forbidden.
4. Tune `StudsPerTile` by viewing the material at deck, mast, and aerial height. The current value of `10` can make a strongly patterned ColorMap repeat conspicuously. Test several scales and use `MaterialPattern = Organic` if it improves repetition without causing visible rotation discontinuities.
5. NormalMap requirements must follow Roblox’s documented tangent-space/OpenGL convention. Inspect the actual uploaded image; an asset ID and generic name are not validation.
6. Perform map inspection and MaterialVariant property validation at authoring time through the Studio MCP/plugin, where those Plugin Security properties are accessible. The LocalScript must not pretend it can read them. At runtime, validate instance presence, baked manifest/version, and `ContentProvider.AssetFetchFailed`; keep the authoring-time report as the source of map identity.
7. Ensure each uploaded image is approved and permitted for the published experience. Test in an actual published client, not only local Studio cache.
8. The active material must remain unchanged from `t=0` through quality changes. Quality adaptation must not replace it with SmoothPlastic, an emergency texture, or a different tiling scale.
9. Capture a material test grid/sphere or flat swatch showing ColorMap, NormalMap response, roughness response, and final combined water under noon, sunset, night, and Gale lighting. Inspect the captures yourself and iterate.

## Phase 6 — replace false diagnostics with useful tests

1. Rewrite `_UpdateSeamStats`. It currently samples the same function twice. Compare the **actual committed/stored edge positions and normals** of the fine and coarse rendered meshes, accounting for their origins, morph weights, and coarse-edge interpolation.
2. Add a five-minute soak test with fixed High quality and another with adaptive quality. During each test require:
   - no fallback transition;
   - no mesh generation change unless explicitly requested by the test;
   - no ring/horizon object-count growth;
   - no NaN/Inf or displacement-bound rejection;
   - no worsening editable-memory trend after warm-up;
   - no periodic 0.5-second horizon hitch;
   - no material path/ID change;
   - zero ocean-related red errors.
3. Move the camera slowly and rapidly across recenter boundaries during the soak. Include a moving boat and a stationary aerial camera.
4. Add a targeted automated quality test that simulates over-budget frames. It must prove that a quality downgrade changes safe budgets but does not call `_Build`, destroy an EditableMesh, create a fallback Part, or change the active material.

## Required visual acceptance sequence

Capture and inspect all of the following before claiming completion:

| Run | Times | Required result |
|---|---|---|
| High locked, stationary | 0, 2, 5, 30, 120 seconds | Identical healthy topology; no fallback or visual explosion |
| Adaptive, stationary | 0, 2, 5, 30, 120 seconds | Safe budget changes only; no destructive rebuild |
| High, moving camera/boat | continuous 2 minutes | No recenter twitch, mesh corruption, or texture movement |
| Trade Sea deck view | close and grazing angles | Clean water color, subtle ripple normals, no weird repeated albedo |
| Gale deck/mast view | 30 seconds | Stable sharp waves and foam; material remains coherent |
| 80-stud aerial | cardinal and diagonal views | Complete horizon annulus with no cross-shaped gaps or corner-only tiles |
| Published client | at least 2 minutes | Assets load with permissions and match Studio appearance |

## Forbidden shortcuts

- Do not reintroduce `collectgarbage`.
- Do not disable wave motion to hide a mutation bug.
- Do not leave adaptive quality disabled as the final fix; make it non-destructive.
- Do not allow automatic quality to select static fallback.
- Do not create 100–196 horizon EditableMeshes.
- Do not let a horizon failure destroy healthy near rings.
- Do not keep the four current generated map IDs without inspecting their actual pixels and final rendered result.
- Do not claim `OceanMaterialMapBinding = active` from LocalScript reads of Plugin Security properties.
- Do not accept a seam metric that compares a sample with itself.
- Do not claim completion without the timestamped soak captures and runtime evidence.

## Completion deliverables

Return:

1. Implemented repository/place changes and a concise file-by-file summary.
2. The measured before-fix causal timeline, including the exact first error and whether the two-second quality rebuild triggered it.
3. Before/after object counts and editable-memory evidence for High and Ultra.
4. The corrected horizon coverage-test result.
5. Fixed-High and adaptive five-minute soak results.
6. The final material asset IDs, authoring-time property inspection, ownership/permission status, and material test captures.
7. Timestamped gameplay captures from the acceptance table.
8. Explicit confirmation that the ocean no longer changes to fallback, corrupts, jitters, or swaps material after several seconds.

Prioritize exactly: reproduce and capture the first failure; stop destructive adaptive rebuilds; remove editable horizon meshes; isolate failures; then replace and visually approve the material. Do not spend time on more foam or spectrum tuning until the two-minute and five-minute stability gates pass.
