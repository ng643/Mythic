--!strict

export type WaveComponent = {
  direction: Vector2,
  amplitude: number,
  wavelength: number,
  waveNumber: number,
  angularFrequency: number,
  horizontalAmplitude: number,
  phase: number,
  energy: number,
  minRenderTier: number?,
}

export type WaveEvent = {
  id: string,
  kind: "Packet" | "Radial" | "Wake" | "Impact",
  startServerTime: number,
  duration: number,
  originXZ: Vector2,
  direction: Vector2,
  amplitude: number,
  wavelength: number,
  length: number,
  width: number,
  phase: number,
  choppiness: number,
  gameplayRelevant: boolean,
}

export type OceanPreset = {
  name: string,
  significantWaveHeightMeters: number,
  peakPeriodSeconds: number,
  windSpeedMetersPerSecond: number,
  windDirectionDegrees: number,
  directionalSpreadDegrees: number,
  swellHeightMeters: number,
  swellPeriodSeconds: number,
  swellDirectionDegrees: number,
  choppiness: number,
  foamAmount: number,
  waterColor: Color3,
  horizonColor: Color3,
  roughness: number,
  stormIntensity: number,
}

export type OceanState = {
  version: number,
  seed: number,
  epochServerTime: number,
  seaLevel: number,
  waveGravity: number,
  bankA: {WaveComponent},
  bankB: {WaveComponent},
  bankBlendStart: number,
  bankBlendDuration: number,
  bankBlendTarget: number,
  waterColor: Color3,
  horizonColor: Color3,
  roughness: number,
  clarity: number,
  foamThreshold: number,
  windWorld: Vector3,
  stormIntensity: number,
  disturbances: {WaveEvent},
}

export type SampleOptions = {
  inverseIterations: number?,
  includeEvents: boolean?,
  componentCap: number?,
  zoneAmplitude: number?,
  foamMultiplier: number?,
}

export type WaveSample = {
  position: Vector3,
  height: number,
  normal: Vector3,
  velocity: Vector3,
  foam: number,
  jacobian: number,
  inverseResidual: number,
}

return {}
