# Mythic Ocean — Actual-Water Visual and Ship Stability Correction

Use this as a **standalone corrective implementation prompt** against the latest `main` branch. It supersedes prior “implementation complete” claims wherever they conflict with actual Play behavior.

## Audited baseline

- Repository: `ng643/Mythic`
- Audited remote HEAD: `197f67f532d10a3f7531425cb66b9a61f780980d`
- Relevant implementation commit: `bf694b61a991be3246c6552cc6dce0e9f1c6bbbe` (`Pivot ocean to coherent Gerstner macro surface`)
- User-visible result: the water still looks like a terrible repeated texture rather than an ocean, and the physical ship still has problems.
- Target: the **second/last showcase video** in the DevForum Gerstner template for crest shape, motion, and specular readability, but with believable production ocean shading rather than its checker/debug texture.

The repository report explicitly says Play mode was blocked and that the material, ship, swimming, rendered VFX, transitions, and profiler acceptance gates were not run. Static compilation and Edit-mode probes do not override the user’s real Play result. Do not call this repair complete until you run and inspect a clean Play session.

## Confirmed defects to fix before any more artistic tuning

### 1. Fresh-start renderer failure

`OceanRenderer.luau` defines `setMeshPartProperties(part, runtime)`, but its nil-attribute branch calls `self.runtime:SetAttribute(...)`. There is no `self` in that local helper. On a clean session, `OceanClientMain.client.luau` starts the renderer **before** the material controller has initialized `OceanMaterialPath`, so this branch can throw while the near mesh is being built and send the renderer into its static fallback.

Fix both the incorrect variable and the unsafe startup ordering. The renderer must have an attractive, asset-free material default before building any MeshPart. Add a test that deletes/recreates `Workspace.OceanRuntime`, clears all attributes, then starts the complete client stack. It must produce the dynamic near mesh with `OceanFallback == false` and no startup warnings.

Do not let a pcall hide this as an acceptable fallback. A fallback may keep the game alive, but the acceptance test must fail loudly if the intended dynamic path was not created.

### 2. Production analytic normals are not attached to faces

Both production mesh builders call `AddNormal()` and update those IDs every frame, but their `addFace()` functions only call `SetFaceColors()`. They never call `SetFaceNormals()`.

`AddTriangle()` automatically receives its own face attributes; independently created normal IDs do nothing visually until assigned to the face corners. Consequently, the expensive per-frame `SetNormal()` loop can update unused IDs while the visible mesh retains static/automatic normals. This destroys the moving specular response that makes the reference demo look like water.

For **every triangle** created by `_BuildMesh` and `_BuildRectMesh`:

- assign `{normals[a], normals[b], normals[c]}` with `SetFaceNormals()`;
- assign color IDs with `SetFaceColors()`;
- if UVs are used, assign real UV IDs with `SetFaceUVs()`;
- retain face IDs for validation;
- assert with `GetFaceNormals()` and `GetFaceColors()` that every face references the intended IDs;
- sample adjacent faces and verify shared logical vertices use the same smooth normal IDs unless a deliberate hard edge exists.

Also update the color call to the current API shape: use `SetColor(colorId, color)` and set alpha separately with `SetColorAlpha()` only when required. Do not pass a legacy third alpha argument to `SetColor()`.

### 3. The current material assets are not production-ready

The live manifest currently points at:

- ColorMap `114485532047931` — Roblox reports it completed, but pixel inspection shows a high-contrast photographic ripple surface with baked white highlights;
- NormalMap `122673814251163` — Roblox thumbnail state was still `Pending` at audit time;
- RoughnessMap `84568670031055` — still `Pending` at audit time;
- MetalnessMap `90459269207438` — completed and black, which is appropriate for non-metallic water.

The ColorMap is fundamentally wrong even if all moderation completes. It is nearly the exact failure mode the previous report claimed to reject: white photographed ripples are baked into albedo, so their highlights cannot follow the moving Gerstner normals. At `StudsPerTile = 48`, the photograph also repeats conspicuously over a huge ocean.

