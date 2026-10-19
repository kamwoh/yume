// The live-play clock of the viewer. Mirrors the reference loop (ADR 0068,
// ADR 0069): the input poll runs once per physics step, and a sim tick runs
// each time the accumulator passes tick_seconds. Level swaps run after the
// tick, then the physics host steps the bodies (ADR 0095 phase 3). It has
// no DOM code, so Node tests can drive it.
import { pollInput } from "./input.ts";
import type { World } from "./world.ts";

export const PHYSICS_DT = 1 / 60;
/** Float sums of 1/60 drift below whole steps. This margin keeps 1 s at 60 steps. */
const EPS = 1e-9;

export class LiveClock {
  world: World;
  /** The actions whose keys are down now. */
  held = new Set<string>();
  /** The actions whose key went down since the last poll. */
  justPressed = new Set<string>();
  private simAccum = 0;
  private frameAccum = 0;

  constructor(world: World) {
    this.world = world;
  }

  keyDown(action: string): void {
    if (!this.held.has(action)) this.justPressed.add(action);
    this.held.add(action);
  }

  keyUp(action: string): void {
    this.held.delete(action);
  }

  /** One physics step: the poll, the sim ticks that are due, then the bodies. */
  physicsStep(): void {
    pollInput(this.world, this.held, this.justPressed);
    // world.gd snap: a tick_seconds within 0.5% of the step is one tick for each step.
    // Without it, 0.0167 against 1/60 skips one tick every 8 s.
    if (Math.abs(this.world.tickSeconds - PHYSICS_DT) < PHYSICS_DT * 0.005) this.tick();
    else {
      this.simAccum += PHYSICS_DT;
      while (this.simAccum >= this.world.tickSeconds - EPS) {
        this.simAccum -= this.world.tickSeconds;
        this.tick();
      }
    }
    this.world.env.physics?.step(PHYSICS_DT);
  }

  private tick(): void {
    this.world.advanceOneTick();
    this.world.processPending();
  }

  /** Real time since the last frame, in seconds. A long stall runs at most 0.25 s. */
  advance(dt: number): void {
    this.frameAccum += Math.min(dt, 0.25);
    while (this.frameAccum >= PHYSICS_DT - EPS) {
      this.frameAccum -= PHYSICS_DT;
      this.physicsStep();
    }
  }
}