Remove the current ColorMap from the shipping path immediately. Do not replace it with another photograph, generated “ocean image,” checker, whitecap picture, or texture containing directional shadows/highlights.

The production material stack must be:

1. **Guaranteed baseline:** asset-free `Enum.Material.Glass`, no MaterialVariant, no SurfaceAppearance, no TextureID, analytic face normals, dynamic vertex color, tuned reflectance/transparency, and proper environment specular lighting.
2. **Optional validated PBR candidate:** no albedo map or a uniform/near-uniform neutral tint map; a seamless tangent-space normal map containing only small-scale surface gradients; a subtle roughness map; solid-black metalness; no baked foam or lighting.

Make the Glass baseline the default until the PBR candidate is visibly better in an actual Play A/B and every asset resolves successfully.

For a new PBR set:

- Color/albedo must be uniform or vary by less than roughly 5–8% and contain no bright crest lines.
- The normal map should be centered around tangent-space flat normal `(127,127,255)`, be seamless, and combine subtle multi-scale ripples offline rather than showing a photographed surface.
- The roughness map should remain in a believable low-to-medium non-metal range with modest variation; tune by rendered capture.
- Metalness stays black.
- Start testing texture periods around 80–160 studs, not 48, and reject any setting whose repetition is detectable from the ship deck.
- Keep actual whitecaps in the dynamic foam system, not in the base material.

Use `ContentProvider:PreloadAsync()` with its per-asset callback and/or `GetAssetFetchStatus()`/status-changed signals. A pcall that merely returns without throwing is not proof that each asset succeeded. Only switch to PBR after every required asset reports final success. Pending, failure, timeout, permission failure, or moderation placeholder must leave the Glass baseline active.

Correct the telemetry. It currently publishes `MaterialVariant`, `surfaceappearance-manifest`, `pixel-inspected`, and `ok` even when running Glass, without a SurfaceAppearance, or with pending maps. Runtime attributes must report the material actually applied and the real status of each asset.

### 4. The material is not proven world-locked

The near ocean recenters in large snaps while the MaterialVariant projects a repeated surface pattern. Current High quality uses a 64-stud rebase step but the material repeats every 48 studs. If projection is object-relative, every rebase shifts the texture by one-third of a tile, producing obvious texture teleporting/skating.

Build a visual marker test and record a video across at least 20 rebase boundaries. Track one recognizable normal-map feature against a fixed world marker and a crest. It must not jump or follow the camera patch.

Choose and prove one solution:

- rebase only by exact integer multiples of the chosen material period;
- or create proper EditableMesh UV IDs, attach them to faces, and update their world offset atomically only on a rebase;
- or use an asset-free/material path whose projection is demonstrated to remain stable.

Do not simply label `OceanMaterialWorldLockedUV = true`. Measure the phase before and after a rebase and publish the maximum discontinuity.

## Reproduce the reference look correctly

### Fix the reference harness first

`OceanReferenceHarness.luau` currently does **not** faithfully reproduce the attached module. It calculates `amplitude = steepness / waveNumber` and then sets `horizontalAmplitude = amplitude * steepness`, applying the steepness factor twice to horizontal displacement. The reference source uses the computed Gerstner amplitude directly for the horizontal cosine displacement. The harness therefore has only about `0.30² + 0.20² = 0.13` effective aggregate horizontal steepness instead of approximately `0.50`.

Correct the reference mode so its two normalized components match the source’s visible crest sharpness. Keep positive-Jacobian safety checks, but do not weaken the test reference and then claim production matches it.

The harness also has two nominal modes—`Candidate Production` and `Current Main`—that currently display the same production renderer. Its debug toggles only set attributes and do not render the promised normals/grid/LOD/crest/compression views. Implement real distinct comparisons or remove dishonest labels.

Ensure the material controller excludes the dedicated reference MeshPart or explicitly honors its Glass setting; currently any MeshPart parented under `OceanRuntime` can be immediately restyled by the material controller.

### Retune the default visible spectrum

The new spectrum still gives most of its vertical variance to enormous waves: Trade Sea includes the exact approximately 403-stud wind peak plus roughly 526- and 675-stud swells, while only two components are in the 70–140-stud range. A 384-stud local patch therefore reads mostly as a slow rolling/tilting sheet instead of the repeated, followable 94–98-stud crests in the reference video.

For the default Trade/open-ocean visual target:

- retain four to six shared physical components;
- put approximately 55–70% of visible vertical variance into two or three coherent components in the 70–160-stud range;
- keep approximately 20–35% in medium swell around 180–450 studs;
- reserve only a smaller background share for >450-stud swell in the ordinary preset;
- keep two dominant directions close enough to form long readable crest trains, with a weaker crossing component for variation;
- preserve the chosen Hs target and a positive Jacobian;
- tune aggregate steepness around the proven reference neighborhood without double-applying it;
- ensure the 384-stud near patch visibly contains multiple moving crests from a deck camera.

Storm presets may restore stronger long swell and cross-sea energy, but still require readable mid-scale crest structure. The physics, renderer, swimming, and buoyancy must continue to consume this same field.

## Repair the distance surface instead of hiding it

The current eight-sector transition is not truly seamless:

- the near edge is sampled every 8 studs while the transition edge is sampled every 96 studs, creating a T-junction and different nonlinear interpolation between shared endpoints;
- the transition interior updates only about every 0.12 seconds while selected boundary vertices update much more frequently, so triangles can temporarily connect current-time border vertices to stale-time interior vertices;
- the generic square `boundaryIndices` calculation does not correctly describe every edge of each rectangular sector;
- the flat horizon is made from many independent Parts and inherits the same unsuitable repeated albedo.

Replace this with a provably continuous transition:

- the transition’s first row must contain every near-patch boundary vertex one-for-one;
- use graded rows or explicit stitching before decimating to coarser spacing;
- eliminate visible T-junctions;
- update every vertex of a connected transition at one coherent ocean timestamp, or interpolate the whole mesh between two coherent buffers;
- never update a moving boundary against a stale interior;
- keep positions, normals, colors, and material phase continuous together;
- use the same neutral/Glass material on near, transition, and horizon;
- verify all four sides and corners, not only shared sample points.

A debug checker/grid is allowed only in Studio to expose deformation and texture movement. It must be impossible to appear in normal play.

## Ship physics: confirmed destabilizing logic

### 1. Correct the stabilizer sign and controller

`BuoyancyService.luau` uses:

```luau
local tiltError = UP:Cross(bodyUp)
```

This has the wrong restoring sign. For a small positive roll around X, `UP:Cross(bodyUp)` points along positive X and commands torque that increases the roll. This is an anti-restoring contribution and can actively drive the ship toward inversion.

Replace it with a verified orientation-error formulation such as `bodyUp:Cross(desiredUp)`, then test both signs of roll and pitch. The commanded torque must always reduce the small-angle error.

Do not scale torque using dimensionally arbitrary `mass * gravity` constants alone. Build a weak, critically damped angular-acceleration controller and convert desired angular acceleration with `BasePart:AngularAccelerationToTorque(...)`, which accounts for the actual assembly inertia. Clamp angular acceleration and final torque.

`desiredUp` should normally be a low-pass-filtered blend between world up and an area/weight-averaged water normal sampled under the hull. Clamp the wave-follow angle. This lets the ship ride broad waves without following every small ripple or being forced unnaturally flat. Do not stabilize yaw with the roll/pitch controller.

Add deterministic unit tests with synthetic ±5° and ±15° roll/pitch orientations. For every case, the controller’s angular acceleration must point toward the desired orientation, oppose excessive roll/pitch angular velocity, remain finite, and remain below its cap.

### 2. Handle every Seat, not one selected seat

`ShipRegistry.luau` calls `findDriverSeat()` and stores one `occupant`, one occupant connection, and one occupant-parts table. Passenger seats and multiple seated players are not handled, despite the prior report claiming multi-seat validation.

Register every `Seat` and `VehicleSeat` in the ship. Maintain occupant state per seat/humanoid. For every seated character:

- save and change collision groups safely;
- prevent character-vessel self-collision;
- restore each part’s original group independently on unseat, death, respawn, seat destruction, and ship removal;
- handle character parts added after seating;
- avoid one occupant’s unseat restoring another occupant incorrectly;
- expose seated count and effective passenger mass.

### 3. Re-establish ownership on assembly topology events

Ownership is currently set only once because `_ApplyOwnership()` returns permanently after `ownershipChecked`. A Seat weld changes the physical mechanism/assembly context. Roblox’s network-ownership guidance specifically warns that vehicle passengers can affect vehicle ownership.

Keep an explicit policy, initially server ownership for the stability baseline, but reapply and verify it on event-driven topology changes: occupant sit/unseat, SeatWeld added/removed, relevant assembly-root change, and ship registration. After the assembly settles for a simulation step, verify `GetNetworkOwner()` and `GetNetworkOwnershipAuto()` against the intended policy. Do not poll or reassign every physics frame.

Once the ship is stable, a separately measured driver-ownership experiment is allowed for responsiveness, with server validation. Do not mix policies silently.

### 4. Remove the seating sink/force discontinuity

The current controller blends newly observed payload mass over roughly 1.5 seconds. During that interval, a newly seated assembly can weigh more immediately while buoyancy still uses the old control mass, making the hull sink and creating a large transient torque.

Use the actual finite assembly mass as the buoyancy target. If filtering is necessary, use a short critically damped transition and separately cap the **rate of force change**, not a long period of deliberately insufficient weight support. Record assembly mass, center of mass, waterplane, wet-point count, total lift, and roll/pitch response before/after seating.

Do not globally multiply all buoyancy forces by a torque cap in a way that removes the lift required to support weight. Limit per-point force and aggregate vertical lift independently; handle excess angular response through hull geometry, force distribution, damping, and the corrected weak stabilizer.

### 5. Inspect the actual Studio ship, not only repository scripts

The current place model is not fully represented in the Rojo repository. Use the Roblox Studio MCP to inspect the live ship after every Play restart:

- all parts, constraints, welds, anchors, massless flags, densities, collision groups, RootPriority, PrimaryPart, and AssemblyRootPart;
- dry and occupied AssemblyMass/AssemblyCenterOfMass;
- every buoyancy attachment’s world/local position, weight, target depth, and maximum force;
- waterline versus hull bottom and center of mass;
- every seat and SeatWeld;
- network owner before seating, while seated, and after unseating.

Ensure buoyancy points span the actual waterplane with sufficient beam and fore/aft leverage. Symmetry of their arithmetic centroid alone is not proof of stability.

### 6. Be explicit about ship controls

There is currently no propulsion, rudder, sail, throttle, or steering implementation in the repository. A VehicleSeat only forwards movement input to connected motors; it does not automatically turn this raft into a controllable ship.

If this demo ship is supposed to be controllable now, implement a bounded physical control service:

- smoothed throttle and steering from the designated driver seat;
- forward propulsion through a VectorForce/force at a deliberate location;
- speed-dependent rudder/yaw torque with low authority near zero speed;
- strong lateral hull drag, weaker forward drag, and capped reverse;
- no `PivotTo`, CFrame steering, direct velocity setting, or anchored motion;
- server validation and a documented ownership policy.

If controls are intentionally out of scope, state that clearly in the final report instead of implying the VehicleSeat drives the ship.

## Required Play-mode workflow

Do not continue accumulating Edit-mode claims if StartPlay is stuck.

1. Save the place and repository state.
2. Resolve the Play blocker: stop any pending session, close blocking modal state, reconnect/restart the Studio MCP or Studio safely, and reopen the saved place if necessary.
3. Start from a clean `OceanRuntime` with no persisted diagnostic attributes.
4. Run actual client and server Play tests.
5. Inspect rendered output, live assemblies, network owner, and MicroProfiler—not only source or Edit objects.

If Play still cannot run, stop and report the blocker. Do not mark the task complete, do not manufacture screenshots, and do not substitute an Edit-mode mesh build for physics/material acceptance.

## Acceptance gates

### Ocean appearance

- A 30–60 second ship-deck video beside the second DevForum reference video shows multiple coherent moving crests, deep troughs, moving specular ribbons tied to geometry, and sparse real foam.
- No photographic/bubbly/checker albedo is visible.
- No obvious tile repeats within the visible near and transition ocean.
- With a stationary camera, highlights move because normals/waves move; nothing looks painted onto the surface.
- Across 20+ camera rebases, neither the normal pattern nor any color/foam pattern jumps.
- Noon, sunrise/sunset, and storm captures all remain readable.
- The transition/horizon boundary is not visible on any side or corner while sailing.
- Every required material asset has a final successful fetch status; otherwise the capture must demonstrate the asset-free Glass baseline.

### Renderer correctness

- Fresh-start dynamic build succeeds with `OceanFallback == false`.
- Every production face has the expected current normal/color attribute IDs.
- Perturbing one test normal produces the expected visible/specular and `GetFaceNormals()` result, then the test restores it.
- No deprecated or wrong-arity EditableMesh calls.
- No frozen ring, NaN/inf value, stale-boundary tearing, or hidden pcall error.

### Ship

- Empty ship: five-minute rough-sea soak without inversion or runaway roll.
- Twenty driver sit/unseat cycles without flip, large sink transient, ownership change, collision explosion, or retained state.
- Passenger-seat and two-player tests, including different seating orders.
- Standing/jumping passenger, sharp steering, wave broadside, crest/trough crossing, and ownership transition tests.
- Record maximum roll/pitch, angular velocity, submersion, force, torque, center of mass, seated count, and network owner.
- No anchored movement, CFrame teleporting, or direct velocity control.

### Performance

- Measure in an actual Roblox client as well as Studio.
- Provide MicroProfiler captures and average/p95 times for wave evaluation, vertex commits, normal commits, color commits, transition update, foam, buoyancy, and total ocean work.
- No 8 Hz visible transition stepping, rebase spike, unbounded connection/task/object growth, or per-frame asset/material reassignment.

## Deliverables

1. Implemented and saved Studio/Rojo changes.
2. A clean commit series on top of audited HEAD.
3. Automated tests for fresh startup, face normal/color assignment, exact reference steepness, material fetch/fallback state, texture rebase phase, transition coherence, stabilizer sign, every-seat occupant bookkeeping, and ownership events.
4. Actual Play screenshots/video and profiler evidence.
5. A concise before/after defect table.
6. A final list of active material maps and their real fetch states.
7. Honest remaining limitations; no “complete” status while any required Play gate is blocked.

## Primary references

- Visual target and attached place: <https://devforum.roblox.com/t/gerstner-wave-module/3011006>
- Current EditableMesh API: <https://create.roblox.com/docs/reference/engine/classes/EditableMesh>
- MaterialVariant: <https://create.roblox.com/docs/reference/engine/classes/MaterialVariant>
- PBR texture guidance: <https://create.roblox.com/docs/art/modeling/surface-appearance>
- Asset fetch status: <https://create.roblox.com/docs/reference/engine/classes/ContentProvider/GetAssetFetchStatus>
- Network ownership: <https://create.roblox.com/docs/physics/network-ownership>
- Assemblies and root selection: <https://create.roblox.com/docs/physics/assemblies>
- Inertia-aware torque conversion: <https://create.roblox.com/docs/reference/engine/classes/BasePart/AngularAccelerationToTorque>
- MicroProfiler: <https://create.roblox.com/docs/performance-optimization/microprofiler>

Priority order: **make the clean-start dynamic surface work; attach its normals; remove the photographic/pending material; reproduce the reference crest response; eliminate texture/transition jumps; correct the ship’s anti-restoring torque and all-seat handling; then tune and optimize from real Play evidence.**
